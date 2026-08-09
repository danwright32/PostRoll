"""Tests for the Phase 3 export pipeline."""

from __future__ import annotations

from copy import deepcopy

from pathlib import Path

import pytest
from PIL import Image

from postroll.export import (
    BlogData,
    CollageCarouselData,
    FridayData,
    SingleDayData,
    ThursdayData,
    TuesdayData,
    WeekExport,
    _checklist,
    _format_caption,
    _from_dict,
    _master_captions,
    _photo_label,
    _slug,
    export_week,
)


# ===================================================================
# Fixtures
# ===================================================================


def _make_photo(path: Path, size: tuple[int, int] = (800, 600)) -> Path:
    """Write a minimal JPEG to path and return it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", size, (100, 100, 100)).save(str(path), "JPEG")
    return path


def _make_png(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (1080, 1920), (50, 50, 50)).save(str(path), "PNG")
    return path


def _make_mp4(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x00" * 64)  # fake binary
    return path


SAMPLE_CAPTION = {
    "caption": "A moment from the stage.",
    "hashtags": ["#dwphotony", "#carnegiehall"],
    "alt_texts": ["Soprano soloist at center stage, arms raised."],
    "scene_labels": ["Act I"],
}

MULTI_CAPTION = {
    "caption": "Ten frames from the evening.",
    "hashtags": ["#dwphotony", "#carnegiehall", "#dciny"],
    "alt_texts": [f"Photo {i} alt text." for i in range(1, 11)],
    "scene_labels": [None] * 10,
}

PERFORMERS = [
    {"name": "Lauren Snouffer", "role": "soloist"},
    {"name": "Jonathan Griffith", "role": "conductor"},
]


@pytest.fixture
def week_data(tmp_path) -> WeekExport:
    src = tmp_path / "src"
    # Deep copies, never the module-level dicts themselves. They were shared by
    # every day AND every test, so one test setting a caption key (tag_handles,
    # say) silently changed the fixture for every test that ran after it, and
    # the failure surfaced in an unrelated test.
    sample = deepcopy(SAMPLE_CAPTION)
    multi = deepcopy(MULTI_CAPTION)

    return WeekExport(
        event="Vocal Colors",
        org="DCINY",
        venue="David Geffen Hall",
        date="2026-04-04",
        performers=PERFORMERS,
        sunday=SingleDayData(
            day="sunday",
            photo=_make_photo(src / "sun_photo.jpg"),
            story=_make_png(src / "sun_story.png"),
            caption=deepcopy(sample),
        ),
        monday=SingleDayData(
            day="monday",
            photo=_make_photo(src / "mon_photo.jpg"),
            story=_make_png(src / "mon_story.png"),
            caption=deepcopy(sample),
        ),
        tuesday=TuesdayData(
            reel=_make_mp4(src / "tue_reel.mp4"),
            story_cover=_make_png(src / "tue_cover.png"),
            caption=deepcopy(sample),
        ),
        wednesday=CollageCarouselData(
            day="wednesday",
            carousel_photos=[_make_photo(src / f"wed_{i:02d}.jpg") for i in range(1, 11)],
            collage_story=_make_png(src / "wed_collage.png"),
            caption=deepcopy(multi),
        ),
        thursday=ThursdayData(
            reel=_make_mp4(src / "thu_reel.mp4"),
            caption=deepcopy(sample),
        ),
        friday=FridayData(
            before_after=_make_png(src / "fri_ba.png"),
        ),
    )


# ===================================================================
# Folder structure
# ===================================================================


def test_creates_top_level_folder(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert out.exists()
    assert out.name == "dciny_vocal_colors_2026-04-04"


def test_all_day_folders_exist(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    for day in (
        "1. Sunday", "2. Monday", "3. Tuesday",
        "4. Wednesday", "5. Thursday", "6. Friday",
    ):
        assert (out / day).is_dir(), f"Missing day folder: {day}"


def test_carousel_subfolder_exists(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "4. Wednesday" / "carousel").is_dir()


def test_blog_folder_not_created_without_blog(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert not (out / "0. Blog").exists()


def test_blog_folder_created_with_blog(week_data, tmp_path):
    src = tmp_path / "src"
    week_data.blog = BlogData(
        title="A Night at Geffen Hall",
        body="First paragraph.\n\n[PHOTO: 1]\n\nSecond paragraph.",
        photos=[_make_photo(src / f"blog_{i}.jpg") for i in range(1, 4)],
    )
    out = export_week(week_data, tmp_path)
    assert (out / "0. Blog").is_dir()
    assert (out / "0. Blog" / "draft.md").exists()


# ===================================================================
# File contents — single day
# ===================================================================


def test_single_day_photo_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "1. Sunday" / "photo.jpg").exists()


def test_single_day_story_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "1. Sunday" / "story.png").exists()


def test_single_day_caption_txt(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "1. Sunday" / "caption.txt").read_text()
    assert "A moment from the stage." in text
    assert "#dwphotony" in text


def test_single_day_alt_text_txt(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "1. Sunday" / "alt_text.txt").read_text()
    assert "Soprano soloist" in text
    assert "Photo 1:" not in text


# ===================================================================
# File contents — tuesday
# ===================================================================


def test_tuesday_reel_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "3. Tuesday" / "reel.mp4").exists()


def test_tuesday_story_cover_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "3. Tuesday" / "story_cover.png").exists()


def test_tuesday_alt_text_raw(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "3. Tuesday" / "alt_text.txt").read_text()
    assert text == "Soprano soloist at center stage, arms raised."
    assert "Photo 1:" not in text


# ===================================================================
# File contents — wednesday
# ===================================================================


def test_wednesday_carousel_numbered(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    for i in range(1, 11):
        assert (out / "4. Wednesday" / "carousel" / f"{i:02d}.jpg").exists()


def test_wednesday_alt_texts_numbered(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "4. Wednesday" / "alt_texts.txt").read_text()
    assert "Photo 1:" in text
    assert "Photo 10:" in text


# ===================================================================
# File contents — thursday
# ===================================================================


def test_thursday_reel_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "5. Thursday" / "reel.mp4").exists()


def test_thursday_alt_text_raw(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "5. Thursday" / "alt_text.txt").read_text()
    assert text == "Soprano soloist at center stage, arms raised."
    assert "Photo 1:" not in text


# ===================================================================
# File contents — friday
# ===================================================================


def test_friday_before_after_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "6. Friday" / "before_after_story.png").exists()


def test_friday_has_no_caption(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert not (out / "6. Friday" / "caption.txt").exists()


# ===================================================================
# CAPTIONS.txt
# ===================================================================


def test_captions_master_exists(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "CAPTIONS.txt").exists()


def test_captions_master_has_all_days(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "CAPTIONS.txt").read_text()
    for day in ("SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY"):
        assert f"=== {day} ===" in text


def test_captions_master_includes_alt_text(week_data):
    # Parity with the Swift exporter: CAPTIONS.txt carries an ALT TEXT block,
    # single-line for single-photo days and the soloist alt text for Sunday.
    text = _master_captions(week_data)
    assert "ALT TEXT:\nSoprano soloist at center stage, arms raised." in text


def test_captions_master_wednesday_alt_text_is_per_photo(week_data):
    # Wednesday's carousel lists one labelled alt text per photo. The fixture
    # filenames (wed_01.jpg ...) have no trailing "-number", so labels fall
    # back to 1-based position.
    text = _master_captions(week_data)
    assert "1: Photo 1 alt text." in text
    assert "10: Photo 10 alt text." in text


def test_captions_master_includes_photo_tags(week_data):
    # Per-photo people tags surface under a PHOTO TAGS block for the tagged
    # photos only, labelled the same way as the alt text.
    first = week_data.wednesday.carousel_photos[0]
    third = week_data.wednesday.carousel_photos[2]
    week_data.wednesday.photo_tags = {
        str(first): ["Mike Bono", "@mikebonomusic"],
        str(third): ["Catherine Gregory"],
    }
    text = _master_captions(week_data)
    assert "PHOTO TAGS:" in text
    # Bare usernames, no @ (#221): Instagram's tag field takes a username.
    assert "1: Mike Bono, mikebonomusic" in text
    assert "3: Catherine Gregory" in text
    # Untagged photos are omitted from the block.
    assert "2: " not in text.split("PHOTO TAGS:")[1]


# ── #222: the reel days had no tag list at all ───────────────────────────────


def test_reel_days_carry_the_weeks_tag_list(week_data):
    """Thursday and Tuesday exported a caption, hashtags and alt text and
    nothing to paste into Instagram's tag field, so everyone in the reel went
    untagged. They have no per-photo tags of their own, so they carry the
    union of everyone taggable anywhere that week."""
    first = week_data.wednesday.carousel_photos[0]
    week_data.wednesday.photo_tags = {str(first): ["@safa.wav"]}
    week_data.sunday.caption["tag_handles"] = ["@ferminsuerojr"]

    text = _master_captions(week_data)

    for label in ("TUESDAY", "THURSDAY"):
        block = text.split(f"=== {label} ===")[1].split("=== ")[0]
        assert "TAG LIST:" in block, f"{label} has nothing to paste into the tag field"
        assert "safa.wav" in block, f"{label} is missing a per-photo tag from elsewhere"
        assert "ferminsuerojr" in block, f"{label} is missing a day's handle"
        assert "@" not in block.split("TAG LIST:")[1], "bare usernames only (#221)"


def test_reel_days_have_no_tag_list_when_nobody_is_tagged(week_data):
    text = _master_captions(week_data)
    thursday = text.split("=== THURSDAY ===")[1]
    assert "TAG LIST:" not in thursday


def test_collage_days_keep_photo_tags_rather_than_the_week_list(week_data):
    first = week_data.wednesday.carousel_photos[0]
    week_data.wednesday.photo_tags = {str(first): ["@safa.wav"]}

    text = _master_captions(week_data)
    wednesday = text.split("=== WEDNESDAY ===")[1].split("=== ")[0]

    assert "PHOTO TAGS:" in wednesday
    assert "TAG LIST:" not in wednesday, "a carousel day tags per photo, not per week"


def test_captions_master_omits_photo_tags_when_none(week_data):
    text = _master_captions(week_data)
    assert "PHOTO TAGS:" not in text


def test_photo_label_uses_trailing_number():
    photos = [Path("show-277.jpg"), Path("show-281.jpg")]
    assert _photo_label(0, photos) == "277"
    assert _photo_label(1, photos) == "281"


def test_photo_label_falls_back_to_position():
    photos = [Path("wed_01.jpg")]
    assert _photo_label(0, photos) == "1"      # no dash -> position
    assert _photo_label(5, photos) == "6"      # out of range -> position


# ===================================================================
# CHECKLIST.md
# ===================================================================


def test_checklist_exists(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "CHECKLIST.md").exists()


def test_checklist_contains_event_name(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "CHECKLIST.md").read_text()
    assert "Vocal Colors" in text


def test_checklist_contains_performer_names(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "CHECKLIST.md").read_text()
    assert "Lauren Snouffer" in text
    assert "Jonathan Griffith" in text


def test_checklist_has_friday_highlights_task(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "CHECKLIST.md").read_text()
    assert "highlights" in text.lower()


def test_checklist_no_performers_fallback(tmp_path, week_data):
    week_data.performers = []
    out = export_week(week_data, tmp_path)
    text = (out / "CHECKLIST.md").read_text()
    assert "no performers listed" in text


# ===================================================================
# Blog
# ===================================================================


def test_blog_draft_contains_title(tmp_path, week_data):
    src = tmp_path / "src"
    week_data.blog = BlogData(
        title="A Night at Geffen Hall",
        body="First paragraph.",
        photos=[_make_photo(src / "blog_1.jpg")],
    )
    out = export_week(week_data, tmp_path)
    draft = (out / "0. Blog" / "draft.md").read_text()
    assert "# A Night at Geffen Hall" in draft
    assert "First paragraph." in draft


def test_blog_photos_copied_and_numbered(tmp_path, week_data):
    src = tmp_path / "src"
    week_data.blog = BlogData(
        title="Night at Geffen",
        body="Body.",
        photos=[_make_photo(src / f"b{i}.jpg") for i in range(1, 4)],
    )
    out = export_week(week_data, tmp_path)
    for i in range(1, 4):
        assert (out / "0. Blog" / f"photo_{i:02d}.jpg").exists()


# ===================================================================
# Helpers
# ===================================================================


def test_format_caption_joins_hashtags():
    result = _format_caption({"caption": "Hello.", "hashtags": ["#a", "#b"]})
    assert result == "Hello.\n\n#a #b"


def test_format_caption_handles_missing_hashtags():
    result = _format_caption({"caption": "Hello."})
    assert result == "Hello."


def test_slug_lowercases_and_replaces_spaces():
    assert _slug("David Geffen Hall") == "david_geffen_hall"


def test_slug_collapses_consecutive_punctuation():
    assert _slug("DCINY — Sing & Play!") == "dciny_sing_play"


# ===================================================================
# Re-export hygiene
# ===================================================================


# ===================================================================
# Posting preset (balanced 4/4/4 vs classic 1/1/10)
# ===================================================================


def _balanced_sunday(src: Path) -> CollageCarouselData:
    """Sunday as a 4 photo carousel + collage story (balanced preset)."""
    return CollageCarouselData(
        day="sunday",
        carousel_photos=[_make_photo(src / f"sun_{i:02d}.jpg") for i in range(1, 5)],
        collage_story=_make_png(src / "sun_collage.png"),
        caption=deepcopy(MULTI_CAPTION),
    )


def test_balanced_sunday_exports_carousel_and_collage(week_data, tmp_path):
    src = tmp_path / "src"
    week_data.preset = "balanced"
    week_data.sunday = _balanced_sunday(src)

    out = export_week(week_data, tmp_path)
    # Carousel of four photos plus the collage story image.
    assert (out / "1. Sunday" / "carousel").is_dir()
    for i in range(1, 5):
        assert (out / "1. Sunday" / "carousel" / f"{i:02d}.jpg").exists()
    assert (out / "1. Sunday" / "collage_story.png").exists()
    # Per-photo numbered alt texts (like Wednesday), not a single alt_text.txt.
    text = (out / "1. Sunday" / "alt_texts.txt").read_text()
    assert "1: Photo 1 alt text." in text


def test_balanced_checklist_says_carousel_for_sunday(week_data, tmp_path):
    src = tmp_path / "src"
    week_data.preset = "balanced"
    week_data.sunday = _balanced_sunday(src)
    out = export_week(week_data, tmp_path)
    text = (out / "CHECKLIST.md").read_text()
    sunday_block = text.split("### Sunday")[1].split("###")[0]
    assert "Post carousel" in sunday_block
    assert "collage story" in sunday_block


def test_balanced_sunday_emits_per_photo_tags_and_alt(week_data, tmp_path):
    src = tmp_path / "src"
    sunday = _balanced_sunday(src)
    sunday.photo_tags = {
        str(sunday.carousel_photos[1]): ["Mike Bono", "@mikebonomusic"],
        str(sunday.carousel_photos[3]): ["Catherine Gregory"],
    }
    week_data.preset = "balanced"
    week_data.sunday = sunday

    text = _master_captions(week_data)
    sunday_block = text.split("=== SUNDAY ===")[1].split("=== ")[0]
    # Per-photo numbered alt texts (carousel), not a single shared alt.
    assert "1: Photo 1 alt text." in sunday_block
    # Per-photo people tags for the tagged photos only.
    assert "PHOTO TAGS:" in sunday_block
    assert "Mike Bono, mikebonomusic" in sunday_block
    assert "Catherine Gregory" in sunday_block


def test_classic_sunday_stays_single_photo(week_data, tmp_path):
    # Default fixture Sunday is a SingleDayData; classic keeps it that way.
    week_data.preset = "classic"
    out = export_week(week_data, tmp_path)
    assert (out / "1. Sunday" / "photo.jpg").exists()
    assert (out / "1. Sunday" / "story.png").exists()
    assert not (out / "1. Sunday" / "carousel").exists()


def test_from_dict_balanced_makes_sunday_collage_carousel(tmp_path):
    src = tmp_path / "src"
    raw = {
        "event": "E", "org": "O", "venue": "V", "date": "2026-04-04",
        "preset": "balanced",
        "sunday": {
            "carousel_photos": [str(_make_photo(src / "s1.jpg"))],
            "collage_story": str(_make_png(src / "s_collage.png")),
            "caption": SAMPLE_CAPTION,
        },
        "monday": {
            "carousel_photos": [str(_make_photo(src / "m1.jpg"))],
            "collage_story": str(_make_png(src / "m_collage.png")),
            "caption": SAMPLE_CAPTION,
        },
        "tuesday": {"reel": str(_make_mp4(src / "t.mp4")),
                    "story_cover": str(_make_png(src / "tc.png")), "caption": SAMPLE_CAPTION},
        "wednesday": {"carousel_photos": [str(_make_photo(src / "w1.jpg"))],
                      "collage_story": str(_make_png(src / "w_collage.png")), "caption": MULTI_CAPTION},
        "thursday": {"reel": str(_make_mp4(src / "th.mp4")), "caption": SAMPLE_CAPTION},
        "friday": {"before_after": str(_make_png(src / "f.png"))},
    }
    week = _from_dict(raw)
    assert isinstance(week.sunday, CollageCarouselData)
    assert isinstance(week.monday, CollageCarouselData)
    assert week.preset == "balanced"


def test_from_dict_classic_makes_sunday_single(tmp_path):
    src = tmp_path / "src"
    raw = {
        "event": "E", "org": "O", "venue": "V", "date": "2026-04-04",
        "preset": "classic",
        "sunday": {"photo": str(_make_photo(src / "s.jpg")),
                   "story": str(_make_png(src / "s_story.png")), "caption": SAMPLE_CAPTION},
        "monday": {"photo": str(_make_photo(src / "m.jpg")),
                   "story": str(_make_png(src / "m_story.png")), "caption": SAMPLE_CAPTION},
        "tuesday": {"reel": str(_make_mp4(src / "t.mp4")),
                    "story_cover": str(_make_png(src / "tc.png")), "caption": SAMPLE_CAPTION},
        "wednesday": {"carousel_photos": [str(_make_photo(src / "w1.jpg"))],
                      "collage_story": str(_make_png(src / "w_collage.png")), "caption": MULTI_CAPTION},
        "thursday": {"reel": str(_make_mp4(src / "th.mp4")), "caption": SAMPLE_CAPTION},
        "friday": {"before_after": str(_make_png(src / "f.png"))},
    }
    week = _from_dict(raw)
    assert isinstance(week.sunday, SingleDayData)
    assert week.preset == "classic"


def test_reexport_removes_stale_files(week_data, tmp_path):
    """A second export into the same destination must not keep files from
    the first one (trimmed carousel photos, superseded assets)."""
    out = tmp_path / "exports"
    first = export_week(week_data, out)

    # Simulate debris from the previous export that the new one won't write
    stale_carousel = first / "4. Wednesday" / "carousel" / "11.jpg"
    stale_carousel.write_bytes(b"stale")
    stale_root = first / "old_story.png"
    stale_root.write_bytes(b"stale")

    second = export_week(week_data, out)

    assert second == first
    assert not stale_carousel.exists()
    assert not stale_root.exists()
    # The real contents are still there
    assert (second / "CAPTIONS.txt").exists()
    assert (second / "4. Wednesday" / "carousel" / "01.jpg").exists()
