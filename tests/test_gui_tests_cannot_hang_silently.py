"""A GUI test that hangs has to fail, not wedge the job (#877).

Measured on 2026-08-23, run 32673163649: one UI test stopped responding inside
an accessibility query, two seconds into a test that had passed on the previous
run of the same file. The job then sat in that step for 35 minutes and reported
nothing at all, because a run's log is not readable until it finishes and this
one never would have, short of the workflow's own 45 minute timeout. Cancelling
it by hand is what unlocked the log.

A wait with no deadline cannot fail, it can only hang, and a hang is worse than
a failure because it is indistinguishable from slowness while holding the
runner (L110). XCUITest's own timeouts are off unless the invocation turns them
on, so the deadline has to be asked for.

This does not stop tests hanging. It makes a hang report itself, with the name
of the test that did it, in a job that finishes.
"""

from __future__ import annotations

from workflow_commands import WORKFLOWS, runs_the_gui_scheme, xcodebuild_commands


def gui_runs() -> list[tuple[str, str]]:
    """Every invocation that executes the GUI suite, with the workflow it is in."""
    found = [
        (path.name, command)
        for path in sorted(WORKFLOWS.glob("*.yml"))
        for command in xcodebuild_commands(path.read_text())
        if runs_the_gui_scheme(command)
    ]
    assert found, (
        "no workflow runs the GUI suite at all, so this test is reading nothing "
        "and would pass on a repo that never executes a UI test"
    )
    return found


def test_a_hanging_gui_test_is_given_a_deadline():
    without = [name for name, command in gui_runs()
               if "-test-timeouts-enabled YES" not in command]

    assert not without, (
        f"{without} runs the GUI suite with test timeouts off, so a test that "
        "stops responding holds the job until the workflow's own timeout and "
        "reports nothing, which is what happened on 2026-08-23"
    )


def test_the_deadline_is_shorter_than_the_job_it_protects():
    """A per test allowance longer than the job's timeout is not a deadline.

    The job gives up at 45 minutes. An allowance anywhere near that lets one
    wedged test spend the whole budget, which is the state this exists to end,
    while the flag reads as protection (L188).
    """
    for name, command in gui_runs():
        words = command.split()
        assert "-default-test-execution-time-allowance" in words, (
            f"{name} enables test timeouts and names no allowance, so the "
            "default applies and nothing here says what it is"
        )
        allowance = int(words[words.index("-default-test-execution-time-allowance") + 1])
        # Four launches at about 42 seconds each is the cost this suite actually
        # carries, so the allowance is per test and has to clear one launch with
        # room, not the whole class.
        assert 90 <= allowance <= 600, (
            f"{name} allows {allowance}s per test. Under 90 would fail on a "
            "cold launch, which was measured at about 42 seconds; over 600 is "
            "long enough that a hang still costs most of the job"
        )
