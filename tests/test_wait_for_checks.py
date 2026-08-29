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
    EXIT_BEHIND,
    EXIT_GREEN,
    EXIT_NEVER_APPEARED,
    EXIT_NOT_MERGED,
    EXIT_RED,
    EXIT_STILL_RUNNING,
    EXIT_UNUSABLE,
    BaseStanding,
    ExpectedCheck,
    GhUnusable,
    MergeRefused,
    Poll,
    UnreadableWorkflow,
    base_standing,
    bucket_of,
    expected_checks,
    main,
    merge_commit,
    parse_arguments,
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
             EXIT_UNUSABLE, EXIT_NOT_MERGED, EXIT_BEHIND]
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


# ── merging the commit that was judged ────────────────────────────────────────


# The recorded comparisons and the stand-in for them live here rather than
# beside their own tests further down, because the merge harness below needs
# the stand-in: since #680 a merge crosses the base comparison on its way.
REAL_BEHIND = REPO_ROOT / "tests" / "fixtures" / "gh_compare_behind_real.json"
REAL_AHEAD = REPO_ROOT / "tests" / "fixtures" / "gh_compare_ahead_real.json"

#: Where main was when the two comparisons above were recorded, on 2026-08-17.
MAIN_SHA = "063877ef94c8710b27018261240a811f696dffd6"
#: A commit two behind that main, which is what a stale branch looks like.
STALE_SHA = "7b510ea33af5f6fbe5db8dd0b1bcd8d1e9e12cd0"


def real_compare(name: str) -> dict:
    path = REAL_BEHIND if name == "behind" else REAL_AHEAD
    return json.loads(path.read_text(encoding="utf-8"))


class FakeStanding:
    """Stands in for the comparison against the base branch."""

    def __init__(self, *, behind_by: int = 0, raising: Exception | None = None) -> None:
        self.behind_by = behind_by
        self.raising = raising
        self.asked: list[tuple[str, str]] = []

    def __call__(self, number: str, sha: str) -> BaseStanding:
        self.asked.append((number, sha))
        if self.raising:
            raise self.raising
        return BaseStanding(branch="main", base_sha=MAIN_SHA,
                            behind_by=self.behind_by, ahead_by=1)


class FakeMerge:
    """Stands in for the call that merges, recording what it was asked to merge."""

    def __init__(self, *, refusing: str | None = None) -> None:
        self.refusing = refusing
        self.asked: list[tuple[str, str]] = []

    def __call__(self, number: str, sha: str) -> str:
        self.asked.append((number, sha))
        if self.refusing:
            raise MergeRefused(self.refusing)
        return sha


def wait_and_merge(
    replies: list[list[dict[str, str]]],
    *,
    merge: FakeMerge,
    argv: list[str] | None = None,
    lines: list[str] | None = None,
    heads: list[str] | None = None,
    base: "FakeStanding | None" = None,
) -> int:
    """Drive main() to a verdict with the merge step wired to a fake.

    The base comparison (#680) is a precondition of the merge rather than the
    subject of these tests, so it stands in as a branch that contains its base.
    The tests below it are the ones that vary it.
    """
    clock = FakeClock()
    remaining = list(replies)
    seen = list(heads or [HEAD_SHA])

    def poll(_number: str) -> Poll:
        rows = remaining.pop(0) if len(remaining) > 1 else remaining[0]
        head = seen.pop(0) if len(seen) > 1 else seen[0]
        return Poll(head_sha=head, rows=rows)

    return main(
        argv or ["7", "--timeout", "600", "--interval", "30", "--merge"],
        poll=poll, merge=merge, base=base or FakeStanding(behind_by=0),
        now=clock.now, sleep=clock.sleep,
        workflows=WORKFLOWS, out=(lines.append if lines is not None else lambda _l: None))


def test_the_merge_is_of_exactly_the_commit_that_was_judged_green() -> None:
    """The whole point: the merge names a SHA rather than "the top of the branch".

    A push landing in the seconds between the green and the merge otherwise
    merges a commit nothing has judged, which is the one step that cannot be
    undone (#674).
    """
    merge = FakeMerge()

    code = wait_and_merge([real_reply()], merge=merge)

    assert code == EXIT_GREEN
    assert merge.asked == [("7", HEAD_SHA)], merge.asked


def test_the_commit_merged_is_the_last_one_judged_not_the_first_seen() -> None:
    """A commit landing mid-wait is judged afresh, and it is that one that merges."""
    merge = FakeMerge()

    code = wait_and_merge([[], real_reply()], merge=merge,
                          heads=[OTHER_SHA, HEAD_SHA])

    assert code == EXIT_GREEN
    assert merge.asked == [("7", HEAD_SHA)], merge.asked


def test_a_refused_merge_is_reported_as_not_merged_rather_than_as_green() -> None:
    """GitHub refuses with a 409 when the head has moved, which is the case
    this exists for. Reporting green then would be a success claim over a merge
    that did not happen (L12), and the caller's next step is to look, not to
    merge again."""
    merge = FakeMerge(refusing="the head moved to 0ef38b2c1d4e, so nothing merged")
    lines: list[str] = []

    code = wait_and_merge([real_reply()], merge=merge, lines=lines)

    assert code == EXIT_NOT_MERGED
    said = "\n".join(lines)
    assert "not merged" in said, said
    assert "the head moved" in said, said


def test_a_red_verdict_never_reaches_the_merge() -> None:
    rows = real_reply()
    rows[0] = {**rows[0], "bucket": "fail"}
    merge = FakeMerge()

    code = wait_and_merge([rows], merge=merge)

    assert code == EXIT_RED
    assert merge.asked == [], merge.asked


def test_a_deadline_reached_with_work_still_running_never_reaches_the_merge() -> None:
    rows = real_reply()
    rows[0] = dict(rows[0], bucket="pending", state="IN_PROGRESS")
    merge = FakeMerge()

    code = wait_and_merge([rows], merge=merge)

    assert code == EXIT_STILL_RUNNING
    assert merge.asked == [], merge.asked


def test_without_the_flag_a_green_merges_nothing() -> None:
    """The wait stays a wait by default: merging is the irreversible step, so
    it happens only when it was asked for."""
    merge = FakeMerge()

    code = wait_and_merge([real_reply()], merge=merge,
                          argv=["7", "--timeout", "600", "--interval", "30"])

    assert code == EXIT_GREEN
    assert merge.asked == [], merge.asked


class FakeGh:
    """Stands in for the `gh api` subprocess the merge call makes."""

    def __init__(self, *, returncode: int = 0, stdout: str = "",
                 stderr: str = "") -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.argv: list[str] = []

    def __call__(self, argv: list[str], **_kwargs: object) -> "FakeGh":
        self.argv = argv
        return self


def test_the_merge_call_carries_the_sha_github_must_match() -> None:
    """`sha` is what makes this safe by construction: GitHub refuses the merge
    with a 409 when the head is not that commit."""
    gh = FakeGh(stdout=json.dumps({"merged": True, "sha": "aaa111"}))

    merged = merge_commit("7", HEAD_SHA, run=gh)

    assert merged == "aaa111"
    flattened = " ".join(gh.argv)
    assert f"sha={HEAD_SHA}" in flattened, flattened
    assert "PUT" in flattened and "pulls/7/merge" in flattened, flattened


def test_a_merge_github_refuses_is_a_refusal_rather_than_a_merge() -> None:
    gh = FakeGh(returncode=1, stderr="HTTP 409: Head branch was modified")

    with pytest.raises(MergeRefused) as refusal:
        merge_commit("7", HEAD_SHA, run=gh)

    assert "409" in str(refusal.value), refusal.value


def test_a_reply_that_does_not_say_it_merged_is_a_refusal() -> None:
    """gh exiting 0 is not the merge happening. A reply saying `merged: false`
    carries GitHub's own reason, and treating it as done would report a merge
    over a pull request still sitting open (L12)."""
    gh = FakeGh(stdout=json.dumps(
        {"merged": False, "message": "Pull Request is not mergeable"}))

    with pytest.raises(MergeRefused) as refusal:
        merge_commit("7", HEAD_SHA, run=gh)

    assert "not mergeable" in str(refusal.value), refusal.value


def test_a_reply_that_is_not_json_is_a_refusal_rather_than_a_merge() -> None:
    gh = FakeGh(stdout="not json at all")

    with pytest.raises(MergeRefused):
        merge_commit("7", HEAD_SHA, run=gh)


def test_gh_missing_altogether_is_a_refusal() -> None:
    def missing(_argv: list[str], **_kwargs: object) -> object:
        raise FileNotFoundError("gh")

    with pytest.raises(MergeRefused):
        merge_commit("7", HEAD_SHA, run=missing)


def test_the_usage_line_names_the_merge_option() -> None:
    """An option nothing documents is one nobody reaches for."""
    with pytest.raises(GhUnusable) as refusal:
        parse_arguments([])

    assert "--merge" in str(refusal.value), refusal.value


# ── the base the green was earned against ─────────────────────────────────────
#
# #680. Proving one named commit green and merging exactly that commit closes
# the window between the two (#674). It does not close the other one: the
# commit judged may have been tested against a base that has since moved, so
# two changes that are each green against their own base merge into a broken
# main (L85). Until now that was handled by remembering to rebase.

def wait_merge_and_compare(
    *,
    merge: FakeMerge,
    standing: FakeStanding,
    lines: list[str] | None = None,
) -> int:
    clock = FakeClock()
    return main(
        ["7", "--timeout", "600", "--interval", "30", "--merge"],
        poll=lambda _n: Poll(head_sha=HEAD_SHA, rows=real_reply()),
        merge=merge, base=standing, now=clock.now, sleep=clock.sleep,
        workflows=WORKFLOWS,
        out=(lines.append if lines is not None else lambda _l: None))


def test_a_branch_behind_its_base_is_refused_rather_than_merged() -> None:
    """The green was earned against a base that has since moved, so what it
    proves is not what merging would produce (L85)."""
    merge = FakeMerge()
    lines: list[str] = []

    code = wait_merge_and_compare(merge=merge, standing=FakeStanding(behind_by=2),
                                  lines=lines)

    assert code == EXIT_BEHIND
    assert merge.asked == [], merge.asked
    said = "\n".join(lines)
    assert "2 commits behind main" in said, said
    assert MAIN_SHA[:12] in said, said
    # A refusal that does not name a step which changes the state it refuses on
    # leaves the person facing the same command (L111).
    assert "Rebase onto main" in said, said


def test_a_branch_that_contains_its_base_still_merges() -> None:
    """The positive case, in the same harness as the refusal above, because a
    test that something did NOT happen is satisfied by a fixture in which it
    could not happen (L159)."""
    merge = FakeMerge()

    code = wait_merge_and_compare(merge=merge, standing=FakeStanding(behind_by=0))

    assert code == EXIT_GREEN
    assert merge.asked == [("7", HEAD_SHA)], merge.asked


def test_the_comparison_is_taken_at_the_commit_that_was_judged() -> None:
    """Asking about the branch rather than the judged commit would answer for
    whatever is at the top of it by then, which is the defect one step earlier
    (#674)."""
    standing = FakeStanding(behind_by=0)

    wait_merge_and_compare(merge=FakeMerge(), standing=standing)

    assert standing.asked == [("7", HEAD_SHA)], standing.asked


def test_a_comparison_that_cannot_be_taken_refuses_to_merge() -> None:
    """Not knowing whether the base has moved is not the same as it not having
    moved, and the merge is the step that cannot be undone, so this fails
    closed (L42)."""
    merge = FakeMerge()
    lines: list[str] = []

    code = wait_merge_and_compare(
        merge=merge, standing=FakeStanding(raising=GhUnusable("HTTP 503")),
        lines=lines)

    assert code == EXIT_UNUSABLE
    assert merge.asked == [], merge.asked
    said = "\n".join(lines)
    assert "not merged" in said, said
    assert "503" in said, said


def test_without_the_merge_flag_nothing_is_compared() -> None:
    """The wait stays a wait: it is the merge that this refuses, and a plain
    wait asking two more questions of GitHub would fail for reasons that have
    nothing to do with what it was asked."""
    standing = FakeStanding(behind_by=2)
    clock = FakeClock()

    code = main(["7", "--timeout", "600", "--interval", "30"],
                poll=lambda _n: Poll(head_sha=HEAD_SHA, rows=real_reply()),
                base=standing, now=clock.now, sleep=clock.sleep,
                workflows=WORKFLOWS, out=lambda _l: None)

    assert code == EXIT_GREEN
    assert standing.asked == [], standing.asked


def test_the_wait_compares_through_the_real_reading_by_default() -> None:
    """A comparison nothing calls is a rule that lives only in a docstring (L3)."""
    assert inspect.signature(main).parameters["base"].default is base_standing


class CompareApi:
    """Answers the three paths `base_standing` asks, from recorded replies."""

    def __init__(self, *, compare: dict, branch: str = "main",
                 tip: str = MAIN_SHA) -> None:
        self.compare = compare
        self.branch = branch
        self.tip = tip
        self.paths: list[str] = []

    def __call__(self, path: str) -> dict:
        self.paths.append(path)
        if "/pulls/" in path:
            return {"head": {"sha": STALE_SHA},
                    "base": {"ref": self.branch, "repo": {"full_name": REPO}}}
        if "/compare/" in path:
            return self.compare
        if "/commits/" in path:
            return {"sha": self.tip}
        raise AssertionError(f"the tool asked for a path nothing recorded: {path}")


def test_a_real_reply_about_a_stale_branch_reads_as_behind() -> None:
    """GitHub's own reply for a commit two behind main, recorded 2026-08-17,
    rather than a shape invented here (L48)."""
    api = CompareApi(compare=real_compare("behind"))

    standing = base_standing("7", STALE_SHA, api=api)

    assert standing.behind_by == 2, standing
    assert standing.branch == "main"
    assert standing.base_sha == MAIN_SHA
    # The comparison names the commit judged, not the branch it sits on, so a
    # push landing meanwhile cannot answer for it (L179).
    assert any(STALE_SHA in path for path in api.paths), api.paths


def test_a_real_reply_about_an_up_to_date_branch_reads_as_not_behind() -> None:
    api = CompareApi(compare=real_compare("ahead"))

    standing = base_standing("7", HEAD_SHA, api=api)

    assert standing.behind_by == 0, standing
    assert standing.ahead_by == 1, standing


def test_a_comparison_that_will_not_say_how_far_apart_is_refused() -> None:
    """A missing count must not read as zero: zero is the answer that merges."""
    reply = dict(real_compare("ahead"))
    reply.pop("behind_by")
    api = CompareApi(compare=reply)

    with pytest.raises(GhUnusable) as refusal:
        base_standing("7", HEAD_SHA, api=api)

    assert "behind" in str(refusal.value), refusal.value


def test_a_comparison_whose_two_halves_disagree_is_refused() -> None:
    """`behind_by` and the merge base say the same thing in two ways. When
    they stop agreeing, this reply does not mean what the code reads it to
    mean, and guessing which half is right is how a wrong green ships."""
    reply = dict(real_compare("behind"))
    reply["behind_by"] = 0
    api = CompareApi(compare=reply)

    with pytest.raises(GhUnusable) as refusal:
        base_standing("7", STALE_SHA, api=api)

    assert "merge base" in str(refusal.value), refusal.value


def test_a_pull_request_that_names_no_base_branch_is_refused() -> None:
    api = CompareApi(compare=real_compare("ahead"), branch="")

    with pytest.raises(GhUnusable) as refusal:
        base_standing("7", HEAD_SHA, api=api)

    assert "base branch" in str(refusal.value), refusal.value


def test_a_base_branch_with_no_commit_is_refused() -> None:
    """Where main is now is the whole question, so an answer that does not name
    it is not an answer."""
    api = CompareApi(compare=real_compare("ahead"), tip="")

    with pytest.raises(GhUnusable) as refusal:
        base_standing("7", HEAD_SHA, api=api)

    assert "main" in str(refusal.value), refusal.value


# ── #936: the retry budget scales with the caller's patience ──────────────────
#
# On 2026-08-28 the local machine ran out of network sockets under load from
# several concurrent builds, and `dial tcp ... can't assign requested address`
# persisted past the six seconds the two fixed pauses bought. The tool refused
# correctly rather than inventing an answer, but PR #934 was left open and
# unmerged with nothing watching it, which in an unattended run means work
# silently does not land.
#
# What must not change: it still retries the ASKING and never the verdict, it
# still refuses rather than guessing when the failure does not clear, and it
# still classifies no error as transient. Only the patience widens.


def _always_failing(text: str = "dial tcp 140.82.121.6:443: can't assign requested address"):
    def poll(_number: str) -> Poll:
        raise GhUnusable(text)
    return poll


def _retry_seconds(timeout: str, interval: str = "30") -> float:
    """How long a permanently failing gh is retried for, on the fake clock."""
    clock = FakeClock()
    code = main(["7", "--timeout", timeout, "--interval", interval],
                poll=_always_failing(), now=clock.now, sleep=clock.sleep,
                workflows=WORKFLOWS, out=lambda _line: None)
    assert code == EXIT_UNUSABLE, code
    return clock.t


def test_the_retry_budget_scales_with_how_long_the_caller_would_wait():
    """The whole issue. The budget was two fixed pauses, so a caller willing to
    wait forty minutes got the same six seconds of patience as one willing to
    wait one, and an outage lasting seven seconds ended both."""
    patient = _retry_seconds("2400")
    hurried = _retry_seconds("600")

    assert patient > hurried, (
        f"a 2400s wait retried for {patient}s and a 600s wait for {hurried}s, "
        "so the patience does not scale with what the caller asked for")


def test_an_outage_lasting_longer_than_the_old_six_seconds_no_longer_ends_it():
    """The measured incident, as a case. Six seconds of retrying was the whole
    budget before this, so an error that outlived it ended a 2400 second wait
    and left the pull request with nothing watching it."""
    clock = FakeClock()
    down_until = 45.0

    def poll(_number: str) -> Poll:
        if clock.t < down_until:
            raise GhUnusable(
                "dial tcp 140.82.121.6:443: can't assign requested address")
        return Poll(head_sha=HEAD_SHA, rows=real_reply())

    code = main(["7", "--timeout", "2400", "--interval", "30"],
                poll=poll, now=clock.now, sleep=clock.sleep,
                workflows=WORKFLOWS, out=lambda _line: None)

    assert code == EXIT_GREEN, (
        f"a {down_until:.0f}s outage inside a 2400s wait still ended it")


def test_a_failure_that_does_not_clear_still_ends_well_before_the_deadline():
    """The other half, and the one the widening could quietly destroy.

    gh being genuinely unusable (not installed, not authenticated) must be
    reported while somebody could still act on it, not at the end of a wait
    they would otherwise have spent watching. Asserted as a share of the
    timeout rather than against the budget constant, because a check whose
    expected value comes from the code it checks can only confirm the code
    agrees with itself (L70).
    """
    spent = _retry_seconds("2400")

    assert 0 < spent < 2400 * 0.25, (
        f"a permanent failure cost {spent}s of a 2400s wait, which is no longer "
        "a bounded retry: it is the wait")


def test_no_kind_of_failure_is_retried_differently_from_any_other():
    """The rule the issue says to keep exactly as it is.

    Retrying every failure rather than the ones that look transient is what
    keeps this free of a second, message-matching classifier that would
    eventually disagree with the first one (L35). Two failures that read very
    differently must cost the same patience.
    """
    def spent(text: str) -> float:
        clock = FakeClock()
        main(["7", "--timeout", "600", "--interval", "30"],
             poll=_always_failing(text), now=clock.now, sleep=clock.sleep,
             workflows=WORKFLOWS, out=lambda _line: None)
        return clock.t

    assert spent("HTTP 503: No server is currently available") == spent(
        "gh: authentication required")


def test_the_pauses_grow_rather_than_repeating_one_length():
    """A budget spent as many short pauses is a busy loop against a service
    that is already struggling. It has to back off."""
    pauses: list[float] = []
    clock = FakeClock()

    def sleep(seconds: float) -> None:
        pauses.append(seconds)
        clock.sleep(seconds)

    main(["7", "--timeout", "2400", "--interval", "30"],
         poll=_always_failing(), now=clock.now, sleep=sleep,
         workflows=WORKFLOWS, out=lambda _line: None)

    assert len(pauses) >= 3, pauses
    assert pauses == sorted(pauses), f"the pauses do not grow: {pauses}"
    assert pauses[-1] > pauses[0], f"every pause is the same length: {pauses}"
