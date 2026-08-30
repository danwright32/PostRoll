"""#107: postroll/posting_preset.py is the declared source of truth for how a
week is shaped, and it had no direct tests at all. Only its Swift mirror was
pinned, so the source could change and only the copy would complain, which is
backwards.

Every case comes from tests/fixtures/posting_presets.json, which the Swift
mirror asserts against too. One statement of the rules, two implementations
checked against it, so neither can drift without the fixture being edited
deliberately.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll import posting_preset
from postroll.posting_preset import (
    COLLAGE_CAROUSEL,
    DEFAULT_PRESET,
    SINGLE,
    collage_count,
    day_format,
    is_collage_carousel,
)

FIXTURE_PRESETS: tuple[str, ...] = ("balanced", "classic", "opening")

FIXTURE = json.loads(
    (Path(__file__).parent / "fixtures" / "posting_presets.json").read_text()
)


def _ids(cases):
    return [f"{c['preset'] or 'empty'}-{c['day']}" for c in cases]


def test_the_fixture_names_the_same_default():
    assert DEFAULT_PRESET == FIXTURE["default_preset"]


def test_the_fixture_names_the_same_formats():
    assert SINGLE == FIXTURE["formats"]["single"]
    assert COLLAGE_CAROUSEL == FIXTURE["formats"]["collage_carousel"]


@pytest.mark.parametrize("case", FIXTURE["cases"], ids=_ids(FIXTURE["cases"]))
def test_day_format_matches_the_fixture(case):
    result = day_format(case["preset"], case["day"])
    if case["format"] is None:
        assert result is None, (
            f"{case['day']} is not governed by the preset, so its format must be "
            "None rather than a guess"
        )
    else:
        assert result == (case["format"], case["count"])


@pytest.mark.parametrize("case", FIXTURE["cases"], ids=_ids(FIXTURE["cases"]))
def test_collage_count_matches_the_fixture(case):
    expected = case["count"] if case["format"] == COLLAGE_CAROUSEL else None
    assert collage_count(case["preset"], case["day"]) == expected


@pytest.mark.parametrize("case", FIXTURE["cases"], ids=_ids(FIXTURE["cases"]))
def test_is_collage_carousel_matches_the_fixture(case):
    assert is_collage_carousel(case["preset"], case["day"]) == (
        case["format"] == COLLAGE_CAROUSEL
    )


@pytest.mark.parametrize("case", FIXTURE["unknown_preset_falls_back_to_default"],
                         ids=_ids(FIXTURE["unknown_preset_falls_back_to_default"]))
def test_an_unknown_preset_falls_back_to_the_default(case):
    """A stored preset from a future build, or a typo, must not produce an
    empty week."""
    assert day_format(case["preset"], case["day"]) == (case["format"], case["count"])


def test_a_none_preset_falls_back_to_the_default():
    assert day_format(None, "sunday") == day_format(DEFAULT_PRESET, "sunday")


def test_an_unknown_day_is_not_governed_rather_than_an_error():
    assert day_format("balanced", "caturday") is None
    assert collage_count("balanced", "caturday") is None
    assert is_collage_carousel("balanced", "caturday") is False


def test_the_fixture_covers_every_day_of_the_week_for_every_preset():
    """A fixture that quietly stopped covering a day would let that day drift.

    Enumerated here rather than trusted, because the whole value of the shared
    fixture is that both sides check the same complete set.
    """
    days = {"sunday", "monday", "tuesday", "wednesday", "thursday", "friday"}
    for preset in FIXTURE_PRESETS:
        covered = {c["day"] for c in FIXTURE["cases"] if c["preset"] == preset}
        assert covered == days, f"{preset} is missing {days - covered}"


# --- The two predicates a layout SWITCH is decided by (#1010) -----------------
#
# Separate on purpose. Switching rebuilds a day's captions only when its POST
# TYPE changes, and redraws its images only when the format or the effective
# count changes. Keying the paid half on format alone pays for a caption
# rebuild on a day whose post type did not move.


def test_the_effective_count_fixture_is_not_empty():
    """Its own emptiness assertion, not the one `cases` has.

    `test_the_fixture_is_readable` only ever asserted `cases` was non-empty, so
    a new array that came back empty would be iterated zero times and every
    test over it would pass while proving nothing (L98).
    """
    assert FIXTURE["effective_counts"], "an empty array would assert nothing"


def test_the_post_type_fixture_is_not_empty():
    assert FIXTURE["post_types"], "an empty array would assert nothing"


@pytest.mark.parametrize("case", FIXTURE["effective_counts"])
def test_effective_count_matches_the_fixture(case):
    assert posting_preset.effective_count(
        case["preset"], case["day"], case["assigned"]
    ) == case["effective"]


@pytest.mark.parametrize("case", FIXTURE["post_types"])
def test_post_type_matches_the_fixture(case):
    assert posting_preset.post_type(
        case["preset"], case["day"], case["assigned"]
    ) == case["post_type"]


def test_post_type_is_the_same_function_generate_week_uses():
    """One implementation, not two that agree today.

    `_auto_post_type` is what actually decides what the caption pipeline is
    told, so a second copy of the rule here would drift in the direction that
    flatters whichever one a test happened to read. Two same-named functions
    on either side of a boundary are never compared and can implement
    different rules indefinitely (L263).
    """
    from postroll.ai import generate_week

    for case in FIXTURE["post_types"]:
        assert generate_week._auto_post_type(
            case["day"], case["assigned"], case["preset"]
        ) == posting_preset.post_type(
            case["preset"], case["day"], case["assigned"]
        ), f"the two disagree for {case}"


def test_a_collage_day_with_one_photo_posts_the_same_as_a_single_day():
    """The row the whole switch decision turns on.

    A Balanced Sunday and a Classic Sunday disagree about the format, so a rule
    keyed on format alone calls this a caption rebuild. Python's own rule says
    both are a feed_photo, so nothing about the caption changes and the rebuild
    is money spent for no difference, which is the waste #1010 exists to stop.
    """
    assert posting_preset.post_type("balanced", "sunday", 1) == "feed_photo"
    assert posting_preset.post_type("classic", "sunday", 1) == "feed_photo"
    assert posting_preset.day_format("balanced", "sunday")[0] != \
        posting_preset.day_format("classic", "sunday")[0], \
        "fixture assumption: the two presets really do disagree about the format"
