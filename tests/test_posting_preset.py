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

from postroll.posting_preset import (
    COLLAGE_CAROUSEL,
    DEFAULT_PRESET,
    SINGLE,
    collage_count,
    day_format,
    is_collage_carousel,
)

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
    for preset in ("balanced", "classic"):
        covered = {c["day"] for c in FIXTURE["cases"] if c["preset"] == preset}
        assert covered == days, f"{preset} is missing {days - covered}"
