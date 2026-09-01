"""#1153, #1154: move a misplaced photo marker to a position DERIVED from the
post, never one guessed.

Both checks are about where a marker sits, so repairing either MOVES one. The
plan deferred them because "where a photograph belongs" reads as a judgement
about the flow, and #998 records what happens when a rewriter is allowed to
guess a marker's position.

What makes this buildable is that neither destination is a guess:

- `stacked_photos` is two markers with no prose between them. The second one
  belongs after the next prose block, because that is the only position that
  removes the finding without moving any OTHER marker.
- `late_first_photo` is more than two prose blocks before the first photo. The
  marker belongs after the second one, because that is the threshold the rule
  itself states.

Three properties carry the safety, and each has a test that fails without it:
no prose is written or lost, photographs keep their order relative to each
other, and a move with no derived destination is REFUSED rather than guessed.
"""

from __future__ import annotations

import re

import pytest

from postroll.ai.blog_quality import check_blog, repair_marker_placement

M1 = "[PHOTO: one.jpg | A singer at a microphone, mouth open mid-phrase]"
M2 = "[PHOTO: two.jpg | A conductor with both arms raised above the players]"
M3 = "[PHOTO: three.jpg | A violinist bowing, eyes closed, stage lit behind]"
P = ["First paragraph of prose.", "Second paragraph.", "Third paragraph.",
     "Fourth paragraph.", "Fifth paragraph."]


def body_of(*blocks: str) -> str:
    return "\n\n".join(blocks)


def markers_in(body: str) -> list[str]:
    return re.findall(r"\[PHOTO:\s*([^|\]]+)", body)


def codes(body: str) -> list[str]:
    return [f.code for f in check_blog(body)]


# --- stacked_photos (#1153) -------------------------------------------------

def test_the_second_of_two_stacked_markers_moves_below_the_next_prose():
    before = body_of(P[0], M1, M2, P[1], P[2])
    after, moves = repair_marker_placement(before)
    assert after == body_of(P[0], M1, P[1], M2, P[2])
    assert [name for name, _why in moves] == ["two.jpg"]


def test_a_stack_the_repair_fixes_stops_being_reported():
    before = body_of(P[0], M1, M2, P[1], P[2])
    assert "stacked_photos" in codes(before)
    after, _moves = repair_marker_placement(before)
    assert "stacked_photos" not in codes(after)


def test_three_stacked_markers_spread_across_the_prose_that_follows():
    before = body_of(P[0], M1, M2, M3, P[1], P[2], P[3])
    after, moves = repair_marker_placement(before)
    assert after == body_of(P[0], M1, P[1], M2, P[2], M3, P[3])
    assert [name for name, _why in moves] == ["two.jpg", "three.jpg"]


def test_a_stack_with_no_prose_after_it_is_refused_not_guessed():
    """The destination is DERIVED from the post, so a post with no prose left
    below the stack has no destination, and inventing one is the failure #998
    records. It stays put and `check_blog` goes on reporting it (L98)."""
    before = body_of(P[0], P[1], M1, M2)
    after, moves = repair_marker_placement(before)
    assert after == before
    assert moves == []
    assert "stacked_photos" in codes(after)


def test_a_stack_is_only_partly_repaired_when_the_prose_runs_out():
    """Two markers to place and one prose block to place them after. The first
    move happens, the second is refused, and the refusal is still reported
    rather than silently dropped."""
    before = body_of(P[0], M1, M2, M3, P[1])
    after, moves = repair_marker_placement(before)
    assert after == body_of(P[0], M1, P[1], M2, M3)
    assert [name for name, _why in moves] == ["two.jpg"]
    assert "stacked_photos" in codes(after)


# --- late_first_photo (#1154) ----------------------------------------------

def test_a_late_first_photo_moves_up_to_the_threshold_the_rule_states():
    before = body_of(P[0], P[1], P[2], P[3], M1, P[4])
    after, moves = repair_marker_placement(before)
    assert after == body_of(P[0], P[1], M1, P[2], P[3], P[4])
    assert [name for name, _why in moves] == ["one.jpg"]


def test_a_late_first_photo_the_repair_fixes_stops_being_reported():
    before = body_of(P[0], P[1], P[2], P[3], M1, P[4])
    assert "late_first_photo" in codes(before)
    after, _moves = repair_marker_placement(before)
    assert "late_first_photo" not in codes(after)


def test_a_first_photo_already_inside_the_threshold_is_left_alone():
    before = body_of(P[0], P[1], M1, P[2])
    after, moves = repair_marker_placement(before)
    assert after == before
    assert moves == []


# --- the three safety properties -------------------------------------------

@pytest.mark.parametrize("before", [
    body_of(P[0], M1, M2, P[1], P[2]),
    body_of(P[0], M1, M2, M3, P[1], P[2], P[3]),
    body_of(P[0], P[1], P[2], P[3], M1, P[4]),
    body_of(P[0], P[1], P[2], M1, M2, P[3], P[4]),
])
def test_photographs_keep_their_order_relative_to_each_other(before):
    """The property the damage gate's ordered marker check exists to protect.
    A repair that reorders photographs has rewritten the post's sequence, which
    is the judgement this deliberately does not make."""
    after, _moves = repair_marker_placement(before)
    assert markers_in(after) == markers_in(before)


@pytest.mark.parametrize("before", [
    body_of(P[0], M1, M2, P[1], P[2]),
    body_of(P[0], M1, M2, M3, P[1], P[2], P[3]),
    body_of(P[0], P[1], P[2], P[3], M1, P[4]),
    body_of(P[0], P[1], P[2], M1, M2, P[3], P[4]),
])
def test_no_prose_is_written_lost_or_reordered(before):
    """Rule 3: the app adds only a fact it already holds, and this adds none at
    all. The prose blocks come out in the same order with the same words."""
    after, _moves = repair_marker_placement(before)
    prose = lambda b: [x for x in b.split("\n\n") if not x.startswith("[PHOTO:")]
    assert prose(after) == prose(before)


@pytest.mark.parametrize("before", [
    body_of(P[0], M1, M2, P[1], P[2]),
    body_of(P[0], M1, M2, M3, P[1], P[2], P[3]),
    body_of(P[0], P[1], P[2], P[3], M1, P[4]),
])
def test_running_it_twice_changes_nothing_the_second_time(before):
    once, first_moves = repair_marker_placement(before)
    twice, second_moves = repair_marker_placement(once)
    assert twice == once
    assert first_moves and second_moves == []


def test_a_clean_body_is_returned_untouched_and_reports_no_move():
    before = body_of(P[0], M1, P[1], M2, P[2])
    after, moves = repair_marker_placement(before)
    assert after == before
    assert moves == []


def test_a_body_with_no_markers_at_all_is_untouched():
    before = body_of(P[0], P[1], P[2], P[3])
    after, moves = repair_marker_placement(before)
    assert after == before
    assert moves == []


def test_the_fixtures_actually_fire_the_checks_they_claim_to():
    """The control (L159). If these bodies did not fire the two codes, every
    test above would pass over a repair that had nothing to do."""
    assert "stacked_photos" in codes(body_of(P[0], M1, M2, P[1], P[2]))
    assert "late_first_photo" in codes(body_of(P[0], P[1], P[2], P[3], M1, P[4]))
    # Only the two placement codes are asserted absent from the clean fixture.
    # These alt texts are deliberately short, so the length and venue rules
    # fire on every body here; that is unrelated to where a marker SITS, and
    # demanding a fixture clean of every rule would tie this file to the alt
    # text band it is not testing (L63).
    clean = codes(body_of(P[0], M1, P[1], M2, P[2]))
    assert "stacked_photos" not in clean and "late_first_photo" not in clean


# --- wiring: built is not wired (L3) ---------------------------------------

import ast
from pathlib import Path

AI = Path(__file__).resolve().parent.parent / "postroll" / "ai"
PATHS = ("generate_blog.py", "revise_blog.py", "swap_blog_photos.py")


def _call_lines(module: str, name: str) -> list[int]:
    tree = ast.parse((AI / module).read_text(encoding="utf-8"))
    return sorted(n.lineno for n in ast.walk(tree)
                  if isinstance(n, ast.Call)
                  and getattr(n.func, "id", None) == name)


@pytest.mark.parametrize("module", PATHS)
def test_every_blog_path_repairs_marker_placement(module):
    """A repair wired into generation alone leaves the other two paths
    reporting a finding the app could have fixed, which is #1133's mistake."""
    assert _call_lines(module, "repair_marker_placement"), (
        f"{module} never calls repair_marker_placement, so a stacked or late "
        f"marker on this path is reported rather than moved")


@pytest.mark.parametrize("module", PATHS)
def test_placement_runs_after_the_filename_repair_and_before_the_checks(module):
    """Order is the whole correctness of a pre-check repair.

    After the filename repair, because a marker whose name is a near miss is
    corrected first and this reads names. Before `check_blog`, because what the
    panel reports has to be what the body actually says: running it afterwards
    would move a marker and then hand Dan a finding about where it used to be.
    """
    placement = _call_lines(module, "repair_marker_placement")
    filenames = _call_lines(module, "repair_marker_filenames")
    # Either spelling. `check_blog` is `check_blog_targeted` with the targets
    # dropped, and these paths call the targeted one so the payload can say
    # which marker each finding is about (#1160). A guard naming only one
    # spelling reports a real reordering and a rename identically (L11).
    checks = (_call_lines(module, "check_blog")
              + _call_lines(module, "check_blog_targeted"))
    assert filenames and checks, (
        f"{module}: this test cannot judge order without both neighbours; "
        f"repair_marker_filenames={filenames} check_blog={checks}")
    assert min(placement) > min(filenames), (
        f"{module}: placement at {placement} runs before the filename repair "
        f"at {filenames}, so it reads marker names that may still be wrong")
    assert max(placement) < max(checks), (
        f"{module}: placement at {placement} runs after check_blog at "
        f"{checks}, so the panel reports where a marker USED to be")
