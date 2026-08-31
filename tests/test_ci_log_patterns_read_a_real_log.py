"""Every pattern that reads a CI log is held to a real one (#1085).

`tools/check_job_durations.py` reads each job's log by regex twice over:
`WORK_PATTERNS` for how much work the job did, which is what makes the duration
series a rate rather than a total (#1039), and `FAILURE_PATTERNS` for which
tests failed (#1060, the flake counter). A pattern that stops matching returns
None or an empty set, and both tools are built to treat that as "could not
measure" rather than as an error, so the failure is quiet by design at the call
site and had nothing watching it upstream.

Two format moves have already happened and both were invisible:

* a check for passing Swift tests written as `Test Case '...' passed` found ZERO
  on a run that passed 2,610, because parallel running prints
  `Test case '...' passed on '<worker>'`. Noticed by hand while reading a suite
  result;
* every pytest failure pattern was anchored as `^FAILED`, and matched ZERO on
  every log there has ever been, because GitHub's raw job log prefixes each line
  with an ISO 8601 timestamp. The flake counter had never counted a single
  failure, and nothing said so. Found by running the pattern over a recorded log
  while writing this file.

The whole point is that these run against a log the producer actually made, not
against one written here to match. A fixture shaped so the rule fires proves
nothing about the rule (L48).
"""

from __future__ import annotations

import re

import pytest

from ci_log_fixtures import (
    FAILURE_EVIDENCE,
    REPO_ROOT,
    WORK_EVIDENCE,
    holds,
    manifest,
    recorded,
)
from tools.check_job_durations import (
    FAILURE_PATTERNS,
    WORK_PATTERNS,
    failed_tests,
    work_done,
)


# ── no family is exempt (L96, L129) ──────────────────────────────────────────

def test_every_work_pattern_has_a_recorded_log():
    """A family nobody recorded a log for is a family whose pattern nothing
    checks, which is the state every one of them was in until now."""
    unheld = sorted(set(WORK_PATTERNS) - set(WORK_EVIDENCE))
    assert not unheld, (
        f"these job families have a work pattern and no recorded log to hold it "
        f"to: {unheld}. Record one with tools/record_ci_log.py and name it in "
        "WORK_EVIDENCE, or the pattern can stop matching with nothing saying so."
    )


def test_every_failure_pattern_has_a_recorded_log():
    unheld = sorted(set(FAILURE_PATTERNS) - set(FAILURE_EVIDENCE))
    assert not unheld, (
        f"these job families have a failure pattern and no recorded log to hold "
        f"it to: {unheld}. Record one with tools/record_ci_log.py and name it in "
        "FAILURE_EVIDENCE."
    )


def test_every_named_log_is_actually_recorded():
    """The other direction: a name in the maps above that no file backs would
    make the two tests above pass while checking nothing."""
    for family, name in sorted({**WORK_EVIDENCE, **FAILURE_EVIDENCE}.items()):
        assert name in manifest()["logs"], (
            f"{family} names the recorded log {name}, which the manifest does "
            "not describe"
        )
        assert recorded(name), f"{name} decompressed to nothing"


# ── the work patterns, against real logs ─────────────────────────────────────

@pytest.mark.parametrize("family", sorted(WORK_EVIDENCE))
def test_the_work_pattern_reads_the_recorded_log(family: str):
    name = WORK_EVIDENCE[family]
    expected = holds(name)["work"]
    found = work_done(recorded(name), family)
    assert found == expected, (
        f"{family}'s work pattern {WORK_PATTERNS[family][0]!r} read {found} out "
        f"of the recorded {name} log, and the log says {expected} "
        f"({holds(name)['read_off']}). A pattern that stops matching returns "
        "None, which every caller treats as 'could not measure', so this is the "
        "only thing that would say so."
    )


# ── the failure patterns, against real logs that HOLD failures ───────────────

@pytest.mark.parametrize("family", sorted(FAILURE_EVIDENCE))
def test_the_failure_pattern_has_something_to_find(family: str):
    """A green log is no evidence.

    It holds no failures, so a pattern that can never match reports the same
    empty set as one that works (L159).
    """
    name = FAILURE_EVIDENCE[family]
    assert holds(name)["failed_tests"], (
        f"{family}'s failure pattern is held to {name}, which recorded no "
        "failures, so the check below passes whether the pattern works or not"
    )


@pytest.mark.parametrize("family", sorted(FAILURE_EVIDENCE))
def test_the_failure_pattern_reads_the_recorded_log(family: str):
    name = FAILURE_EVIDENCE[family]
    expected = set(holds(name)["failed_tests"])
    found = failed_tests(recorded(name), family)
    assert found == expected, (
        f"{family}'s failure pattern {FAILURE_PATTERNS[family]!r} read "
        f"{sorted(found)} out of the recorded {name} log, and the log says "
        f"{sorted(expected)} ({holds(name)['read_off']}). An empty set is what "
        "the flake counter treats as a clean run, which is how this stayed "
        "broken from the day it shipped."
    )


# ── the timestamps are the thing (L48) ───────────────────────────────────────

#: GitHub's raw job log opens with a UTF-8 byte order mark and then prefixes
#: every line with an ISO 8601 timestamp. Both are kept in the fixtures because
#: both are what the pattern actually meets.
A_GITHUB_TIMESTAMP = re.compile(
    r"^\ufeff?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z ")


@pytest.mark.parametrize("name", sorted(manifest()["logs"]))
def test_the_recorded_log_still_carries_its_timestamps(name: str):
    """The worse defect was an anchored pattern meeting a prefixed line.

    A fixture with the prefix stripped would pass that pattern and prove
    nothing, so this asserts the fixtures are still the raw thing.
    """
    first = recorded(name).split("\n", 1)[0]
    assert A_GITHUB_TIMESTAMP.match(first), (
        f"the recorded log {name} no longer starts with GitHub's timestamp "
        f"prefix: {first[:80]!r}. Stripping it makes an anchored pattern pass "
        "here and fail in CI, which is the defect this file exists for."
    )


def test_an_anchored_pattern_would_be_caught_here():
    """The positive control on this whole file.

    Written as the pattern that WAS in the repository, so the check that would
    have caught it is shown catching it rather than asserted to (L1). If this
    ever goes red, GitHub stopped prefixing its logs and the story above needs
    rewriting, not the pattern.
    """
    log = recorded("python-red")
    assert re.findall(r"^FAILED (\S+)", log, re.M) == [], (
        "the anchored pattern now matches a real log, so the reason this file "
        "exists has changed"
    )
    assert re.findall(r"FAILED (\S+::\S+)", log), (
        "nothing in the recorded log looks like a pytest FAILED line at all, so "
        "this fixture is not evidence of anything"
    )


# ── the one format left unmatched, tied to the thing that decides it ─────────

PARALLEL_FLAG = "-parallel-testing-enabled YES"
SWIFT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"


def test_the_swift_pattern_matches_the_format_the_workflow_asks_for():
    """`swift-unit`'s failure pattern reads the PARALLEL runner's form,
    `Test case 'Class.method()' failed on '<worker>'`.

    The serial runner printed `Test Case '-[Module.Class method]' failed` and is
    deliberately not matched, because the suite has run in parallel since #992
    and a pattern covering a form nothing produces is a pattern nothing can
    check.

    That leaves one way for this to break silently, which is the very thing this
    file exists to prevent: turn parallel running off and the live logs go back
    to the serial form while the recorded fixture, still parallel, keeps every
    check here green. So the pattern is tied to the flag that decides the
    format rather than to a comment saying which one is in use (L27, L316).
    """
    workflow = SWIFT_WORKFLOW.read_text(encoding="utf-8")
    assert PARALLEL_FLAG in workflow, (
        f"swift.yml no longer passes `{PARALLEL_FLAG}`, so the runner is back "
        "to the SERIAL format, `Test Case '-[Module.Class method]' failed`, "
        "which FAILURE_PATTERNS['swift-unit'] does not match. The flake counter "
        "would report every run clean with nothing saying so. Either restore "
        "the flag, or widen the pattern and record a red serial log to hold it "
        "to."
    )
    # And the recorded log really is from a parallel run, so the fixture and the
    # flag are describing the same thing rather than agreeing by accident.
    assert " failed on '" in recorded("swift-red"), (
        "the recorded swift-red log carries no parallel-mode failure line, so "
        "it is not evidence for the pattern above"
    )
