"""#564: waiting for CI must treat "found no checks" as its own answer.

`gh pr checks <n>` reports nothing in the window between a push and the checks
being registered, and twice on 2026-08-14 a wait loop read that as settled and
green. Trusting it would have merged a commit nothing had run against, which is
L98 exactly: finding zero subjects is indistinguishable from everything
passing, and it arrives precisely when the work has not started.

So the wait has to know what it is waiting FOR. The expected set is derived
from the workflow files rather than pinned by hand, so adding a job raises the
bar instead of silently lowering it (L96: a hand-written registry only checks
what it lists).

`tests/fixtures/gh_pr_checks_real.json` is the real reply for pull request 561,
recorded with `gh pr checks 561 --json name,state,bucket,workflow` on
2026-08-14, not a shape invented here (L48). It is what calibrates the
derivation: eight checks, one of them the `full` guard job legitimately skipped
because it only runs off pull requests.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools.wait_for_checks import (
    EXIT_GREEN,
    EXIT_NEVER_APPEARED,
    EXIT_RED,
    EXIT_STILL_RUNNING,
    EXIT_UNUSABLE,
    ExpectedCheck,
    GhUnusable,
    UnreadableWorkflow,
    expected_checks,
    main,
    read_reply,
    verdict,
)


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
REAL_REPLY = REPO_ROOT / "tests" / "fixtures" / "gh_pr_checks_real.json"


def real_reply() -> list[dict[str, str]]:
    return json.loads(REAL_REPLY.read_text(encoding="utf-8"))


def real_expected() -> set[ExpectedCheck]:
    return expected_checks(WORKFLOWS)


# ── what the workflows promise ────────────────────────────────────────────────


def test_the_derived_set_matches_a_real_pull_request() -> None:
    """Every check GitHub actually reported, and no invented extras.

    Calibration against the recorded reply rather than against the derivation's
    own idea of the workflows, which would only prove it agrees with itself.
    """
    reported = {(row["workflow"], row["name"]) for row in real_reply()}
    derived = {(check.workflow, check.name) for check in real_expected()}
    assert derived == reported


def test_a_matrix_job_is_expected_once_per_shard() -> None:
    names = {check.name for check in real_expected()}
    assert {
        "reference-frames (legibility)",
        "reference-frames (thursday-reel)",
        "reference-frames (goldens)",
    } <= names


def test_two_jobs_may_share_a_name_across_workflows() -> None:
    """`macos` in Tests and the macOS workflow are different things.

    Keying the bar on the name alone would let one of them answer for the
    other (L70).
    """
    expected = real_expected()
    assert ExpectedCheck(workflow="Tests", name="macos") in expected
    assert not any(
        check.workflow == "macOS" and check.name == "macos" for check in expected
    )


def test_adding_a_job_raises_the_bar(tmp_path: Path) -> None:
    """A new job must be waited for without anyone editing this tool."""
    workflows = tmp_path / "workflows"
    workflows.mkdir()
    one = "name: Tests\non:\n  pull_request:\njobs:\n  python:\n    runs-on: ubuntu-latest\n"
    (workflows / "tests.yml").write_text(one, encoding="utf-8")
    before = expected_checks(workflows)

    (workflows / "tests.yml").write_text(
        one + "  windows:\n    runs-on: windows-latest\n", encoding="utf-8")
    after = expected_checks(workflows)

    assert before == {ExpectedCheck(workflow="Tests", name="python")}
    assert after - before == {ExpectedCheck(workflow="Tests", name="windows")}


def test_a_workflow_that_no_pull_request_triggers_is_not_expected(tmp_path: Path) -> None:
    workflows = tmp_path / "workflows"
    workflows.mkdir()
    (workflows / "nightly.yml").write_text(
        "name: Nightly\non:\n  schedule:\n    - cron: '0 3 * * *'\n"
        "jobs:\n  sweep:\n    runs-on: ubuntu-latest\n",
        encoding="utf-8")
    assert expected_checks(workflows) == set()


def test_a_job_condition_this_cannot_read_refuses_to_answer(tmp_path: Path) -> None:
    """An unclassifiable `if:` means the bar is unknown, which is not a pass.

    Guessing would produce a number that reads as authoritative while standing
    for nothing.
    """
    workflows = tmp_path / "workflows"
    workflows.mkdir()
    (workflows / "tests.yml").write_text(
        "name: Tests\non:\n  pull_request:\njobs:\n"
        "  python:\n    if: contains(github.event.head_commit.message, 'skip')\n"
        "    runs-on: ubuntu-latest\n",
        encoding="utf-8")
    with pytest.raises(UnreadableWorkflow, match="if:"):
        expected_checks(workflows)


def test_a_matrix_this_cannot_expand_refuses_to_answer(tmp_path: Path) -> None:
    workflows = tmp_path / "workflows"
    workflows.mkdir()
    (workflows / "tests.yml").write_text(
        "name: Tests\non:\n  pull_request:\njobs:\n"
        "  python:\n    name: python (${{ matrix.os }})\n    runs-on: ubuntu-latest\n",
        encoding="utf-8")
    with pytest.raises(UnreadableWorkflow, match="matrix"):
        expected_checks(workflows)


def test_a_pull_request_workflow_declaring_no_jobs_refuses_to_answer(tmp_path: Path) -> None:
    """A file this cannot read jobs out of contributes nothing, silently.

    Which is the same defect one level down: the bar quietly drops by however
    many checks that workflow produces, and the wait then reports green having
    waited for none of them.
    """
    workflows = tmp_path / "workflows"
    workflows.mkdir()
    (workflows / "tests.yml").write_text(
        "name: Tests\non:\n  pull_request:\njobs:\n\n", encoding="utf-8")
    with pytest.raises(UnreadableWorkflow, match="no jobs"):
        expected_checks(workflows)


def test_no_workflows_at_all_refuses_to_answer(tmp_path: Path) -> None:
    """An empty bar would make every reply green, including no reply at all."""
    empty = tmp_path / "workflows"
    empty.mkdir()
    with pytest.raises(UnreadableWorkflow):
        expected_checks(empty)


# ── reading a reply ───────────────────────────────────────────────────────────


def test_the_real_reply_reads_as_green() -> None:
    assert verdict(real_expected(), real_reply()).state == "green"


def test_no_checks_reported_is_never_green() -> None:
    """The defect this exists for: an empty answer read as everything passing."""
    answer = verdict(real_expected(), [])
    assert answer.state == "missing"
    assert len(answer.missing) == len(real_expected())


def test_one_missing_check_is_never_green() -> None:
    rows = [row for row in real_reply() if row["name"] != "python"]
    answer = verdict(real_expected(), rows)
    assert answer.state == "missing"
    assert answer.missing == [ExpectedCheck(workflow="Tests", name="python")]
    assert "python" in answer.summary


def test_a_failed_check_is_red() -> None:
    rows = real_reply()
    rows[0] = dict(rows[0], bucket="fail", state="FAILURE")
    answer = verdict(real_expected(), rows)
    assert answer.state == "red"
    assert answer.failed == ["Guard proofs / changed"]


def test_a_failure_outranks_a_check_that_has_not_appeared() -> None:
    """Red is the answer even when something else is still missing.

    A caller told "still waiting" would poll on past a failure it could act on
    now.
    """
    rows = [row for row in real_reply() if row["name"] != "python"]
    rows[0] = dict(rows[0], bucket="fail", state="FAILURE")
    assert verdict(real_expected(), rows).state == "red"


def test_a_pending_check_is_still_running() -> None:
    rows = real_reply()
    rows[1] = dict(rows[1], bucket="pending", state="IN_PROGRESS")
    answer = verdict(real_expected(), rows)
    assert answer.state == "running"


def test_a_cancelled_check_is_red() -> None:
    rows = real_reply()
    rows[1] = dict(rows[1], bucket="cancel", state="CANCELLED")
    assert verdict(real_expected(), rows).state == "red"


def test_a_job_declared_to_skip_on_pull_requests_may_skip() -> None:
    """`full` carries `if: github.event_name != 'pull_request'`.

    Its skip is the workflow working, so demanding it pass would make every
    pull request permanently red.
    """
    assert any(row["name"] == "full" and row["bucket"] == "skipping"
               for row in real_reply())
    assert verdict(real_expected(), real_reply()).state == "green"


def test_a_job_that_should_have_run_but_skipped_is_not_green() -> None:
    """A skip is only acceptable where the workflow asked for one.

    Otherwise a job silently dropped by a filter reads exactly like a job that
    passed.
    """
    rows = [dict(row, bucket="skipping", state="SKIPPED") if row["name"] == "python"
            else row for row in real_reply()]
    answer = verdict(real_expected(), rows)
    assert answer.state == "red"
    assert answer.failed == ["Tests / python"]


def test_checks_nobody_derived_do_not_break_green() -> None:
    """A third-party check is not the bar, so it cannot lower or raise it."""
    rows = real_reply() + [
        {"workflow": "Some App", "name": "coverage", "bucket": "pending",
         "state": "IN_PROGRESS"},
    ]
    assert verdict(real_expected(), rows).state == "green"


# ── what gh actually said ─────────────────────────────────────────────────────


def test_an_empty_json_array_reads_as_no_checks() -> None:
    assert read_reply(exit_code=0, stdout="[]", stderr="") == []


def test_ghs_own_no_checks_message_reads_as_no_checks() -> None:
    """gh reports "no checks reported" on stderr with a non-zero exit.

    Recorded from a real run against a freshly pushed branch, so this is the
    message the tool will actually meet rather than one remembered (L52).
    """
    assert read_reply(
        exit_code=1, stdout="",
        stderr="no checks reported on the 'ci-check-wait-564' branch\n") == []


def test_gh_failing_for_any_other_reason_is_not_no_checks() -> None:
    """An auth failure must not spend the whole timeout looking like patience."""
    with pytest.raises(GhUnusable, match="authentication"):
        read_reply(exit_code=4, stdout="", stderr="gh: authentication required\n")


def test_output_that_is_not_json_is_not_no_checks() -> None:
    with pytest.raises(GhUnusable):
        read_reply(exit_code=0, stdout="checks are fine\n", stderr="")


# ── the exit codes ────────────────────────────────────────────────────────────


class FakeClock:
    def __init__(self) -> None:
        self.t = 0.0

    def now(self) -> float:
        return self.t

    def sleep(self, seconds: float) -> None:
        self.t += seconds


def run(replies: list[list[dict[str, str]]], *, timeout: str = "600") -> int:
    """Drive main() over a scripted series of gh replies."""
    clock = FakeClock()
    remaining = list(replies)

    def fetch(_number: str) -> list[dict[str, str]]:
        return remaining.pop(0) if len(remaining) > 1 else remaining[0]

    return main(
        ["7", "--timeout", timeout, "--interval", "30"],
        fetch=fetch, now=clock.now, sleep=clock.sleep,
        workflows=WORKFLOWS, out=lambda _line: None)


def test_green_exits_zero() -> None:
    assert run([real_reply()]) == EXIT_GREEN


def test_a_failure_exits_red() -> None:
    rows = real_reply()
    rows[0] = dict(rows[0], bucket="fail", state="FAILURE")
    assert run([rows]) == EXIT_RED


def test_checks_that_never_appear_exit_never_appeared() -> None:
    """The whole point: no reply, all the way to the deadline, is not green."""
    assert run([[]]) == EXIT_NEVER_APPEARED


def test_a_check_still_pending_at_the_deadline_exits_still_running() -> None:
    rows = [dict(row, bucket="pending", state="IN_PROGRESS") for row in real_reply()]
    assert run([rows]) == EXIT_STILL_RUNNING


def test_an_empty_first_reply_is_waited_out_rather_than_believed() -> None:
    """The registration window, which is where the two bad merges nearly were."""
    assert run([[], [], real_reply()]) == EXIT_GREEN


def test_gh_being_unusable_exits_unusable_at_once() -> None:
    def fetch(_number: str) -> list[dict[str, str]]:
        raise GhUnusable("gh: authentication required")

    clock = FakeClock()
    code = main(["7", "--timeout", "600", "--interval", "30"],
                fetch=fetch, now=clock.now, sleep=clock.sleep,
                workflows=WORKFLOWS, out=lambda _line: None)
    assert code == EXIT_UNUSABLE
    assert clock.t == 0.0


def test_every_exit_code_is_distinct() -> None:
    codes = [EXIT_GREEN, EXIT_RED, EXIT_NEVER_APPEARED, EXIT_STILL_RUNNING,
             EXIT_UNUSABLE]
    assert len(set(codes)) == len(codes)


def test_the_wait_says_what_it_was_waiting_for() -> None:
    """A timeout with no subject named is a hang wearing a message (L110)."""
    lines: list[str] = []
    clock = FakeClock()
    main(["7", "--timeout", "60", "--interval", "30"],
         fetch=lambda _n: [], now=clock.now, sleep=clock.sleep,
         workflows=WORKFLOWS, out=lines.append)
    said = "\n".join(lines)
    assert "Tests / python" in said
    assert "60" in said
