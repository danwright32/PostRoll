"""#1011: a red run on main, or on the weekly sweep, told nobody.

No workflow here had any failure path. Most checks run on a pull request, where
a failure blocks the merge and cannot be missed. Two do not: `guards.yml`'s
`full` job runs AFTER the merge has landed, so it cannot gate anything, and the
weekly sweep has no push and no PR behind it at all.

It has happened. On 2026-08-19 the sweep had been dying at 60 minutes for hours
while the run list read as though somebody had superseded those runs, and every
guard had quietly stopped being re-proved.

Nothing here reaches GitHub. Every test drives the tool with a fake `gh` (L2).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from say_when_ci_goes_red import (  # noqa: E402
    LABELS, TITLE, CannotAsk, body, main, open_reports, report)


class FakeGitHub:
    """A `gh` that holds a list of open issues and records what it was asked."""

    def __init__(self, issues=None, fail_on=None, creates_a_race=False):
        self.issues = list(issues or [])
        self.fail_on = fail_on
        self.creates_a_race = creates_a_race
        self.calls: list[list[str]] = []
        self._next = 900

    def __call__(self, args):
        self.calls.append(args)
        verb = args[1] if len(args) > 1 else ""
        action = args[2] if len(args) > 2 else ""
        if self.fail_on and self.fail_on in " ".join(args):
            return subprocess.CompletedProcess(args, 1, "", "boom")
        if verb == "issue" and action == "list":
            return subprocess.CompletedProcess(args, 0, json.dumps(self.issues), "")
        if verb == "issue" and action == "create":
            title = args[args.index("--title") + 1]
            self._next += 1
            self.issues.append({"number": self._next, "title": title})
            if self.creates_a_race:
                # Another shard got there at the same moment.
                self._next += 1
                self.issues.append({"number": self._next, "title": title})
                self.creates_a_race = False
            return subprocess.CompletedProcess(args, 0, "", "")
        if verb == "issue" and action in ("comment", "close"):
            if action == "close":
                number = int(args[3])
                self.issues = [i for i in self.issues if i["number"] != number]
            return subprocess.CompletedProcess(args, 0, "", "")
        raise AssertionError(f"the tool asked gh something unexpected: {args}")

    def did(self, action):
        return [c for c in self.calls if len(c) > 2 and c[2] == action]


RED = dict(workflow="guards.yml", job="full (3)",
           url="https://github.com/x/y/actions/runs/1")


def test_a_first_failure_files_one_issue():
    gh = FakeGitHub()

    did, number = report(**RED, run=gh)

    assert did == "filed"
    assert len(gh.did("create")) == 1
    created = gh.did("create")[0]
    assert created[created.index("--title") + 1] == "CI is red on guards.yml"


def test_a_filed_issue_carries_the_fields_this_repo_requires():
    """Every issue here needs a milestone, a priority and a category. Two of
    the three are labels and can be set at creation; a run that filed one
    without them would be a check the repo's own gate would have refused."""
    gh = FakeGitHub()

    report(**RED, run=gh)

    created = gh.did("create")[0]
    labels = created[created.index("--label") + 1].split(",")
    assert set(labels) == set(LABELS)
    assert "priority-p1" in labels, (
        "a guard that is already dead on main is not a someday item")


def test_a_second_failure_comments_rather_than_filing_again():
    """The whole value of this is that it is worth reading, and the first flaky
    week would teach everybody to skip it (L36)."""
    gh = FakeGitHub([{"number": 42, "title": "CI is red on guards.yml"}])

    did, number = report(**RED, run=gh)

    assert (did, number) == ("commented", 42)
    assert not gh.did("create"), "it filed a second issue for the same workflow"
    assert gh.did("comment")


def test_two_shards_failing_at_once_leave_one_issue():
    """Assume it runs twice (L33). Four shards can go red together and each
    runs this, so two can look, find nothing, and both create."""
    gh = FakeGitHub(creates_a_race=True)

    did, number = report(**RED, run=gh)

    assert did == "deduplicated"
    assert number == min(i["number"] for i in gh.issues + [{"number": number}])
    assert len(gh.did("close")) == 1, "the duplicate was left open"
    assert len([i for i in gh.issues
                if i["title"] == "CI is red on guards.yml"]) == 1


def test_a_report_for_another_workflow_is_not_mistaken_for_this_one():
    """Matched on the exact title, so `swift.yml` going red does not comment on
    the issue about `guards.yml`."""
    gh = FakeGitHub([{"number": 42, "title": "CI is red on swift.yml"}])

    did, _ = report(**RED, run=gh)

    assert did == "filed"


def test_an_issue_a_person_wrote_about_the_same_workflow_is_left_alone():
    """An exact title rather than a search over words (L521). A search would
    match somebody's own report and this would comment on a human's issue
    instead of its own record."""
    gh = FakeGitHub([{"number": 7,
                      "title": "guards.yml is red again and I do not know why"}])

    did, _ = report(**RED, run=gh)

    assert did == "filed"
    assert not gh.did("comment")


def test_the_body_names_the_job_and_the_run():
    """A notice that says a workflow is red and not WHICH run leaves the reader
    to go and find it, which is the work this exists to remove (L80)."""
    text = body(**{k: v for k, v in
                   zip(("workflow", "job", "url"), RED.values())})

    assert "guards.yml" in text
    assert "full (3)" in text
    assert RED["url"] in text


def test_a_broken_token_refuses_rather_than_reporting_nothing_wrong():
    """A run that said "nothing to report" on a broken token would say it every
    time and read as a healthy repository (L11, L98)."""
    gh = FakeGitHub(fail_on="issue list")

    with pytest.raises(CannotAsk):
        open_reports("guards.yml", run=gh)


def test_a_failure_to_record_the_failure_warns_rather_than_going_red(capsys):
    """The job is ALREADY red. A second red step saying nothing about the first
    would bury the thing worth reading under the thing that could not report
    it (L11)."""
    import say_when_ci_goes_red as tool

    tool.subprocess = _AlwaysFails()
    try:
        code = main(["--workflow", "guards.yml", "--job", "full (1)",
                     "--run-url", "https://example.invalid/1"])
    finally:
        import subprocess as real
        tool.subprocess = real

    assert code == 0
    assert "::warning::" in capsys.readouterr().out


class _AlwaysFails:
    @staticmethod
    def run(args, **kwargs):
        return subprocess.CompletedProcess(args, 1, "", "no token")


def test_the_title_is_stable_because_everything_keys_on_it():
    """The dedup, the comment and the close all find the issue by this string.
    Changing it orphans every issue already filed, so it is asserted rather
    than left to be noticed when the list quietly grows a second copy (L186)."""
    assert TITLE.format(workflow="guards.yml") == "CI is red on guards.yml"

# --- it is actually wired into the workflow ----------------------------------

GUARDS = REPO_ROOT / ".github" / "workflows" / "guards.yml"


def _job(name: str) -> str:
    """One job's own text, so a check about `full` is not answered by `changed`.

    A rule matched over a whole file is satisfied by any occurrence in it, and
    with two jobs in one file that is exactly how a step present in the wrong
    one reads as present (L135).
    """
    text = GUARDS.read_text(encoding="utf-8")
    start = text.index(f"\n  {name}:\n")
    rest = text[start + 1:]
    following = [rest.index(f"\n  {other}:\n")
                 for other in ("changed", "full") if other != name
                 and f"\n  {other}:\n" in rest]
    return rest[:min(following)] if following else rest


def test_the_job_that_cannot_gate_anything_reports_its_own_failure():
    """Built is not wired (L3). Every check above drives the tool directly; this
    is the one that says the workflow calls it, because a reporter nothing runs
    reports nothing while all of them pass."""
    full = _job("full")

    assert "say_when_ci_goes_red.py" in full, (
        "the `full` job does not run the failure reporter, so a red run on "
        "main still reaches nobody (#1011)")


def test_the_reporter_speaks_only_when_something_is_wrong():
    """`failure()`, not `always()`. A notice on every green run is what teaches
    a person to skip the whole list (L36)."""
    full = _job("full")
    at = full.index("say_when_ci_goes_red.py")
    step = full[full.rindex("- name:", 0, at):at]

    assert "if: failure()" in step, (
        "the reporter runs on more than a failure, so it would file or comment "
        "on green runs too")


def test_the_reporter_runs_on_every_shard():
    """Unlike the two steps beside it, which ask a question about the workflow
    and are pinned to shard 1. This REPORTS a failure, and shard 3 going red
    while shard 1 is green is exactly the case that must not be silent (L120)."""
    full = _job("full")
    at = full.index("say_when_ci_goes_red.py")
    step = full[full.rindex("- name:", 0, at):at]

    assert "matrix.shard == 1" not in step, (
        "the reporter is pinned to one shard, so a failure on any other shard "
        "is silent, which is the defect this exists to fix")


def test_the_job_may_actually_write_an_issue():
    """A reporter without the permission fails at the last step, and it fails
    inside an already red job where nobody is looking for a second reason
    (L503)."""
    full = _job("full")

    assert "issues: write" in full, (
        "the `full` job cannot open an issue, so the reporter would refuse "
        "every time and the failure would still reach nobody")


def test_the_reporter_is_told_which_run_it_is_reporting():
    """A notice that says a workflow is red and not WHICH run leaves the reader
    to go and find it, which is the work this removes (L80)."""
    full = _job("full")
    at = full.index("say_when_ci_goes_red.py")
    step = full[at:at + 500]

    assert "--run-url" in step and "github.run_id" in step
    assert "--job" in step and "matrix.shard" in step, (
        "the report names no shard, so it cannot say which part went red")


def test_the_job_reading_this_is_the_one_that_cannot_gate():
    """The control on `_job`. If it returned the wrong job, or the whole file,
    every check above would be answered by the wrong text (L100)."""
    full, changed = _job("full"), _job("changed")

    assert "github.event_name != 'pull_request'" in full
    assert "github.event_name == 'pull_request'" in changed
    assert "say_when_ci_goes_red.py" not in changed, (
        "the reporter is in the pull request job, where a failure already "
        "blocks the merge and is impossible to miss, so it would file an issue "
        "about something somebody is already looking at (L36)")

# --- the class, not the one instance ----------------------------------------

WORKFLOWS = sorted((REPO_ROOT / ".github" / "workflows").glob("*.yml"))

#: Workflows that cannot go red without somebody having asked for the run, and
#: why each (L233).
#:
#: A run somebody started by hand is a run somebody is watching, so filing an
#: issue about it would tell them what they are already looking at, and the
#: first such notice is what teaches a person to skip the whole list (L36).
BY_HAND_ONLY: dict[str, str] = {
    "ci-profile.yml":
        "workflow_dispatch only: it exists to be run by hand when somebody "
        "wants a build profile, so its failures already have a reader",
    "record-durations.yml":
        "workflow_dispatch only, and it is the tool somebody runs deliberately "
        "when the durations record needs re-taking",
}


def _jobs(text: str) -> dict[str, str]:
    """Each job's own text, keyed by name."""
    starts = [(m.group(1), m.start() + 1)
              for m in re.finditer(r"\n  ([a-z][a-z0-9-]*):\n", text)]
    # `on:` keys sit at the same indent, so a job is one that has steps.
    found = {}
    for i, (name, at) in enumerate(starts):
        end = starts[i + 1][1] - 1 if i + 1 < len(starts) else len(text)
        body = text[at:end]
        if "\n    steps:\n" in body:
            found[name] = body
    return found


def test_the_job_reader_finds_the_jobs_that_are_really_there():
    """The positive control. A reader finding no jobs would report every
    workflow as covered (L98, L100)."""
    guards = _jobs(GUARDS.read_text(encoding="utf-8"))

    assert set(guards) >= {"changed", "full"}, (
        f"the reader found {sorted(guards)} in guards.yml, which is not this "
        f"workflow")
    assert "say_when_ci_goes_red" in guards["full"]
    assert "say_when_ci_goes_red" not in guards["changed"]


def test_every_job_that_cannot_gate_a_merge_says_so_when_it_goes_red():
    """The class, not the one instance #1011 was reported about (L30).

    A job is covered when a pull request failing it blocks the merge. Everything
    else runs after the merge has landed, on a schedule with no push behind it,
    or on another workflow finishing, and a failure there reached nobody at all.
    """
    silent = []
    for path in WORKFLOWS:
        if path.name in BY_HAND_ONLY:
            continue
        text = path.read_text(encoding="utf-8")
        header = text[:text.index("jobs:")] if "jobs:" in text else text
        for name, job_body in _jobs(text).items():
            gated = ("pull_request:" in header
                     and "github.event_name == 'pull_request'" in job_body)
            if gated or "say_when_ci_goes_red" in job_body:
                continue
            silent.append(f"{path.name}:{name}")

    assert not silent, (
        "these jobs can go red without blocking anything, so the failure sits "
        "in the Actions tab until somebody opens it, which is how every guard "
        "in the registry stopped being re-proved for hours on 2026-08-19 "
        f"(#1011, L13): {silent}")


def test_every_by_hand_exemption_names_a_workflow_that_is_by_hand_only():
    """A stale entry excuses a real failure silently, and it reads as a
    considered decision the whole time (L217, L233)."""
    wrong = []
    for name, why in BY_HAND_ONLY.items():
        path = REPO_ROOT / ".github" / "workflows" / name
        if not path.is_file():
            wrong.append(f"{name} is gone, so this excuses nothing")
            continue
        text = path.read_text(encoding="utf-8")
        header = text[:text.index("jobs:")]
        triggers = {line.strip().rstrip(":")
                    for line in header.splitlines()
                    if line.startswith("  ") and line.strip().endswith(":")}
        if triggers - {"on", "workflow_dispatch"}:
            wrong.append(f"{name} now runs on {sorted(triggers)}, not by hand "
                         f"alone. Its reason was: {why}")

    assert not wrong, "\n".join(wrong)


def test_every_reporter_names_its_own_workflow():
    """A report filed under the wrong name comments on another workflow's
    issue, and both then read as one thing being broken (L11)."""
    wrong = []
    for path in WORKFLOWS:
        text = path.read_text(encoding="utf-8")
        for at in [m.start() for m in re.finditer(r"say_when_ci_goes_red\.py", text)]:
            call = text[at:at + 400]
            if f"--workflow {path.name}" not in call:
                wrong.append(f"{path.name} reports under another name")

    assert not wrong, "\n".join(wrong)
