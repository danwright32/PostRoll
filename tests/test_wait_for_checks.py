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

#669 is the other half, and the dangerous one. `gh pr checks` reports rows
keyed by workflow and check NAME with no notion of which commit produced them,
so a push landing while the previous run finishes mixes two commits' answers:
measured on #667 on 2026-08-17, three consecutive pushes each reported
`red: failed: Tests / python` within seconds, every one of them the previous
commit's run. The mirror is a superseded run that PASSED reporting green for a
commit nothing has judged. So every row here is now sourced through the head
SHA and refused if it names another one (L173).

The fixtures are real replies for pull request 667 at
84e9dbf2b77495a73348cb81bd9de852f2edcf9b, recorded on 2026-08-17, not shapes
invented here (L48):

    gh api "repos/danwright32/PostRoll/actions/runs?head_sha=<sha>&per_page=100"
    gh api "repos/danwright32/PostRoll/actions/runs/<id>/jobs?per_page=100"

Each run's `repository`, `head_repository`, `pull_requests`, `head_commit`,
`actor` and `triggering_actor`, and each job's `steps`, were deleted whole
because nothing here reads them and they are most of the bytes. Every field
this tool touches is as GitHub sent it.

`tests/fixtures/gh_pr_checks_real.json` is kept beside them: the real
`gh pr checks 561 --json name,state,bucket,workflow` reply from 2026-08-14,
which is what the verdict rules were calibrated against and still are.
"""

from __future__ import annotations

import inspect
import json
import sys
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
    Poll,
    UnreadableWorkflow,
    bucket_of,
    expected_checks,
    main,
    poll_checks,
    say,
    verdict,
)


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
REAL_REPLY = REPO_ROOT / "tests" / "fixtures" / "gh_pr_checks_real.json"
REAL_RUNS = REPO_ROOT / "tests" / "fixtures" / "gh_actions_runs_real.json"
REAL_JOBS = REPO_ROOT / "tests" / "fixtures" / "gh_actions_jobs_real.json"

#: The head commit of pull request 667, which every recorded reply is about.
HEAD_SHA = "84e9dbf2b77495a73348cb81bd9de852f2edcf9b"
OTHER_SHA = "0ef38b2c1d4e5f60718293a4b5c6d7e8f9a0b1c2"
REPO = "danwright32/PostRoll"


def real_reply() -> list[dict[str, str]]:
    return json.loads(REAL_REPLY.read_text(encoding="utf-8"))


def real_expected() -> set[ExpectedCheck]:
    return expected_checks(WORKFLOWS)


def real_runs() -> dict:
    return json.loads(REAL_RUNS.read_text(encoding="utf-8"))


def real_jobs() -> dict[str, dict]:
    return json.loads(REAL_JOBS.read_text(encoding="utf-8"))


class FakeApi:
    """Answers `gh api` paths out of the recorded replies for #667.

    A real seam rather than a reimplementation: the replies are GitHub's own,
    so a field renamed here would be a field renamed in the recording (L52).
    """

    def __init__(
        self,
        *,
        sha: str = HEAD_SHA,
        runs: dict | None = None,
        jobs: dict[str, dict] | None = None,
    ) -> None:
        self.sha = sha
        self.runs = real_runs() if runs is None else runs
        self.jobs = real_jobs() if jobs is None else jobs
        self.paths: list[str] = []

    def __call__(self, path: str) -> dict:
        self.paths.append(path)
        if "/pulls/" in path:
            sha = self.sha() if callable(self.sha) else self.sha
            return {"head": {"sha": sha}, "base": {"repo": {"full_name": REPO}}}
        if "/jobs" in path:
            run_id = path.split("/actions/runs/", 1)[1].split("/", 1)[0]
            return self.jobs[run_id]
        if "/actions/runs?" in path:
            return self.runs
        raise AssertionError(f"the tool asked for a path nothing recorded: {path}")


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


def test_a_run_not_yet_finished_outranks_every_settled_check() -> None:
    """Eight green jobs under a run still going on is not a green commit."""
    answer = verdict(real_expected(), real_reply(), ["Tests"])
    assert answer.state == "running"
    assert "Tests" in answer.summary


def test_checks_nobody_derived_do_not_break_green() -> None:
    """A third-party check is not the bar, so it cannot lower or raise it."""
    rows = real_reply() + [
        {"workflow": "Some App", "name": "coverage", "bucket": "pending",
         "state": "IN_PROGRESS"},
    ]
    assert verdict(real_expected(), rows).state == "green"


# ── a run at another commit is not an answer ──────────────────────────────────


def test_the_rows_read_out_of_a_real_reply_are_the_checks_the_workflows_promise() -> None:
    """Calibration: GitHub's own runs and jobs against the derived bar.

    Two independent routes to the same set, the workflow files and what GitHub
    actually ran, so agreement means something (L70).
    """
    poll = poll_checks("667", api=FakeApi())
    reported = {(row["workflow"], row["name"]) for row in poll.rows}
    assert reported == {(check.workflow, check.name) for check in real_expected()}
    assert poll.head_sha == HEAD_SHA
    assert verdict(real_expected(), poll.rows, poll.unfinished).state == "green"


def test_the_head_sha_is_asked_for_and_carried_into_the_query() -> None:
    """The whole point of #669: the question names a commit."""
    api = FakeApi()
    poll_checks("667", api=api)
    assert any("/pulls/667" in path for path in api.paths), api.paths
    assert any(f"head_sha={HEAD_SHA}" in path for path in api.paths), api.paths


def test_a_run_at_another_commit_is_refused_rather_than_counted() -> None:
    """#669 measured: the previous commit's failed run answered for the new one.

    GitHub filters by `head_sha` server side, so this can only fire if that
    filter is dropped, wrong, or asked with the wrong SHA. It is the one thing
    the tool must never get away with, so it is checked here too rather than
    trusted (L70).
    """
    runs = real_runs()
    runs["workflow_runs"][0] = dict(runs["workflow_runs"][0], head_sha=OTHER_SHA)
    with pytest.raises(GhUnusable, match=OTHER_SHA[:12]):
        poll_checks("667", api=FakeApi(runs=runs))


def test_a_job_at_another_commit_is_refused_rather_than_counted() -> None:
    """Each job names its own commit, which is a second, independent witness.

    A run object and its jobs are two API replies, so a job carrying another
    SHA is caught even when the run it came from claims the right one.
    """
    jobs = real_jobs()
    jobs["32065034890"]["jobs"][1] = dict(
        jobs["32065034890"]["jobs"][1], head_sha=OTHER_SHA)
    with pytest.raises(GhUnusable, match="python"):
        poll_checks("667", api=FakeApi(jobs=jobs))


def test_a_run_still_in_flight_is_never_green() -> None:
    """"Every run completed" is part of the answer, not a detail of it.

    All eight jobs can be listed and settled in the seconds a run spends
    finalising, and a green read there is a green for work still going on.
    """
    runs = real_runs()
    runs["workflow_runs"][2] = dict(
        runs["workflow_runs"][2], status="in_progress", conclusion=None)
    poll = poll_checks("667", api=FakeApi(runs=runs))
    assert poll.unfinished == ["Tests"]
    answer = verdict(real_expected(), poll.rows, poll.unfinished)
    assert answer.state == "running"
    assert "Tests" in answer.summary


def test_a_run_triggered_by_something_other_than_the_pull_request_is_not_the_bar() -> None:
    """The bar is derived from what a pull request triggers, so the rows must be.

    A workflow that also runs on push would otherwise report its jobs twice at
    one commit, under names the bar holds once.
    """
    runs = real_runs()
    runs["total_count"] += 1
    #: A higher id than any real run, so keeping the newest run per workflow
    #: cannot be what drops it and the event is the only thing that can.
    runs["workflow_runs"].append(
        dict(runs["workflow_runs"][2], id=99999999999, event="push"))
    api = FakeApi(runs=runs)
    poll = poll_checks("667", api=api)
    assert not any("/99999999999/jobs" in path for path in api.paths), api.paths
    assert len(poll.rows) == len(real_expected())


def test_a_reply_that_did_not_fit_on_one_page_is_refused() -> None:
    """A short page is a smaller bar, and a smaller bar is a cheaper green."""
    runs = dict(real_runs(), total_count=9)
    with pytest.raises(GhUnusable, match="9"):
        poll_checks("667", api=FakeApi(runs=runs))


def test_gh_failing_is_unusable_rather_than_an_empty_answer() -> None:
    """An auth failure must not spend the whole timeout looking like patience."""
    def api(_path: str) -> dict:
        raise GhUnusable("gh: authentication required")

    with pytest.raises(GhUnusable, match="authentication"):
        poll_checks("667", api=api)


# ── what a status and a conclusion mean ───────────────────────────────────────


@pytest.mark.parametrize(
    ("status", "conclusion", "expected"),
    [
        ("completed", "success", "pass"),
        ("completed", "neutral", "pass"),
        ("completed", "skipped", "skipping"),
        ("completed", "cancelled", "cancel"),
        ("completed", "failure", "fail"),
        ("completed", "timed_out", "fail"),
        ("completed", "action_required", "fail"),
        ("completed", "startup_failure", "fail"),
        ("queued", None, "pending"),
        ("in_progress", None, "pending"),
        ("waiting", None, "pending"),
    ],
)
def test_each_status_and_conclusion_reads_as_one_bucket(
        status: str, conclusion: str | None, expected: str) -> None:
    assert bucket_of(status, conclusion) == expected


def test_a_conclusion_this_has_never_heard_of_is_not_a_pass() -> None:
    """GitHub may add one, and the safe side of an unknown word is red (L35)."""
    assert bucket_of("completed", "exploded") == "fail"
    assert bucket_of("completed", None) == "fail"


# ── the exit codes ────────────────────────────────────────────────────────────


class FakeClock:
    def __init__(self) -> None:
        self.t = 0.0

    def now(self) -> float:
        return self.t

    def sleep(self, seconds: float) -> None:
        self.t += seconds


def run(replies: list[list[dict[str, str]]], *, timeout: str = "600") -> int:
    """Drive main() over a scripted series of polls, all at one commit."""
    clock = FakeClock()
    remaining = list(replies)

    def poll(_number: str) -> Poll:
        rows = remaining.pop(0) if len(remaining) > 1 else remaining[0]
        return Poll(head_sha=HEAD_SHA, rows=rows)

    return main(
        ["7", "--timeout", timeout, "--interval", "30"],
        poll=poll, now=clock.now, sleep=clock.sleep,
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


def test_gh_being_unusable_throughout_exits_unusable() -> None:
    """A failure that does not clear is still unusable, and says so.

    It is no longer instant: a few attempts are made first, because one
    momentary API error is not evidence that gh cannot be asked. What must not
    change is the verdict when the failure persists.
    """
    def poll(_number: str) -> Poll:
        raise GhUnusable("gh: authentication required")

    clock = FakeClock()
    code = main(["7", "--timeout", "600", "--interval", "30"],
                poll=poll, now=clock.now, sleep=clock.sleep,
                workflows=WORKFLOWS, out=lambda _line: None)
    assert code == EXIT_UNUSABLE
    # Bounded: a permanent failure costs seconds, not the whole timeout.
    assert 0 < clock.t <= 30


def test_one_transient_gh_failure_does_not_end_the_wait() -> None:
    """#657. A single HTTP 503 four minutes into a 2400 second wait ended it.

    The refusal to guess a verdict is right and stays. What was wrong is that
    one momentary outage counted as evidence gh could not be asked at all, so a
    GitHub wobble cost a full restart, and during a real incident, which is when
    a status is hardest to read by hand, the wait could never finish.
    """
    replies: list[object] = [
        GhUnusable("HTTP 503: No server is currently available"),
        real_reply(),
    ]

    def poll(_number: str) -> Poll:
        nxt = replies.pop(0) if len(replies) > 1 else replies[0]
        if isinstance(nxt, GhUnusable):
            raise nxt
        return Poll(head_sha=HEAD_SHA, rows=nxt)

    clock = FakeClock()
    code = main(["7", "--timeout", "600", "--interval", "30"],
                poll=poll, now=clock.now, sleep=clock.sleep,
                workflows=WORKFLOWS, out=lambda _line: None)
    assert code == EXIT_GREEN


def test_a_retried_failure_is_said_out_loud() -> None:
    """A retry nobody can see is indistinguishable from a wait that stalled."""
    lines: list[str] = []

    def poll(_number: str) -> Poll:
        raise GhUnusable("HTTP 503: No server is currently available")

    clock = FakeClock()
    main(["7", "--timeout", "600", "--interval", "30"],
         poll=poll, now=clock.now, sleep=clock.sleep,
         workflows=WORKFLOWS, out=lines.append)
    assert any("retr" in line.lower() for line in lines), lines
    assert any("503" in line for line in lines), lines


def test_retrying_does_not_run_past_the_deadline() -> None:
    """The deadline is the deadline. Retries live inside it, not beside it."""
    def poll(_number: str) -> Poll:
        raise GhUnusable("HTTP 503: No server is currently available")

    clock = FakeClock()
    main(["7", "--timeout", "1", "--interval", "30"],
         poll=poll, now=clock.now, sleep=clock.sleep,
         workflows=WORKFLOWS, out=lambda _line: None)
    assert clock.t <= 30


def test_the_default_voice_flushes_every_line() -> None:
    """Caught live on 2026-08-17 running this against #671 in the background.

    Every progress line here exists so a wait that is working and a wait that
    has stalled do not look identical (L106), and Python block-buffers stdout
    the moment it is not a terminal, which is precisely how a long wait is run.
    The output file stayed empty for the whole wait.
    """
    class Recorder:
        def __init__(self) -> None:
            self.written = ""
            self.flushes = 0

        def write(self, text: str) -> int:
            self.written += text
            return len(text)

        def flush(self) -> None:
            self.flushes += 1

    recorder = Recorder()
    original = sys.stdout
    sys.stdout = recorder  # type: ignore[assignment]
    try:
        say("120s elapsed at 84e9dbf2b774")
    finally:
        sys.stdout = original

    assert "120s elapsed" in recorder.written
    assert recorder.flushes >= 1, "the line was written and left in the buffer"


def test_the_wait_speaks_through_the_flushing_voice_by_default() -> None:
    """A flushing printer nothing calls is a wait that still says nothing (L3)."""
    assert inspect.signature(main).parameters["out"].default is say


def test_every_exit_code_is_distinct() -> None:
    codes = [EXIT_GREEN, EXIT_RED, EXIT_NEVER_APPEARED, EXIT_STILL_RUNNING,
             EXIT_UNUSABLE]
    assert len(set(codes)) == len(codes)


def test_the_wait_says_what_it_was_waiting_for() -> None:
    """A timeout with no subject named is a hang wearing a message (L110)."""
    lines: list[str] = []
    clock = FakeClock()
    main(["7", "--timeout", "60", "--interval", "30"],
         poll=lambda _n: Poll(head_sha=HEAD_SHA, rows=[]),
         now=clock.now, sleep=clock.sleep,
         workflows=WORKFLOWS, out=lines.append)
    said = "\n".join(lines)
    assert "Tests / python" in said
    assert "60" in said


def test_every_verdict_names_the_commit_it_judged() -> None:
    """So a green can be checked against the commit about to be merged."""
    lines: list[str] = []
    clock = FakeClock()
    code = main(["7", "--timeout", "600", "--interval", "30"],
                poll=lambda _n: Poll(head_sha=HEAD_SHA, rows=real_reply()),
                now=clock.now, sleep=clock.sleep,
                workflows=WORKFLOWS, out=lines.append)
    assert code == EXIT_GREEN
    assert HEAD_SHA[:12] in lines[-1], lines[-1]


def test_a_commit_landing_mid_wait_is_said_out_loud_and_judged_afresh() -> None:
    """A green earned by the old commit is not a green for the new one.

    Silently carrying on would answer about a commit nothing had run against,
    which is the same defect one push later.
    """
    lines: list[str] = []
    clock = FakeClock()
    seen = [Poll(head_sha=OTHER_SHA, rows=[]),
            Poll(head_sha=HEAD_SHA, rows=real_reply())]

    def poll(_number: str) -> Poll:
        return seen.pop(0) if len(seen) > 1 else seen[0]

    code = main(["7", "--timeout", "600", "--interval", "30"],
                poll=poll, now=clock.now, sleep=clock.sleep,
                workflows=WORKFLOWS, out=lines.append)
    said = "\n".join(lines)
    assert code == EXIT_GREEN
    assert OTHER_SHA[:12] in said and HEAD_SHA[:12] in said, said
    assert "moved" in said, said
