"""The GUI suite's launches are counted and declared (#896).

A launch of the real app costs 42 to 55 seconds on the runner, every time, and
the job runs on every merge to main. The suite went from two tests to nine in
one session and from about 100 seconds to 342, entirely in launches, and
nothing anywhere would have said so: each new class looks cheap on its own and
the cost only appears in the job's total.

That is how the LAST UI target died. #509 deleted it as too slow to keep, and
#849 had to argue the case from scratch to bring one back. So the number is
declared here, with what each launch buys, and adding one means editing this
file: a decision somebody takes rather than a cost that creeps in.

This counts launch SITES, not launches at runtime, which is the right unit for
the thing being protected: a site is what somebody adds when they write a test,
and a site inside a loop would be a different and much louder problem.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
UI_TESTS = REPO_ROOT / "PostRollApp" / "UITests"

#: What each launch is for. The four alert conditions cannot be shared at all:
#: each is a different state of the store or the code folder, and the app reads
#: both at launch, so they are decided before there is an app to drive.
#:
#: The two that could be shared and are: the entry point pair share one, and the
#: New Event form's two halves share one (#896).
#:
#: Still available if this has to come down further: the window lifecycle test
#: launches into the same state as the form test and could sequence onto it.
#: It is separate on purpose, because it closes the window the form test needs,
#: so a failure in either would be reported against a screen the other left.
EXPECTED_LAUNCHES = {
    "AppEntryPointUITests.swift": 1,
    "LaunchAlertUITests.swift": 4,
    "NewEventFormUITests.swift": 1,
    "WindowLifecycleUITests.swift": 1,
}

LAUNCH = re.compile(r"LaunchedApp\.launch\(")


def launch_sites() -> dict[str, int]:
    found = {
        path.name: len(LAUNCH.findall(path.read_text()))
        for path in sorted(UI_TESTS.glob("*.swift"))
    }
    return {name: count for name, count in found.items() if count}


def test_every_launch_in_the_gui_suite_is_declared():
    """Read from the files, so a new test file cannot be exempt by omission.

    A hand written registry only ever covers what somebody remembered to add,
    and the entries you remember are the ones already safe (L96).
    """
    actual = launch_sites()

    assert actual, (
        "no launches were found in the GUI suite at all, so this test is "
        "reading nothing and would pass on any repo"
    )
    assert actual == EXPECTED_LAUNCHES, (
        f"the GUI suite launches the app {sum(actual.values())} times, and this "
        f"file says {sum(EXPECTED_LAUNCHES.values())}: {actual}. Each launch is "
        "42 to 55 seconds of every merge. If the new one is genuinely needed, "
        "say what it buys in EXPECTED_LAUNCHES and why it cannot share an "
        "existing app"
    )


def test_the_declared_total_is_one_somebody_would_notice():
    """A budget nobody would ever hit is not a budget.

    The job was 342 seconds at eight launches. This is the number that makes the
    next addition a conversation rather than a surprise on the merge that lands
    it.
    """
    total = sum(EXPECTED_LAUNCHES.values())

    assert total <= 8, (
        f"the GUI suite is declared as {total} launches, which is over five "
        "minutes of every merge before a single assertion runs"
    )
