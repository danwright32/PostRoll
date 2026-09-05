"""The Python half of the saved collage layout contract (#967, #970).

The Swift half is PostRollApp/Tests/CollageLayoutValidityTests.swift and reads
the same committed file. Two lists of the same rule agree only until somebody
edits one (L26).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.media.collage_layout import MIN_CELL_PX, layout_problems

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "collage_layout_validity.json"
CONTRACT = json.loads(FIXTURE.read_text(encoding="utf-8"))
CASES = CONTRACT["cases"]


def _cells(case) -> list[dict]:
    return [{"photo_path": p, "x": x, "y": y, "w": w, "h": h}
            for p, x, y, w, h in case["cells"]]


def test_the_fixture_carries_enough_cases_to_mean_anything():
    # A contract file that lost its cases passes every assertion below while
    # checking nothing (L98). Both a clean layout and each of the five faults
    # have to be represented, or the rule is only half asserted.
    assert len(CASES) >= 12
    codes = {code for case in CASES for code in case["problems"]}
    assert codes == {"under_floor", "off_canvas", "overlapping", "covers_strip", "empty"}
    assert any(not case["problems"] for case in CASES), "no case shows a VALID layout"


@pytest.mark.parametrize("case", CASES, ids=lambda c: c["name"])
def test_python_agrees_with_the_contract(case):
    assert layout_problems(_cells(case), strip_y=case["strip_y"],
                           strip_h=case["strip_h"]) == sorted(case["problems"])


def test_the_floor_is_the_one_the_drag_clamps_to():
    # Restated in the validator, the floor and the clamp drift and a drag
    # becomes able to save what the validator would refuse (L41).
    assert MIN_CELL_PX == CONTRACT["min_cell_px"]


def test_the_canvas_is_the_one_the_renderer_draws_into():
    from postroll.media.collage_layout import CANVAS_H, CANVAS_W
    assert (CANVAS_W, CANVAS_H) == (CONTRACT["canvas"]["w"], CONTRACT["canvas"]["h"])


def test_a_layout_with_no_strip_is_not_accused_of_covering_one():
    # strip_y of None means this layout has no branded band, which is a real
    # state (a single row). Reading the absence as a band at zero would refuse
    # every such layout (L214).
    cells = [{"photo_path": "a", "x": 0, "y": 0, "w": 1080, "h": 400}]
    assert layout_problems(cells, strip_y=None, strip_h=0) == []
    assert layout_problems(cells, strip_y=0, strip_h=0) == []


# ── what an unseeded collage does (#1028) ───────────────────────────────────


#: Six landscape frames, which is what a Wednesday collage is made of and, more
#: to the point, a set several arrangements genuinely fit. A mixed set where
#: nothing fits the crop budget falls back to one layout for every seed, and the
#: control below would then be asserting about the fallback rather than about
#: the planner (L48).
RATIOS = [1.5] * 6


def _plan(seed):
    from postroll.media.generate_collage import plan_base_layout
    return plan_base_layout(RATIOS, seed)


def test_an_unseeded_collage_lays_out_the_same_way_every_time():
    """`Event.swift` said a missing seed meant "random each time", and it does
    not: `plan_base_layout` takes the first fitting arrangement rather than
    drawing one, and its own docstring says so.

    The comment is what a reader trusts, and #1010 had to decide whether
    clearing a seed was neutral while the three places that answer this
    disagreed. So the behaviour is asserted here rather than described (L32).
    """
    assert _plan(None) == _plan(None)


def test_a_seeded_collage_lays_out_the_same_way_every_time():
    """The other half of the same promise, and the one the app depends on:
    adjusting a crop must not reshuffle the grid."""
    assert _plan(4242) == _plan(4242)


def test_the_seed_actually_chooses_the_arrangement():
    """The positive control. Without it both assertions above are satisfied by
    a planner that ignores the seed entirely and always returns one layout
    (L159), which is exactly what "deterministic" would then mean."""
    arrangements = {str(_plan(seed)[:2]) for seed in range(12)}

    assert len(arrangements) > 1, (
        "twelve seeds produced one arrangement, so the seed decides nothing "
        f"and every collage is the same grid: {arrangements}")


def test_the_unseeded_arrangement_is_one_a_seed_can_also_produce():
    """The default is the FIRST fitting arrangement, not a thirteenth option
    reachable only by having no seed. If it were, a day that gains a seed
    could never be laid out the way it looked before it had one."""
    unseeded = _plan(None)[:2]
    seeded = {str(_plan(seed)[:2]) for seed in range(200)}

    assert str(unseeded) in seeded, (
        "the unseeded arrangement is one no seed produces, so the layout a day "
        "had before it was seeded cannot be got back")
