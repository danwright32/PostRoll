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
