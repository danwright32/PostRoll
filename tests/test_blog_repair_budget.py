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


# --- every path bounds the pass, not just the week run (#1166) --------------

import ast
from pathlib import Path as _Path
from unittest.mock import patch

from PIL import Image as _Image

from postroll.ai import generate_blog as _gb
from postroll.ai import swap_blog_photos as _swap
from postroll.ai.blog_repair import CEILING_HEADROOM, PROCESS_CEILING

_AI = _Path(__file__).resolve().parent.parent / "postroll" / "ai"
_PROSE = "It's a night that started late and ran long, and the room stayed full."


@pytest.fixture
def _photo(tmp_path):
    path = tmp_path / "DSC0001.jpg"
    _Image.new("RGB", (40, 30), (10, 20, 30)).save(path)
    return str(path)


class _Spy:
    """Stands in for the pass and records the deadline it was handed."""

    def __init__(self):
        self.deadline = "never called"

    def __call__(self, body, **kwargs):
        self.deadline = kwargs.get("deadline")
        from postroll.ai.blog_repair import RepairOutcome
        return RepairOutcome(body=body, ran=True)


def test_generation_bounds_the_pass_when_no_caller_hands_it_a_deadline(_photo):
    """`repair_deadline` defaults to None and only `generate_week` passes one.

    None used to reach `repair_alt_text` unchanged, where it becomes
    `float("inf")`, so the budget check could never fire. A parameter a function
    needs in order to be CORRECT must not carry a default standing for absent
    (L168): the caller that forgets gets silence, not a refusal.
    """
    spy = _Spy()
    body = f"{_PROSE}\n\n[PHOTO: DSC0001.jpg | A male performer sings]\n\n{_PROSE}"

    def drafted(prompt, timeout=600, image_paths=None, image_labels=None, **k):
        return {"body": body, "photo_count": 1}

    with patch.object(_gb, "run_json_prompt", side_effect=drafted), \
         patch.object(_gb, "repair_alt_text", spy):
        _gb.generate_blog(event="E", org="O", venue=VENUE, date="2026-04-05",
                          program=PROGRAM, photo_paths=[_photo],
                          skip_humanizer=True, skip_voice_pass=True)

    assert spy.deadline not in (None, float("inf")), (
        f"generation handed the pass {spy.deadline!r}, so nothing stops it "
        f"carrying the process past its own ceiling")


def test_the_swap_bounds_the_pass_too(_photo):
    spy = _Spy()

    def drafted(prompt, timeout=300, image_paths=None, image_labels=None, **k):
        return {"body": f"{_PROSE}\n\n[PHOTO: DSC0001.jpg | A male performer sings]",
                "photo_count": 1}

    with patch.object(_swap, "run_json_prompt", side_effect=drafted), \
         patch.object(_swap, "repair_alt_text", spy):
        _swap.swap_blog_photos(
            body=f"{_PROSE}\n\n[PHOTO: old.jpg | old alt]",
            photo_paths=[_photo], program=PROGRAM, venue=VENUE)

    assert spy.deadline not in (None, float("inf")), (
        f"the swap handed the pass {spy.deadline!r}, so a swap of several "
        f"photographs is the route able to outlive its own process")


@pytest.mark.parametrize("path", ["generate_blog.py", "swap_blog_photos.py",
                                  "retry_blog_repair.py"])
def test_no_path_calls_the_pass_without_a_deadline(path):
    """The structural half. The two tests above prove the derivation works on
    the paths they drive; this one refuses a FOURTH caller added later that
    forgets, which is how both of these got here (L96)."""
    tree = ast.parse((_AI / path).read_text(encoding="utf-8"))
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
             and getattr(n.func, "id", None) == "repair_alt_text"]
    assert calls, f"{path} never calls repair_alt_text"
    for call in calls:
        assert any(kw.arg == "deadline" for kw in call.keywords), (
            f"{path} line {call.lineno} runs the repair pass with no deadline, "
            f"so its budget check can never fire")


def test_a_derived_deadline_sits_inside_the_ceiling_rather_than_on_it():
    """A deadline EQUAL to the ceiling races it, and whichever fires first
    decides what Dan is told."""
    deadline = deadline_from(started_at=0.0, now=lambda: 0.0)
    assert deadline == PROCESS_CEILING - CEILING_HEADROOM
    assert deadline < PROCESS_CEILING


# ── the per-call timeout is the recorded reading, not a retyped one (#1188) ──

def test_the_call_timeout_is_the_number_the_measurement_recommends():
    """`tools/measure_alt_text_call.py` writes its readings to
    `tests/fixtures/alt_text_call_timing.json` and already computes a
    `recommended_timeout` from them. `CALL_TIMEOUT` was a hand written 120 with
    the reading quoted in a comment beside it, and nothing in that module read
    the fixture.

    So re-running the measurement updated the file and left the constant
    untouched, while the comment went on asserting a reading the constant might
    no longer reflect. A number spelled in two places is a number the two can
    disagree about (L41), and a dated number in a comment reads as MORE
    trustworthy rather than less (L316).

    Same shape as `test_the_process_ceiling_matches_the_one_swift_actually_enforces`
    above, and as #1164 did for the Swift side.
    """
    import json
    from pathlib import Path

    from postroll.ai.blog_repair import CALL_TIMEOUT
    from tools.measure_alt_text_call import summarise

    fixture = (Path(__file__).resolve().parent
               / "fixtures" / "alt_text_call_timing.json")
    readings = json.loads(fixture.read_text(encoding="utf-8"))["readings"]
    summary = summarise(readings)

    assert summary.get("recommended_timeout"), (
        "the fixture holds no readings the summary can recommend from, so this "
        "check is comparing against nothing (L98)")
    assert CALL_TIMEOUT == summary["recommended_timeout"], (
        f"CALL_TIMEOUT is {CALL_TIMEOUT} and the recorded readings recommend "
        f"{summary['recommended_timeout']}. Re-running the measurement moves "
        f"the fixture and not the constant, so one of them is describing a "
        f"call speed that no longer holds. Re-measure with "
        f"`venv/bin/python tools/measure_alt_text_call.py --photo <a photograph>` "
        f"and bring the constant with it.")


def test_the_recommendation_would_actually_move_if_the_readings_did():
    """The positive control (L159). Pinning to a number that can never change
    is the same as not pinning at all: the floor is 120 and today's readings
    are far under it, so the check above passes for a reason that has nothing
    to do with the readings unless this shows the pair really are coupled."""
    from tools.measure_alt_text_call import summarise

    slow = summarise([{"seconds": s, "answered": True}
                      for s in (300.0, 310.0, 320.0)])

    assert slow["recommended_timeout"] > 120, (
        "a call ten times slower than today recommends the same timeout, so "
        "the constant is pinned to a floor rather than to a measurement")
