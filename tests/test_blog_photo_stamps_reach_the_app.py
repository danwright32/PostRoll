"""#1130 (Phase 2b): the stamps travel, and the app keeps them.

A stamp that never leaves Python is not a retention key: the swap path is a new
process reading a payload the app stored, so what the alt text was written
against has to be IN that payload. A field with a writer and no reader is not
evidence (L46), and here the reader is a later run of a different script.

The swap manifest carries them back the other way, which is the half that
actually saves the money: without it the swap has no record to compare against
and every photograph reads as new.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import generate_blog as gb
from postroll.ai import revise_blog as rb
from postroll.ai import swap_blog_photos as swap
from postroll.ai.blog_photo_stamps import Retention, retention_for


PROSE = "It's a paragraph about the evening in the room."


@pytest.fixture
def photos(tmp_path):
    made = []
    for i in range(2):
        path = tmp_path / f"DSC{i:04d}.jpg"
        Image.new("RGB", (60, 40), (40 + i, 60, 80)).save(path)
        made.append(str(path))
    return made


def _generate(photos, body):
    with patch.object(gb, "run_json_prompt",
                      side_effect=lambda *a, **k: {"body": body,
                                                   "photo_count": 2}):
        return gb.generate_blog(event="E", org="O", venue="V", date="2026-04-05",
                                program={"performers": [], "pieces": []},
                                photo_paths=photos, skip_humanizer=True,
                                skip_voice_pass=True)


def test_generation_records_a_stamp_for_every_photograph_it_placed(photos):
    body = (f"{PROSE}\n\n[PHOTO: DSC0000.jpg | Alt one]\n\n{PROSE}\n\n"
            f"[PHOTO: DSC0001.jpg | Alt two]\n\n{PROSE}")
    result = _generate(photos, body)

    assert set(result["photo_stamps"]) == {"dsc0000.jpg", "dsc0001.jpg"}
    for stamp in result["photo_stamps"].values():
        assert len(stamp) == 2 and all(isinstance(v, int) for v in stamp)


def test_the_stamps_name_what_the_post_PLACED_not_what_it_was_offered(photos):
    """The record that replaces what blog_marker_missing_photo was providing.

    An event's photo list is the photos AVAILABLE to a post, not the photos in
    it. Once the repair pass acts on that finding, the only remaining evidence
    of which ones the prose was written around is this key (L277).
    """
    body = f"{PROSE}\n\n[PHOTO: DSC0000.jpg | Alt one]\n\n{PROSE}"
    result = _generate(photos, body)

    assert set(result["photo_stamps"]) == {"dsc0000.jpg"}, (
        "the stamps record a photograph the post never placed, so they cannot "
        "say which ones it was written around")


def test_a_stamp_a_generation_wrote_is_what_a_later_swap_compares_against(photos):
    """The round trip that is the whole saving."""
    body = f"{PROSE}\n\n[PHOTO: DSC0000.jpg | Alt one]\n\n{PROSE}"
    stamps = _generate(photos, body)["photo_stamps"]

    assert retention_for("DSC0000.jpg", photos[0], stamps) is Retention.RETAINED

    Image.new("RGB", (120, 90), (9, 9, 9)).save(photos[0])
    assert retention_for("DSC0000.jpg", photos[0], stamps) is Retention.NEW_EDITED


def test_the_swap_records_stamps_too(photos):
    body = f"{PROSE}\n\n[PHOTO: DSC0000.jpg | Alt one]\n\n{PROSE}"
    with patch.object(swap, "run_json_prompt",
                      side_effect=lambda *a, **k: {"body": body,
                                                   "photo_count": 1}):
        result = swap.swap_blog_photos(body=f"{PROSE}\n\n[PHOTO: old.jpg | old]",
                                       photo_paths=[photos[0]])

    assert set(result["photo_stamps"]) == {"dsc0000.jpg"}


def test_a_revision_carries_the_stamps_it_was_given_through_unchanged(photos):
    """A revision has no photographs at all: its manifest names filenames only.

    So it must PASS THROUGH what it was handed rather than compute a new set,
    and it must not drop the key, which would make the next swap treat a post
    written yesterday as having no record at all.
    """
    body = f"{PROSE}\n\n[PHOTO: DSC0000.jpg | Alt one]\n\n{PROSE}"
    given = {"dsc0000.jpg": [111, 222]}

    with patch.object(rb, "run_json_prompt",
                      side_effect=lambda *a, **k: {"title": "T", "body": body}):
        result = rb.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": body, "photo_stamps": given},
            feedback="tighten it", skip_humanizer=True, skip_voice_pass=True)

    assert result["photo_stamps"] == given


def test_a_revision_given_no_stamps_emits_an_empty_map_not_a_missing_key(photos):
    """Every post written before this shipped. The key is always present, so a
    reader never has to tell "absent" from "empty" (L214)."""
    body = f"{PROSE}\n\n[PHOTO: DSC0000.jpg | Alt one]\n\n{PROSE}"
    with patch.object(rb, "run_json_prompt",
                      side_effect=lambda *a, **k: {"title": "T", "body": body}):
        result = rb.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": body},
            feedback="f", skip_humanizer=True, skip_voice_pass=True)

    assert result["photo_stamps"] == {}


def test_a_photograph_that_cannot_be_stat_ed_leaves_no_stamp(tmp_path):
    """A stamp nobody can verify would answer every later comparison as
    retained, which is the failure this key exists to prevent (L215)."""
    from postroll.ai.blog_photo_stamps import photo_stamps

    assert photo_stamps(["gone.jpg"], [str(tmp_path / "gone.jpg")]) == {}
