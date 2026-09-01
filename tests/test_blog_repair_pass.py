"""#1133 (Phase 5c): the alt text repairer, and every seam it honours.

Rule 4 licenses genuinely rewriting alt text, with the photograph attached,
because that is the one finding class where the app can do better than report:
the picture is in hand, so nothing is being invented.

Every collaborator is injected from the first commit (L524, L284). The pass
takes its model runner, its clock, its stat function and its journal path, and
reads none of them from the ambient environment. A budget that read the clock
directly would make `not_reached` an outcome the design enumerates and no test
can produce in its interesting form ("reached 3 of 7, then ran out"), and the
only way to build it would be burning real wall clock in a suite this repo
measures per file.

Every SELECTED target ends in exactly one outcome, and the partition is asserted
total (L47, L517). A target can be lost without throwing, and one that ends the
pass carrying the never-attempted default renders exactly like today's findings,
which is the one thing rule 2 forbids.
"""

from __future__ import annotations

import pytest
from PIL import Image

from postroll.ai.blog_findings import RepairState
from postroll.ai.blog_quality import check_blog
from postroll.ai.blog_repair import RepairOutcome, repair_alt_text


VENUE = "The Green Room 42"
PROGRAM = {"performers": [{"name": "Kate DiGangi"}, {"name": "Ryan Cavanagh"}],
           "pieces": []}
P1 = "It's a night that started late and ran long, and the room stayed full."
P2 = "The band set up at the back and didn't move for the whole first set."

GOOD = ("Kate DiGangi sings into a microphone at The Green Room 42 with one "
        "hand raised and the band lit blue behind her")
BAD = "A male performer sings"


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


def _body(*markers: str) -> str:
    parts = [P1]
    for marker in markers:
        parts.append(marker)
        parts.append(P2)
    return "\n\n".join(parts)


class Clock:
    """An injected clock. Nothing in the pass reads the real one."""

    def __init__(self, start: float = 0.0):
        self.now = start

    def __call__(self) -> float:
        return self.now


def _run(body, photos, *, answers, clock=None, deadline=1_000_000.0,
         rounds=2, journal=None, program=None, venue=VENUE):
    """One pass with every seam set. An unset seam would run for real (L284)."""
    calls = []

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        calls.append({"labels": list(image_labels), "paths": list(image_paths),
                      "prompt": prompt})
        answer = answers.pop(0) if answers else None
        if isinstance(answer, Exception):
            raise answer
        return {"alt": answer}

    result = repair_alt_text(
        body,
        program=PROGRAM if program is None else program,
        venue=venue,
        photo_paths=photos,
        runner=runner,
        now=clock or Clock(),
        deadline=deadline,
        max_rounds=rounds,
        journal=journal,
    )
    return result, calls


# --- the saving -------------------------------------------------------------

def test_a_marker_that_breaks_a_rule_is_rewritten(photos):
    files = photos("a.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]")

    result, calls = _run(body, files, answers=[GOOD])

    assert GOOD in result.body
    assert len(calls) == 1


def test_exactly_one_photograph_is_attached_to_each_call(photos):
    """`_reinsert_skipped` records the danger in as many words: an off by one
    here attaches a real alt text to the wrong photograph, which reads as
    correct and is not."""
    files = photos("a.jpg", "b.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]", f"[PHOTO: b.jpg | {BAD}]")

    _result, calls = _run(body, files, answers=[GOOD, GOOD.replace(
        "Kate DiGangi", "Ryan Cavanagh")])

    assert len(calls) == 2
    for call in calls:
        assert len(call["paths"]) == 1, "more than one photograph in one call"
        assert len(call["labels"]) == 1


def test_each_call_carries_the_photograph_for_the_marker_it_is_about(photos):
    """The off-by-one this whole design is most exposed to."""
    files = photos("a.jpg", "b.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]", f"[PHOTO: b.jpg | {BAD}]")

    _result, calls = _run(body, files, answers=[GOOD, GOOD])

    for call in calls:
        assert call["labels"][0] in call["paths"][0], (
            f"the call for {call['labels'][0]} attached {call['paths'][0]}")


def test_a_marker_with_no_findings_is_never_sent(photos):
    files = photos("a.jpg")
    body = _body(f"[PHOTO: a.jpg | {GOOD}]")

    result, calls = _run(body, files, answers=[])

    assert calls == [], "a clean marker was sent to the model"
    assert result.body == body


# --- acceptance -------------------------------------------------------------

def test_a_rewrite_that_still_breaks_a_rule_is_refused_and_marked_tried(photos):
    files = photos("a.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]")

    result, _calls = _run(body, files, answers=["Still a male performer singing",
                                                "Also a male performer singing"])

    assert BAD in result.body, "the refused rewrite shipped"
    assert result.states["a.jpg"] is RepairState.TRIED


def test_a_rewrite_the_damage_gate_refuses_is_marked_tried(photos):
    """The gate runs over the whole body, not just the marker.

    The original is LONG and breaks a rule, rather than the short `BAD` above.
    A husk replacing a four word original is not gutting anything, and the
    retention check correctly declines to judge it: there is nothing to lose.
    """
    files = photos("a.jpg")
    long_but_wrong = ("A male performer grips a trumpet, elbows out, head "
                      "tipped back in red wash at The Green Room 42")
    body = _body(f"[PHOTO: a.jpg | {long_but_wrong}]")
    # Clears check_alt_text and guts the description: only the gate catches it.
    husk = ("Kate DiGangi at The Green Room 42 during the performance on stage "
            "in the room with the others")

    result, _calls = _run(body, files, answers=[husk, husk])

    assert husk not in result.body, "the gate let a gutted rewrite through"
    assert long_but_wrong in result.body, "the original was not kept"
    assert result.states["a.jpg"] is RepairState.TRIED


def test_a_deletion_can_never_satisfy_the_acceptance_check(photos):
    """The shortest path to an accepted repair must not be removing the words."""
    files = photos("a.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]")

    result, _calls = _run(body, files, answers=["", ""])

    assert BAD in result.body
    assert result.states["a.jpg"] is RepairState.TRIED


# --- failure paths ----------------------------------------------------------

def test_an_unreachable_model_is_blocked_and_not_tried(photos):
    """For a network blip, `tried`'s claim that re-running will not help is
    simply false, and rule 1 removed every other signal (L11)."""
    from postroll.ai.claude_client import ClaudeError

    files = photos("a.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]")

    result, _calls = _run(body, files, answers=[ClaudeError("network down")])

    assert result.states["a.jpg"] is RepairState.BLOCKED


def test_an_unreadable_photograph_is_blocked_and_costs_no_call(photos):
    body = _body(f"[PHOTO: a.jpg | {BAD}]")

    result, calls = _run(body, {"a.jpg": "/nowhere/a.jpg"}, answers=[])

    assert result.states["a.jpg"] is RepairState.BLOCKED
    assert calls == [], "a call was paid for with no photograph to attach"


def test_a_failure_on_one_marker_does_not_lose_the_others(photos):
    """An otherwise finished draft is never lost to a network error."""
    from postroll.ai.claude_client import ClaudeError

    files = photos("a.jpg", "b.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]", f"[PHOTO: b.jpg | {BAD}]")

    result, _calls = _run(body, files,
                          answers=[ClaudeError("blip"),
                                   GOOD.replace("Kate DiGangi", "Ryan Cavanagh")])

    assert result.states["a.jpg"] is RepairState.BLOCKED
    assert result.states["b.jpg"] is RepairState.REPAIRED
    assert "Ryan Cavanagh" in result.body


# --- the deadline -----------------------------------------------------------

def test_a_target_the_deadline_never_reached_is_not_reached_not_tried(photos):
    """Produced by advancing the INJECTED clock, never by burning wall clock."""
    files = photos("a.jpg", "b.jpg", "c.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]", f"[PHOTO: b.jpg | {BAD}]",
                 f"[PHOTO: c.jpg | {BAD}]")
    clock = Clock()

    def answer_and_burn(alt):
        def _make():
            clock.now += 100
            return alt
        return _make

    calls = []

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        calls.append(image_labels[0])
        clock.now += 100          # each call costs 100 seconds of the budget
        return {"alt": GOOD}

    result = repair_alt_text(
        body, program=PROGRAM, venue=VENUE, photo_paths=files,
        runner=runner, now=clock, deadline=150.0, max_rounds=2, journal=None)

    assert len(calls) == 1, f"the pass kept going past its deadline: {calls}"
    reached = [k for k, v in result.states.items()
               if v is RepairState.NOT_REACHED]
    assert len(reached) == 2, result.states


def test_the_pass_never_commits_to_work_it_cannot_finish(photos):
    """Checked BEFORE the call, not after: a call started past the deadline
    carries the process past its ceiling, and when 1800s fires the process is
    SIGTERM'd and every paid call in the whole week is destroyed."""
    files = photos("a.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]")
    clock = Clock(start=1000.0)

    def runner(*a, **k):
        raise AssertionError("a call was started with no budget left for it")

    result = repair_alt_text(
        body, program=PROGRAM, venue=VENUE, photo_paths=files,
        runner=runner, now=clock, deadline=1000.0, max_rounds=2, journal=None)

    assert result.states["a.jpg"] is RepairState.NOT_REACHED


# --- the round cap ----------------------------------------------------------

def test_a_target_is_attempted_at_most_the_round_cap(photos):
    files = photos("a.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]")

    _result, calls = _run(body, files, answers=["still bad", "still bad",
                                                "still bad"], rounds=2)

    assert len(calls) == 2, f"the cap did not hold: {len(calls)} calls"


def test_the_cap_counts_per_target_and_not_for_the_whole_pass(photos):
    files = photos("a.jpg", "b.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]", f"[PHOTO: b.jpg | {BAD}]")

    _result, calls = _run(body, files, answers=["bad", "bad", "bad", "bad"],
                          rounds=2)

    assert len(calls) == 4, f"expected two per marker, got {len(calls)}"


# --- the partition ----------------------------------------------------------

def test_every_selected_target_ends_in_exactly_one_outcome(photos):
    """Asserted total across a mixed run (L47, L517).

    A target lost without throwing would end the pass carrying the
    never-attempted default, which renders exactly like today's findings.
    """
    from postroll.ai.claude_client import ClaudeError

    files = photos("a.jpg", "b.jpg", "c.jpg")
    files["d.jpg"] = "/nowhere/d.jpg"
    body = _body(f"[PHOTO: a.jpg | {BAD}]", f"[PHOTO: b.jpg | {BAD}]",
                 f"[PHOTO: c.jpg | {GOOD}]", f"[PHOTO: d.jpg | {BAD}]")

    result, _calls = _run(body, files,
                          answers=[GOOD, ClaudeError("blip"), ClaudeError("blip")])

    for key in result.selected:
        assert key in result.states, f"{key} was selected and never resolved"
        assert result.states[key] is not RepairState.NEVER, key
    assert set(result.states) == set(result.selected), (
        f"selected {sorted(result.selected)} but resolved "
        f"{sorted(result.states)}")


def test_a_clean_post_selects_nothing_and_says_so(photos):
    files = photos("a.jpg")
    body = _body(f"[PHOTO: a.jpg | {GOOD}]")

    result, calls = _run(body, files, answers=[])

    assert result.selected == []
    assert calls == []
    assert result.ran is True, (
        "a pass that had nothing to do must still record that it RAN, or a "
        "clean post and a pass that never started read the same (L98)")


# --- the body it hands back --------------------------------------------------

def test_the_repaired_body_is_what_the_findings_are_re_measured_against(photos):
    files = photos("a.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]")

    result, _calls = _run(body, files, answers=[GOOD])

    codes = [f.code for f in check_blog(result.body, program=PROGRAM, venue=VENUE)]
    assert "alt_text_appearance_descriptor" not in codes


def test_nothing_but_the_repaired_marker_moves(photos):
    files = photos("a.jpg", "b.jpg")
    body = _body(f"[PHOTO: a.jpg | {BAD}]", f"[PHOTO: b.jpg | {GOOD}]")

    result, _calls = _run(body, files, answers=[GOOD])

    assert P1 in result.body and P2 in result.body
    assert f"[PHOTO: b.jpg | {GOOD}]" in result.body


def test_the_outcome_names_every_state_it_can_produce():
    """No default branch: a state nothing can produce is a state nothing tests."""
    assert set(RepairOutcome.STATES) == {
        RepairState.REPAIRED, RepairState.TRIED, RepairState.BLOCKED,
        RepairState.UNAVAILABLE, RepairState.NOT_REACHED}
