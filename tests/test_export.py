"""Tests for the Phase 3 export pipeline."""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from postroll.export import (
    BlogData,
    FridayData,
    SingleDayData,
    ThursdayData,
    TuesdayData,
    WednesdayData,
    WeekExport,
    _checklist,
    _format_caption,
    _master_captions,
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
            caption=SAMPLE_CAPTION,
        ),
        monday=SingleDayData(
            day="monday",
            photo=_make_photo(src / "mon_photo.jpg"),
            story=_make_png(src / "mon_story.png"),
            caption=SAMPLE_CAPTION,
        ),
        tuesday=TuesdayData(
            reel=_make_mp4(src / "tue_reel.mp4"),
            story_cover=_make_png(src / "tue_cover.png"),
            caption=SAMPLE_CAPTION,
        ),
        wednesday=WednesdayData(
            carousel_photos=[_make_photo(src / f"wed_{i:02d}.jpg") for i in range(1, 11)],
            collage_story=_make_png(src / "wed_collage.png"),
            caption=MULTI_CAPTION,
        ),
        thursday=ThursdayData(
            reel=_make_mp4(src / "thu_reel.mp4"),
            caption=SAMPLE_CAPTION,
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
    for day in ("sunday", "monday", "tuesday", "wednesday", "thursday", "friday"):
        assert (out / day).is_dir(), f"Missing day folder: {day}"


def test_carousel_subfolder_exists(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "wednesday" / "carousel").is_dir()


def test_blog_folder_not_created_without_blog(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert not (out / "blog").exists()


def test_blog_folder_created_with_blog(week_data, tmp_path):
    src = tmp_path / "src"
    week_data.blog = BlogData(
        title="A Night at Geffen Hall",
        body="First paragraph.\n\n[PHOTO: 1]\n\nSecond paragraph.",
        photos=[_make_photo(src / f"blog_{i}.jpg") for i in range(1, 4)],
    )
    out = export_week(week_data, tmp_path)
    assert (out / "blog").is_dir()
    assert (out / "blog" / "draft.md").exists()


# ===================================================================
# File contents — single day
# ===================================================================


def test_single_day_photo_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "sunday" / "photo.jpg").exists()


def test_single_day_story_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "sunday" / "story.png").exists()


def test_single_day_caption_txt(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "sunday" / "caption.txt").read_text()
    assert "A moment from the stage." in text
    assert "#dwphotony" in text


def test_single_day_alt_text_txt(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "sunday" / "alt_text.txt").read_text()
    assert "Soprano soloist" in text


# ===================================================================
# File contents — tuesday
# ===================================================================


def test_tuesday_reel_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "tuesday" / "reel.mp4").exists()


def test_tuesday_story_cover_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "tuesday" / "story_cover.png").exists()


def test_tuesday_has_no_alt_text(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert not (out / "tuesday" / "alt_text.txt").exists()


# ===================================================================
# File contents — wednesday
# ===================================================================


def test_wednesday_carousel_numbered(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    for i in range(1, 11):
        assert (out / "wednesday" / "carousel" / f"{i:02d}.jpg").exists()


def test_wednesday_alt_texts_numbered(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    text = (out / "wednesday" / "alt_texts.txt").read_text()
    assert "Photo 1:" in text
    assert "Photo 10:" in text


# ===================================================================
# File contents — thursday
# ===================================================================


def test_thursday_reel_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "thursday" / "reel.mp4").exists()


def test_thursday_has_no_alt_text(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert not (out / "thursday" / "alt_text.txt").exists()


# ===================================================================
# File contents — friday
# ===================================================================


def test_friday_before_after_copied(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert (out / "friday" / "before_after_story.png").exists()


def test_friday_has_no_caption(week_data, tmp_path):
    out = export_week(week_data, tmp_path)
    assert not (out / "friday" / "caption.txt").exists()


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
    draft = (out / "blog" / "draft.md").read_text()
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
        assert (out / "blog" / f"photo_{i:02d}.jpg").exists()


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
