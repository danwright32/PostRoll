"""#969: the collage gutter is one value, satisfied by both languages.

It was written twice with different numbers: `let gap = 8` in
`PostRollApp/Sources/Views/CaptionReview/CollageDividers.swift` against
`GUTTER = 16` in `postroll/media/design_tokens.py`. Python bakes 16px gaps into
the base PNG and the editor computed every vertical divider position and drag
clamp as though they were 8, so each handle sat 4px off the gap it was meant to
be centred in and both clamps stopped 4px past the 80px floor a save is refused
under.

`tests/fixtures/collage_gutter.json` states the gutter once and carries real
layouts from `plan_collage_cells`. This file asserts Python still draws that
gutter; `PostRollApp/Tests/CollageGutterParityTests.swift` asserts the editor's
geometry is computed from it. Changing the gutter means regenerating the fixture
with `tools/record_collage_gutter.py`, and whichever side disagrees fails.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

import pytest

from postroll.media import generate_collage as collage
from postroll.media.design_tokens import GUTTER


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "collage_gutter.json"


def _fixture() -> dict:
    return json.loads(FIXTURE.read_text())


def _cases():
    return [pytest.param(c, id=c["name"]) for c in _fixture()["cases"]]


def test_the_contract_has_layouts_in_it():
    # Every parametrised check below would pass by running zero cases (L98).
    doc = _fixture()
    assert len(doc["cases"]) >= 4, "the contract has lost its cases"
    for case in doc["cases"]:
        assert len(case["cells"]) >= 4, f"{case['name']} has no layout to measure"


def test_the_contract_states_the_gutter_the_generator_draws_with():
    doc = _fixture()
    assert doc["gutter_px"] == GUTTER, (
        f"the contract says the gutter is {doc['gutter_px']}px and "
        f"design_tokens.GUTTER is {GUTTER}px. Every expected divider position "
        f"on the Swift side is now measured against a gutter Python does not "
        f"draw, so regenerate the fixture rather than editing this number.")
    assert doc["strip_h_px"] == collage.STRIP_H
    assert doc["min_cell_px"] < doc["strip_h_px"]


@pytest.mark.parametrize("case", _cases())
def test_every_gap_in_a_recorded_layout_is_the_stated_gutter(case):
    """The fixture's own cells still carry the gutter it claims.

    Asserted over the recorded layout rather than by re-reading GUTTER, because
    the number and the pixels are different facts: the constant could be right
    while `plan_collage_cells` advanced by something else (L225).
    """
    doc = _fixture()
    gutter, strip = doc["gutter_px"], doc["strip_h_px"]
    cells = case["cells"]

    rows: dict[int, list[dict]] = {}
    for cell in cells:
        rows.setdefault(cell["y"], []).append(cell)

    horizontal = []
    for _, row in sorted(rows.items()):
        row.sort(key=lambda c: c["x"])
        horizontal += [b["x"] - (a["x"] + a["w"]) for a, b in zip(row, row[1:])]
    assert horizontal, f"{case['name']} has no two cells side by side"
    assert set(horizontal) == {gutter}, (
        f"{case['name']}: columns are {sorted(set(horizontal))}px apart, not the "
        f"stated {gutter}px gutter")

    tops = sorted(rows)
    vertical = [b - (a + rows[a][0]["h"]) for a, b in zip(tops, tops[1:])]
    assert vertical, f"{case['name']} has only one row"
    assert set(vertical) <= {gutter, strip}, (
        f"{case['name']}: rows are {sorted(set(vertical))}px apart, and the only "
        f"two legitimate values are the {gutter}px gutter and the {strip}px "
        f"branded strip")
    assert strip in vertical, (
        f"{case['name']} has no branded strip in it, so this layout cannot show "
        f"that the strip is told apart from an ordinary gutter")


@pytest.mark.parametrize("case", _cases())
def test_the_recorded_layouts_are_what_the_planner_produces_now(case):
    """The cells came from `plan_collage_cells` and still match it.

    Without this the fixture is a photograph of a layout the planner has since
    stopped drawing, and both languages would go on agreeing with each other
    about a collage neither of them makes (L84).
    """
    doc = _fixture()
    top, bottom = case["top_pattern"], case["bottom_pattern"]
    count = sum(top) + sum(bottom)
    cells, strip_y = collage.plan_collage_cells(
        [case["photo_ratio"]] * count, top, bottom, random.Random(case["seed"]))

    assert strip_y == case["strip_y"], (
        f"{case['name']}: the planner now puts the branded strip at {strip_y}, "
        f"not the {case['strip_y']} recorded")
    produced = [(c["x"], c["y"], c["w"], c["h"]) for c in cells]
    recorded = [(c["x"], c["y"], c["w"], c["h"]) for c in case["cells"]]
    assert produced == recorded, (
        f"{case['name']}: the planner no longer draws the layout in the "
        f"contract, so regenerate it with tools/record_collage_gutter.py")
    assert doc["gutter_px"] == GUTTER
