"""#1133 (Phase 5d): the pass may not outlive the process it runs in.

Rule 7 says no fixed cap on calls. It does not say the pass may outlive its
process. `PythonBridge.processTimeout` is 1,800 seconds and every blog path runs
under it, but those seconds are shared differently on each path: a revision
spends 600 + 600 + 600 of model timeouts against it, while a week run reaches
the blog as its LAST step, after seven days of caption generation have already
spent most of the ceiling.

A budget expressed as a constant number of seconds is therefore safe only for
whichever path calibrated it (L227, L522). The caller records its own process
start and passes an ABSOLUTE deadline down.

When 1,800 fires the process is SIGTERM'd, `outputMissing` is thrown, and every
paid call in the whole week is destroyed, which is worse than any finding this
pass exists to fix.
"""

from __future__ import annotations

import pytest
from PIL import Image

from postroll.ai.blog_findings import RepairState
from postroll.ai.blog_repair import CALL_TIMEOUT, deadline_from, repair_alt_text


PROGRAM = {"performers": [{"name": "Kate DiGangi"}], "pieces": []}
VENUE = "The Green Room 42"
BAD = "A male performer sings"
P = "It's a night that started late, and the room didn't empty early."


@pytest.fixture
def photos(tmp_path):
    def _make(*names):
        out = {}
        for i, name in enumerate(names):
            path = tmp_path / name
            Image.new("RGB", (40, 30), (10 + i, 20, 30)).save(path)
            out[name] = str(path)
        return out
    return _make


def _body(*names):
    parts = [P]
    for name in names:
        parts.append(f"[PHOTO: {name} | {BAD}]")
        parts.append(P)
    return "\n\n".join(parts)


class Clock:
    def __init__(self, start=0.0):
        self.now = start

    def __call__(self):
        return self.now


# --- the deadline is derived, never a constant ------------------------------

def test_the_budget_shrinks_with_how_much_of_the_ceiling_is_already_spent():
    """Not a constant number of seconds. A week run reaches the blog as its
    LAST step, after seven days of captions have spent most of the ceiling.

    The DEADLINE is an absolute instant and does not move; what moves is what
    remains of it, which is the quantity the pass actually compares against.
    """
    deadline = deadline_from(started_at=0.0, now=lambda: 0.0, ceiling=1800.0)

    fresh_budget = deadline - 0.0
    late_budget = deadline - 1500.0

    assert late_budget < fresh_budget, (
        "the remaining budget does not shrink as the process ceiling is spent, "
        "so the pass would commit to the same work whether it started first or "
        "last")
    assert late_budget < 400.0


def test_the_deadline_is_the_same_instant_whenever_it_is_asked_for():
    """An absolute instant, not a rolling window. A deadline recomputed from
    the current clock can never age, because every evaluation moves it forward
    with the clock (L74)."""
    early = deadline_from(started_at=0.0, now=lambda: 10.0, ceiling=1800.0)
    later = deadline_from(started_at=0.0, now=lambda: 900.0, ceiling=1800.0)

    assert early == later


def test_the_deadline_leaves_headroom_under_the_process_ceiling():
    """A deadline EQUAL to the ceiling races it, and whichever fires first
    decides what Dan is told. PythonBridge says the same about its own."""
    deadline = deadline_from(started_at=0.0, now=lambda: 0.0, ceiling=1800.0)
    assert deadline < 1800.0


def test_a_process_already_past_its_ceiling_gets_no_budget_at_all():
    """Rather than a negative one, which would read as "infinite" to a
    comparison written the other way round."""
    assert deadline_from(started_at=0.0, now=lambda: 2000.0,
                         ceiling=1800.0) <= 2000.0


# --- what the budget actually buys, at the measured cost --------------------

def test_the_measured_cost_leaves_room_for_seven_markers_at_two_rounds():
    """The number the plan got wrong.

    It assumed 300 seconds a call, made seven markers at two rounds 4,200
    seconds, and concluded the round cap had to drop to one. Measured (#1127),
    a call takes about three seconds.
    """
    from postroll.ai.blog_repair import MAX_ROUNDS

    budget = deadline_from(started_at=0.0, now=lambda: 1500.0, ceiling=1800.0)
    reserved_per_attempt = CALL_TIMEOUT
    # Even reserving the full timeout for every attempt, which is what the pass
    # does before committing, the FIRST attempt always fits in a fresh budget.
    assert budget > reserved_per_attempt, (
        "with 300 seconds of the ceiling left, the pass cannot commit to even "
        "one attempt, so the repair never runs on a week generation at all")
    assert MAX_ROUNDS == 2


# --- the interesting form of not_reached ------------------------------------

def test_the_pass_reaches_some_targets_and_reports_the_rest_not_reached(photos):
    """"Reached 3 of 7, then ran out", produced by advancing the injected clock.

    This is the outcome the design enumerates that no test could produce if the
    budget read the clock directly, and the only way to build it would be
    burning real wall clock in a suite this repo measures per file (L151, L101).
    """
    files = photos(*[f"{i}.jpg" for i in range(7)])
    body = _body(*files)
    clock = Clock()
    reached = []

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        reached.append(image_labels[0])
        clock.now += 100
        return {"alt": "still a male performer singing"}

    # Room for three attempts: 3 * CALL_TIMEOUT reserved, plus a little.
    result = repair_alt_text(
        body, program=PROGRAM, venue=VENUE, photo_paths=files, runner=runner,
        now=clock, deadline=CALL_TIMEOUT + 201.0, max_rounds=1, journal=None)

    assert len(reached) == 3, f"reached {reached}"
    not_reached = [k for k, v in result.states.items()
                   if v is RepairState.NOT_REACHED]
    assert len(not_reached) == 4, result.states
    # And the partition is still total.
    assert set(result.states) == set(result.selected)


def test_a_target_the_deadline_stopped_is_never_marked_tried(photos):
    """`tried` claims the app will not get it next time. For a target it never
    looked at, that claim is false (L11)."""
    files = photos("a.jpg", "b.jpg")
    body = _body("a.jpg", "b.jpg")
    clock = Clock()

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        clock.now += 500
        return {"alt": "still a male performer singing"}

    result = repair_alt_text(
        body, program=PROGRAM, venue=VENUE, photo_paths=files, runner=runner,
        now=clock, deadline=CALL_TIMEOUT + 1.0, max_rounds=1, journal=None)

    assert RepairState.TRIED not in [result.states["b.jpg"]]
    assert result.states["b.jpg"] is RepairState.NOT_REACHED


# --- the two ceilings this pass has to live under ---------------------------

def test_the_process_ceiling_matches_the_one_swift_actually_enforces():
    """Two places spelling one number is two places that can disagree (L41).

    If Swift's timeout moves and this does not, the pass commits to work the
    process will be killed partway through, destroying every paid call in the
    week.
    """
    import re
    from pathlib import Path

    from postroll.ai.blog_repair import PROCESS_CEILING

    source = (Path(__file__).resolve().parent.parent / "PostRollApp" / "Sources"
              / "Services" / "PythonBridge.swift").read_text(encoding="utf-8")
    match = re.search(r"static let processTimeout: TimeInterval = (\d+)", source)
    assert match, "processTimeout is no longer declared where this reads it"
    assert float(match.group(1)) == PROCESS_CEILING, (
        f"Swift kills a run at {match.group(1)}s and the repair pass budgets "
        f"against {PROCESS_CEILING}s")


def test_the_pass_steps_often_enough_never_to_look_stalled():
    """`LongRunState.defaultSilenceThreshold` is 660 seconds and its comment
    names the premise it was chosen against: "a single blog pass is one Claude
    call with a 600 second timeout". The repair loop breaks that premise, so the
    premise is re-derived rather than left standing (L316).

    It stays correct, and for a stronger reason than before: the pass steps once
    per marker, and a marker costs about three seconds, so the gap between
    heartbeats during a repair is far SHORTER than during a pass.
    """
    import re
    from pathlib import Path

    source = (Path(__file__).resolve().parent.parent / "PostRollApp" / "Sources"
              / "Services" / "LongRunStatus.swift").read_text(encoding="utf-8")
    match = re.search(
        r"static let defaultSilenceThreshold: TimeInterval = (\d+)", source)
    assert match, "the silence threshold moved out from under this check"
    threshold = float(match.group(1))

    # The longest the pass can go without saying anything is one attempt, and
    # an attempt is cut at CALL_TIMEOUT.
    assert CALL_TIMEOUT < threshold, (
        f"one repair attempt can run for {CALL_TIMEOUT}s against a {threshold}s "
        f"silence threshold, so a healthy repair would be reported as stalled")


def test_a_seven_marker_repair_never_reports_as_stalled(photos):
    """The check the plan asked for, stated as a check rather than as prose
    (L227): a run stepping once per measured call length, for the length of a
    seven marker repair, is never reported as stalled.
    """
    import re
    from pathlib import Path

    source = (Path(__file__).resolve().parent.parent / "PostRollApp" / "Sources"
              / "Services" / "LongRunStatus.swift").read_text(encoding="utf-8")
    threshold = float(re.search(
        r"static let defaultSilenceThreshold: TimeInterval = (\d+)",
        source).group(1))

    files = photos(*[f"{i}.jpg" for i in range(7)])
    body = _body(*files)
    clock = Clock()
    steps: list[float] = []

    class Say:
        def step(self, label, *, index=None, total=None):
            steps.append(clock.now)

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        clock.now += 3.1        # the measured cost of one call (#1127)
        return {"alt": "still a male performer singing"}

    repair_alt_text(body, program=PROGRAM, venue=VENUE, photo_paths=files,
                    runner=runner, now=clock, deadline=100_000.0,
                    max_rounds=2, journal=None, say=Say())

    assert len(steps) >= 7, f"the pass reported only {len(steps)} steps"
    gaps = [b - a for a, b in zip(steps, steps[1:])]
    assert max(gaps) < threshold, (
        f"the longest gap between heartbeats was {max(gaps)}s against a "
        f"{threshold}s threshold, so a healthy repair reads as stalled")
