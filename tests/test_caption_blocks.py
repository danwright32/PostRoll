"""#221, #222, #223: the rules every day's CAPTIONS.txt block must satisfy.

Mirrors PostRollApp/Tests/CaptionBlocksTests.swift. The file is the deliverable,
so a wrongly formatted or entirely missing section ships and is only caught if
Dan happens to notice something absent.
"""

from __future__ import annotations

import pytest

from postroll.caption_blocks import (
    ALT_TEXT,
    PHOTO_TAGS,
    TAG_LIST,
    bare_username,
    expected_blocks,
    missing_blocks,
    week_tag_list,
)


# ── #221 bare usernames ───────────────────────────────────────────────────────


@pytest.mark.parametrize("raw,expected", [
    ("@ferminsuerojr", "ferminsuerojr"),
    ("safa.wav", "safa.wav"),
    ("  @@therealladibree ", "therealladibree"),
    ("https://instagram.com/petewhitesongs/", "petewhitesongs"),
    ("", ""),
    ("@", ""),
])
def test_bare_username(raw, expected):
    assert bare_username(raw) == expected


# ── #222 the reel days get the week's tag list ────────────────────────────────


def test_the_list_gathers_handles_from_every_day():
    days = [({"tag_handles": ["@a"]}, None, None),
            ({"tag_handles": ["@b"]}, None, None)]
    assert week_tag_list(days) == ["a", "b"]


def test_the_list_gathers_per_photo_tags_too():
    days = [({}, {"/p/1.jpg": ["@safa.wav", "@petewhitesongs"]}, ["/p/1.jpg"])]
    assert week_tag_list(days) == ["safa.wav", "petewhitesongs"]


def test_the_list_is_deduplicated_across_days():
    days = [({"tag_handles": ["@shared"]}, None, None),
            ({"tag_handles": ["@shared"]}, {"/p/1.jpg": ["@shared"]}, ["/p/1.jpg"])]
    assert week_tag_list(days) == ["shared"]


def test_two_spellings_of_one_handle_are_one_person():
    """Instagram handles are not case sensitive, so tagging both tags twice."""
    days = [({"tag_handles": ["@Safa.WAV", "@safa.wav"]}, None, None)]
    assert week_tag_list(days) == ["Safa.WAV"]


def test_the_list_carries_no_at_prefixes():
    days = [({"tag_handles": ["@a", "b"]}, None, None)]
    assert all("@" not in name for name in week_tag_list(days))


def test_empty_handles_are_dropped():
    days = [({"tag_handles": ["@", "  ", "@real"]}, None, None)]
    assert week_tag_list(days) == ["real"]


# ── #223 which blocks each day owes ───────────────────────────────────────────


def test_a_collage_day_expects_photo_tags_not_a_week_tag_list():
    blocks = expected_blocks(day="wednesday", is_collage_carousel=True,
                             has_alt_text=True, has_photo_tags=True,
                             has_week_tags=True)
    assert PHOTO_TAGS in blocks
    assert TAG_LIST not in blocks


@pytest.mark.parametrize("day", ["tuesday", "thursday"])
def test_a_reel_day_expects_the_week_tag_list(day):
    """The defect: the reel days emitted no tag list, so everyone in the reel
    went untagged."""
    blocks = expected_blocks(day=day, is_collage_carousel=False,
                             has_alt_text=True, has_photo_tags=False,
                             has_week_tags=True)
    assert TAG_LIST in blocks
    assert PHOTO_TAGS not in blocks


def test_no_tags_anywhere_means_no_tag_block_is_expected():
    blocks = expected_blocks(day="thursday", is_collage_carousel=False,
                             has_alt_text=True, has_photo_tags=False,
                             has_week_tags=False)
    assert TAG_LIST not in blocks


def test_every_day_always_expects_a_caption():
    blocks = expected_blocks(day="friday", is_collage_carousel=False,
                             has_alt_text=False, has_photo_tags=False,
                             has_week_tags=False)
    assert blocks == {"caption"}


# ── #223 the check, seen to fail ──────────────────────────────────────────────


def test_a_complete_block_reports_nothing_missing():
    text = (f"=== THURSDAY ===\nA caption.\n\n{ALT_TEXT}\nSomeone somewhere.\n\n"
            f"{TAG_LIST}\na, b")
    assert missing_blocks(text, {"caption", ALT_TEXT, TAG_LIST}) == []


def test_a_missing_tag_list_is_reported():
    """Exactly what shipped: caption and alt text, nothing to paste into the
    tag field."""
    text = f"=== THURSDAY ===\nA caption.\n\n{ALT_TEXT}\nSomeone somewhere."
    assert missing_blocks(text, {"caption", ALT_TEXT, TAG_LIST}) == [TAG_LIST]


def test_a_missing_alt_text_is_reported():
    text = "=== THURSDAY ===\nA caption."
    assert missing_blocks(text, {"caption", ALT_TEXT}) == [ALT_TEXT]


def test_an_empty_caption_is_reported():
    text = f"=== THURSDAY ===\n\n{ALT_TEXT}\nSomething visible."
    assert "caption" in missing_blocks(text, {"caption", ALT_TEXT})


def test_a_block_that_is_not_expected_is_not_reported():
    assert missing_blocks("=== TUESDAY ===\nA caption.", {"caption"}) == []
