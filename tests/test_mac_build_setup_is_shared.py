"""#1249: the Mac build setup exists once, and every job that needs it calls it.

Three steps (select the pinned Xcode, install XcodeGen, generate the project)
were written out four times across `swift.yml`, `guards.yml` and `ui.yml`.
`sudo xcode-select --switch "${app}"` alone appeared four times. Changing any of
it meant finding every copy, and missing one failed on whichever job was
forgotten rather than at the point of the change.

It also interacts badly with the guard registry, which is how the cost was
first paid rather than predicted: every entry in `tests/fixtures/guard_mutations`
pins its target with a `find` that must match its file exactly once, so a second
copy inside one file makes that entry unresolvable. `ci-selects-the-recorded-xcode`
broke exactly that way on the #1242 branch.

So the setup is one composite action, and this holds it there. The pair matters
more than either half: an action nothing calls is not a step (L3), and an action
that is called while a workflow keeps its own copy has consolidated nothing.
"""

from __future__ import annotations

import pytest

from tests.mac_build_setup import (
    ACTION,
    ACTION_REF,
    SETUP_MARKERS,
    action_text,
    jobs,
    uncommented,
    workflow_texts,
)


# ── the setup exists, once ───────────────────────────────────────────────────

@pytest.mark.parametrize("marker", SETUP_MARKERS)
def test_the_action_does_the_whole_setup(marker: str) -> None:
    """Each part named separately, so a partial move reports WHICH part is
    missing rather than one failure covering four causes (L11)."""
    assert marker in uncommented(action_text()), (
        f"{ACTION} does not {marker!r}, so a caller that stopped doing it "
        "itself now does not do it at all"
    )


def test_no_workflow_keeps_its_own_copy_of_the_setup() -> None:
    offenders = {
        f"{name}: {marker}"
        for name, text in workflow_texts().items()
        for marker in SETUP_MARKERS
        if marker in uncommented(text)
    }
    assert not offenders, (
        "these workflows spell the Mac build setup out themselves rather than "
        f"calling {ACTION_REF}, which is the duplication #1249 removed and the "
        f"shape that made a guard anchor unresolvable: {sorted(offenders)}"
    )


# ── and every job that needs it calls it ─────────────────────────────────────

def test_every_job_that_runs_xcodebuild_prepares_through_the_action() -> None:
    """Derived from what a job DOES, not from a list of job names kept beside
    it, so a new compiling job is covered the day it lands rather than the day
    somebody remembers this file (L96).

    xcodebuild is the predicate because the project it builds is GENERATED: a
    job that runs it without the setup compiles a checked-in `.xcodeproj` that
    may be behind the manifest, or fails outright when there is none.
    """
    unprepared = [
        f"{workflow}:{name}"
        for workflow, text in workflow_texts().items()
        for name, body in jobs(text).items()
        if "xcodebuild" in body and ACTION_REF not in body
    ]
    assert not unprepared, (
        f"these jobs run xcodebuild without calling {ACTION_REF} first: "
        f"{unprepared}"
    )


def test_the_action_is_actually_called() -> None:
    """The other half. An action nothing uses is not a step, and the failure is
    silent in the direction that matters: the workflows would simply stop doing
    the setup while this file went on reporting that the setup exists (L3)."""
    callers = sorted(
        f"{workflow}:{name}"
        for workflow, text in workflow_texts().items()
        for name, body in jobs(text).items()
        if ACTION_REF in body
    )
    assert len(callers) >= 4, (
        "the setup was duplicated across four jobs, so fewer than four callers "
        f"means one of them lost it rather than shared it: {callers}"
    )


def test_the_reference_frame_job_still_does_no_xcode_work() -> None:
    """It needs the runner for its FONTS, not for a build, and moving the setup
    into one line is exactly the change that makes adding it somewhere it is not
    wanted look tidy."""
    swift = jobs(workflow_texts()["swift.yml"])
    frames = next(body for name, body in swift.items() if name == "reference-frames")
    assert ACTION_REF not in frames, (
        "the reference-frame job now prepares an Xcode build it never uses"
    )
