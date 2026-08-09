"""The shared arrangements fixture must keep matching the live generator (#195).

The Swift upload page decides whether to offer a "New layout" button from this
fixture. Reimplementing the split enumeration in Swift would drift from the
crop budget rules, and the drift would be invisible: the button would keep
looking correct while redrawing the identical collage.

So both languages read one committed file, and this test is what keeps it true.
It regenerates the counts from the same pair the renderer uses and fails when
the file disagrees, which is the only thing standing between the fixture and
quietly becoming a snapshot of how the generator used to behave.
"""

from __future__ import annotations

import json
from pathlib import Path

from postroll.media.generate_collage import distinct_collage_splits, split_fits_photos


FIXTURE = Path(__file__).parent / "fixtures" / "collage_arrangements.json"


def _live_counts(ratio: float, photo_counts: list[int]) -> dict[str, int]:
    out = {}
    for n in photo_counts:
        ratios = [ratio] * n
        options = [s for s in distinct_collage_splits(n, ratios)
                   if split_fits_photos(s, ratios)]
        out[str(n)] = len(options)
    return out


def test_the_fixture_matches_the_live_generator():
    doc = json.loads(FIXTURE.read_text())
    recorded = doc["arrangements_by_photo_count"]

    live = _live_counts(doc["aspect_ratio"], [int(k) for k in recorded])

    assert recorded == live, (
        "the collage generator's arrangement counts changed. Regenerate "
        "tests/fixtures/collage_arrangements.json and re-check the Swift "
        "'New layout' button, which reads the same file."
    )


def test_two_and_three_photos_have_exactly_one_arrangement():
    # The reason the fixture exists. At these counts "New layout" reseeds and
    # redraws the identical collage, which is a control that visibly does
    # nothing, so the button must not be offered.
    recorded = json.loads(FIXTURE.read_text())["arrangements_by_photo_count"]

    assert recorded["2"] == 1
    assert recorded["3"] == 1


def test_four_photos_have_a_real_choice():
    # Four is the Balanced preset's collage count, so this is the case Dan
    # actually hits every week.
    recorded = json.loads(FIXTURE.read_text())["arrangements_by_photo_count"]

    assert recorded["4"] > 1


def test_the_fixture_covers_the_counts_the_app_can_reach():
    # A fixture with a hole in it would leave the Swift side guessing for that
    # count, which is how the hardcoded literal got there in the first place.
    recorded = json.loads(FIXTURE.read_text())["arrangements_by_photo_count"]

    for n in range(2, 15):
        assert str(n) in recorded, f"no recorded arrangement count for {n} photos"
