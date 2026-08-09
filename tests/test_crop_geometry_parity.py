"""#168: the crop geometry is one contract, satisfied by both languages.

The crop and pan math is implemented twice: `crop_to_fill` in
`postroll/media/generate_collage.py` renders the Thursday reel strip, the
exported MP4 and the collage base PNG, while `CollageGeometry.placement` in
`PostRollApp/Sources/Services/CollageGeometry.swift` draws the live editor and
the SwiftUI export compositor. Nothing forced the two to agree, and when they
disagree Dan sees one framing on screen and gets another in the exported file,
which makes the preview a liar.

That has already shipped once: Python used a 0.4 vertical bias while the editor
used 0.5.

`tests/fixtures/crop_geometry.json` is the contract. This file asserts the
Python side satisfies it; `PostRollApp/Tests/CollageGeometryFixtureTests.swift`
asserts the Swift side satisfies the same file. Changing the framing rule means
changing the fixture once, and whichever side was not updated fails loudly.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.media.generate_collage import (
    TOP_ANCHORED_CROP_Y,
    ZOOM_FLOOR,
    crop_placement,
)


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "crop_geometry.json"


def _fixture() -> dict:
    return json.loads(FIXTURE.read_text())


def _cases():
    doc = _fixture()
    return [pytest.param(c, id=c["name"]) for c in doc["cases"]]


def test_the_fixture_is_not_empty():
    # Every parametrised test below would pass by running zero cases.
    doc = _fixture()
    assert len(doc["cases"]) >= 10, "the contract has lost its cases"


def test_the_fixture_constants_match_the_implementation():
    # The fixture states the framing rule's two magic numbers. If the code
    # moves one and the fixture does not, every expected value below is being
    # measured against a rule the code no longer follows.
    doc = _fixture()
    assert doc["zoom_floor"] == ZOOM_FLOOR
    assert doc["top_anchored_y"] == TOP_ANCHORED_CROP_Y


@pytest.mark.parametrize("case", _cases())
def test_python_satisfies_the_shared_crop_contract(case):
    tol = _fixture()["tolerance_px"]
    expected = case["expected"]

    rendered_w, rendered_h, draw_x, draw_y = crop_placement(
        photo_w=case["photo_w"], photo_h=case["photo_h"],
        target_w=case["cell_w"], target_h=case["cell_h"],
        crop_offset_x=case["offset_x"], crop_offset_y=case["offset_y"],
        zoom=case["zoom"],
    )

    assert rendered_w == pytest.approx(expected["rendered_w"], abs=tol)
    assert rendered_h == pytest.approx(expected["rendered_h"], abs=tol)
    assert draw_x == pytest.approx(expected["draw_x"], abs=tol)
    assert draw_y == pytest.approx(expected["draw_y"], abs=tol)


# ── the rule the cases exist to pin ───────────────────────────────────────────

def test_an_unset_vertical_offset_is_top_anchored():
    # #167: performing-arts frames put the subject high, so what a fill has to
    # discard comes off the bottom. `None` is what every call site that has no
    # per-photo offset passes.
    unset = crop_placement(2000, 3000, 500, 340, crop_offset_y=None)
    explicit = crop_placement(2000, 3000, 500, 340, crop_offset_y=TOP_ANCHORED_CROP_Y)
    assert unset == explicit
    assert unset[3] == pytest.approx(0.0), "top-anchored keeps the photo's top edge"


def test_an_offset_cannot_pan_an_axis_that_has_slack():
    # Below fill there is nothing to discard, so the photo is centred whatever
    # the offset says. The editor already refuses to commit a pan on an axis
    # without overflow, so a stored offset here is a leftover from a larger
    # zoom, and honouring it would move the export away from the preview.
    centred = crop_placement(3000, 2000, 500, 340, crop_offset_x=0.0, zoom=0.5)
    hard_left = crop_placement(3000, 2000, 500, 340, crop_offset_x=-1.0, zoom=0.5)
    hard_right = crop_placement(3000, 2000, 500, 340, crop_offset_x=1.0, zoom=0.5)
    assert centred == hard_left == hard_right


def test_zoom_is_clamped_to_the_floor_the_editor_enforces():
    # The SIZE slider runs 0.25 to 2.5, so anything below the floor can only
    # arrive from stored data, and the two languages must clamp it the same way
    # or they render different sizes from one saved value.
    assert crop_placement(3000, 2000, 340, 500, zoom=0.01) == \
        crop_placement(3000, 2000, 340, 500, zoom=ZOOM_FLOOR)
