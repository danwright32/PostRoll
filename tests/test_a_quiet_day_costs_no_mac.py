"""The sweep asks whether it has anything to prove BEFORE taking a Mac (#1259).

`check_guard_sweep_due.py` exists so a day with nothing to prove costs nothing.
It was the first step of each of the seven macOS shards, which means a quiet day
still started seven macOS runners to be told seven times that there was nothing
to do.

That reads as almost free and is not, because GitHub bills every job rounded UP
to a whole minute and a macOS minute draws TEN from the allowance (L306, L310).
Measured on the 2026-09-04 sweep: the steps that run whatever the answer is come
to 21 seconds, which bills as one minute, so seven shards cost 70 allowance
minutes a day. Over a month that is 2,100 against the 2,000 a private repository
on the free plan gets. A completely quiet month, with nothing proved at all,
would spend the whole allowance asking a question whose answer is "nothing".

So the question is asked ONCE, in a job that runs on Linux, and the macOS
shards depend on it. A quiet day is then one ubuntu job: one billed minute at a
multiplier of one, 30 a month rather than 2,100.

These assertions are structural rather than textual: they read the workflow
through the same job parser `wait_for_checks.py` derives the merge bar with,
so a step moving between jobs is visible here rather than being matched
wherever it happens to appear in the file (L135).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tools.wait_for_checks import (
    UnreadableWorkflow, _job_blocks, _skips_on_pull_request)

from source_text import without_prose

REPO_ROOT = Path(__file__).resolve().parent.parent
GUARDS = REPO_ROOT / ".github" / "workflows" / "guards.yml"

#: Asking for the WHOLE sweep, before any Mac is taken. `--shards`, plural.
DUE_TOOL = "check_guard_sweep_due.py --shards"
#: Asking for ONE shard, inside it. Singular, and deliberately still there: it
#: is what keeps a shard that was already proved from redoing its share when a
#: neighbour is the reason the sweep ran.
PER_SHARD_TOOL = "check_guard_sweep_due.py --shard "
#: The step that costs the money, identified by the sweep's OWN deadline.
#:
#: Not "check_guards.py", which the pull request leg runs too, and not a
#: spelling of the whole command: #1344 wrapped that across lines to
#: interpolate the shard width, and a guard keyed on "check_guards.py --shard"
#: then matched nothing and passed by finding nothing (L98, L100). 1,800
#: seconds is the full sweep's deadline and the diff leg's is 900, so this
#: names one job and says which.
SWEEP_TOOL = "--deadline-seconds 1800"


@pytest.fixture
def jobs() -> dict[str, str]:
    # Through without_prose, because the comments in guards.yml describe every
    # construct these tests hunt for, and a raw read is answered by the
    # description as readily as by the code (L103, L135).
    found = dict(_job_blocks(without_prose(GUARDS)))
    assert found, (
        "no jobs could be read out of guards.yml, so every assertion below "
        "would pass by finding nothing (L98, L100)")
    return found


def _job_running(jobs: dict[str, str], needle: str) -> tuple[str, str]:
    """The one job whose body runs `needle`."""
    hits = [(name, body) for name, body in jobs.items() if needle in body]
    assert len(hits) == 1, (
        f"expected exactly one job in guards.yml to run {needle!r}, found "
        f"{[name for name, _ in hits]}. Two jobs running it means two places "
        f"decide the same thing (L370); none means this file is guarding "
        f"something that is no longer there")
    return hits[0]


def _runner(body: str) -> str:
    found = re.search(r"^    runs-on:[ \t]*(.+?)[ \t]*$", body, re.M)
    assert found, "a job in guards.yml declares no runner"
    return found.group(1)


def test_the_question_is_asked_off_the_mac(jobs):
    """The whole point. A question asked from a macOS runner has already spent
    the minute it exists to save."""
    name, body = _job_running(jobs, DUE_TOOL)

    assert "ubuntu" in _runner(body), (
        f"the {name!r} job asks whether the sweep has anything to prove on "
        f"{_runner(body)!r}. Every job bills a whole minute and a macOS minute "
        f"draws ten, so asking there costs 70 allowance minutes a day and the "
        f"answer on a quiet day is that there was nothing to do (#1259)")


def test_the_question_is_asked_once_rather_than_once_per_shard(jobs):
    """Seven shards asking separately is seven macOS runners, which is the
    defect. One answer for the sweep is one runner."""
    name, body = _job_running(jobs, DUE_TOOL)

    assert "strategy:" not in body and "matrix:" not in body, (
        f"the {name!r} job asks the question across a matrix, so it is asked "
        f"once per shard again and the saving is undone")


def test_the_per_shard_gate_is_kept_inside_the_shards(jobs):
    """The two gates answer different questions and both are needed.

    Without the per-shard one, a single shard left unproved by its deadline
    makes the whole sweep due, and the other six redo a share they have already
    proved: 25 minutes of Mac to re-establish something already true.
    """
    sweep_name, sweep = _job_running(jobs, SWEEP_TOOL)

    assert PER_SHARD_TOOL in sweep, (
        f"{sweep_name!r} no longer asks whether THIS shard has anything to do, "
        f"so every shard runs whenever any one of them is due")


def test_the_mac_shards_do_not_start_unless_there_is_something_to_prove(jobs):
    """`needs` alone is not enough: a job that merely waits still runs."""
    due_name, _ = _job_running(jobs, DUE_TOOL)
    sweep_name, sweep = _job_running(jobs, SWEEP_TOOL)

    assert "macos" in _runner(sweep), (
        f"{sweep_name!r} no longer asks for a Mac, so this file is measuring "
        f"something other than the cost it was written about")

    needs = re.search(r"^    needs:[ \t]*(.+?)[ \t]*$", sweep, re.M)
    assert needs and due_name in needs.group(1), (
        f"{sweep_name!r} does not depend on {due_name!r}, so the shards start "
        f"before anything has decided whether they should")

    condition = re.search(r"^    if:[ \t]*(.+?)[ \t]*$", sweep, re.M)
    assert condition and due_name in condition.group(1), (
        f"{sweep_name!r} depends on {due_name!r} but does not read its answer, "
        f"so it waits for the decision and then ignores it: every quiet day "
        f"still takes seven Macs (L197)")


def test_the_shards_condition_is_still_one_the_merge_bar_can_read(jobs):
    """`wait_for_checks.py` derives which checks a pull request must clear from
    these files, and REFUSES a condition it cannot classify rather than
    guessing. A job wrongly expected to run blocks the wait forever.

    So the condition above is not free to be written any way at all, and this
    is the test that says so before a merge does.
    """
    sweep_name, sweep = _job_running(jobs, SWEEP_TOOL)

    try:
        skips = _skips_on_pull_request(sweep_name, sweep)
    except UnreadableWorkflow as exc:
        pytest.fail(
            f"the merge bar cannot classify {sweep_name!r}'s condition, so no "
            f"pull request can be waited on: {exc}")
    assert skips, (
        f"{sweep_name!r} is now expected to RUN on a pull request, which would "
        f"put the whole sweep on the critical path of every change")


def test_what_must_be_said_whatever_the_answer_is_said_off_the_mac(jobs):
    """The sweep's own watchdogs.

    `check_guard_sweep_freshness.py` exists because a schedule's failure mode
    is silence: GitHub disables a repository's schedules after 60 days with no
    push and reports that nowhere (#554). Left inside the macOS shards it would
    only speak on the days the sweep ran, which is precisely not the question
    it asks (L98, L144).
    """
    due_name, due = _job_running(jobs, "check_guard_sweep_freshness.py")
    asked_name, _ = _job_running(jobs, DUE_TOOL)

    assert due_name == asked_name, (
        f"whether the sweep is still running at all is asked from "
        f"{due_name!r}, which does not run on a quiet day, so the watchdog "
        f"goes quiet at exactly the same time as the thing it watches")
    assert "ubuntu" in _runner(due)


def test_a_quiet_day_takes_no_mac_at_all(jobs):
    """The measurement this file is named for, stated as a rule.

    Every job that asks for a Mac must be downstream of the decision. If one is
    not, a quiet day costs a billed macOS minute again, and the arithmetic that
    makes this worth doing is per JOB rather than per minute of work.
    """
    due_name, _ = _job_running(jobs, DUE_TOOL)

    ungated = []
    for name, body in jobs.items():
        if "macos" not in _runner(body):
            continue
        condition = re.search(r"^    if:[ \t]*(.+?)[ \t]*$", body, re.M)
        text = condition.group(1) if condition else ""
        # The pull request leg is a different question: it is paid for by a
        # change actually being made, not by the clock.
        if "github.event_name == 'pull_request'" in text:
            continue
        if due_name not in text:
            ungated.append(name)

    assert not ungated, (
        f"{ungated} ask for a macOS runner on a schedule without waiting to "
        f"hear whether there is anything to prove. Each one costs a whole "
        f"billed minute at a multiplier of ten, every day, whatever it finds")
