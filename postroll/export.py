"""
PostRoll — Phase 3 Export Pipeline

Organises all generated assets for one event week into a clean folder
ready for manual upload across platforms. No APIs, no scheduling —
just a dated folder you can open in Finder.

Output structure:

    {org_slug}_{event_slug}_{date}/
        0. Blog/
            draft.md
            photo_01.<ext> … photo_n.<ext>
        1. Sunday/
            photo.<ext>
            story.<ext>
            caption.txt         ← caption + hashtags, copy-pasteable
            alt_text.txt
        2. Monday/              ← same layout as sunday
        3. Tuesday/
            reel.<ext>
            story_cover.<ext>   ← before/after closing frame
            caption.txt
        4. Wednesday/
            carousel/
                01.<ext> … 10.<ext>
            collage_story.<ext>
            caption.txt
            alt_texts.txt       ← numbered, one per photo
        5. Thursday/
            reel.<ext>
            caption.txt
        6. Friday/
            before_after_story.<ext>
        CAPTIONS.txt            ← all 5 days stacked for quick copy-paste
        CHECKLIST.md            ← manual tasks with performer names filled in

Usage:
    python -m postroll.export --manifest manifest.json --output ./exports
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .caption_blocks import (
    PHOTO_TAGS, REEL_DAYS, TAG_LIST, bare_username, week_tag_list,
)

from .posting_preset import DEFAULT_PRESET, is_collage_carousel


# ===================================================================
# Data model
# ===================================================================


@dataclass
class SingleDayData:
    """A single feed photo + story image (Sunday/Monday under the classic preset)."""

    day: str          # "sunday" | "monday"
    photo: Path
    story: Path
    caption: dict[str, Any]   # {caption, hashtags, alt_texts, scene_labels}


@dataclass
class CollageCarouselData:
    """A carousel of photos + a collage that doubles as the story.

    Wednesday always uses this; Sunday/Monday use it under the balanced preset.
    """

    day: str          # "sunday" | "monday" | "wednesday"
    carousel_photos: list[Path]
    collage_story: Path
    caption: dict[str, Any]       # alt_texts is a list here, one per photo
    # Per-photo people tags, keyed by carousel photo path string.
    photo_tags: dict[str, list[str]] = field(default_factory=dict)


@dataclass
class TuesdayData:
    """Tuesday: slider/screen reel + story cover image."""

    reel: Path
    story_cover: Path    # before/after closing frame PNG
    caption: dict[str, Any]


@dataclass
class ThursdayData:
    """Thursday: photo scroll reel."""

    reel: Path
    caption: dict[str, Any]


@dataclass
class FridayData:
    """Friday: before/after story — no caption needed."""

    before_after: Path


@dataclass
class BlogData:
    """Blog post draft + selected photos to embed."""

    title: str
    body: str           # markdown with [PHOTO: n] markers
    photos: list[Path]  # 4–7 photos passed to generate_blog


@dataclass
class WeekExport:
    """All inputs needed to export one event week."""

    event: str
    org: str
    venue: str
    date: str                   # "YYYY-MM-DD"
    performers: list[dict]      # from OCR: [{name, role, ...}]
    sunday: SingleDayData | CollageCarouselData
    monday: SingleDayData | CollageCarouselData
    tuesday: TuesdayData
    wednesday: CollageCarouselData
    thursday: ThursdayData
    friday: FridayData
    blog: BlogData | None = None
    preset: str = DEFAULT_PRESET


# ===================================================================
# Public API
# ===================================================================


def export_week(data: WeekExport, output_dir: Path) -> Path:
    """Create the organised export folder for the week.

    Returns the path to the created folder.
    """
    output_dir = Path(output_dir)
    folder_name = f"{_slug(data.org)}_{_slug(data.event)}_{data.date}"
    export_dir = output_dir / folder_name
    # Rebuild from scratch: a re-export after trimming photos must not leave
    # stale numbered files from the previous export to be uploaded by mistake.
    if export_dir.exists():
        shutil.rmtree(export_dir)
    export_dir.mkdir(parents=True, exist_ok=True)

    _export_preset_day(data.sunday, export_dir / "1. Sunday")
    _export_preset_day(data.monday, export_dir / "2. Monday")
    _export_tuesday(data.tuesday, export_dir / "3. Tuesday")
    _export_collage_carousel(data.wednesday, export_dir / "4. Wednesday")
    _export_thursday(data.thursday, export_dir / "5. Thursday")
    _export_friday(data.friday, export_dir / "6. Friday")

    if data.blog:
        _export_blog(data.blog, export_dir / "0. Blog")

    (export_dir / "CAPTIONS.txt").write_text(_master_captions(data), encoding="utf-8")
    (export_dir / "CHECKLIST.md").write_text(_checklist(data), encoding="utf-8")

    return export_dir


# ===================================================================
# Per-day helpers
# ===================================================================


def _export_preset_day(day: SingleDayData | CollageCarouselData, day_dir: Path) -> None:
    """Sunday/Monday: a single feed photo + story (classic) or a carousel +
    collage story (balanced), depending on which dataclass was assembled."""
    if isinstance(day, CollageCarouselData):
        _export_collage_carousel(day, day_dir)
    else:
        _export_single_day(day, day_dir)


def _export_single_day(day: SingleDayData, day_dir: Path) -> None:
    day_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(day.photo, day_dir / f"photo{day.photo.suffix}")
    shutil.copy2(day.story, day_dir / f"story{day.story.suffix}")
    (day_dir / "caption.txt").write_text(_format_caption(day.caption), encoding="utf-8")
    alt_texts = day.caption.get("alt_texts") or []
    (day_dir / "alt_text.txt").write_text(alt_texts[0] if alt_texts else "", encoding="utf-8")


def _export_tuesday(day: TuesdayData, day_dir: Path) -> None:
    day_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(day.reel, day_dir / f"reel{day.reel.suffix}")
    shutil.copy2(day.story_cover, day_dir / f"story_cover{day.story_cover.suffix}")
    (day_dir / "caption.txt").write_text(_format_caption(day.caption), encoding="utf-8")
    alt_texts = day.caption.get("alt_texts") or []
    (day_dir / "alt_text.txt").write_text(alt_texts[0] if alt_texts else "", encoding="utf-8")


def _export_collage_carousel(day: CollageCarouselData, day_dir: Path) -> None:
    day_dir.mkdir(parents=True, exist_ok=True)
    carousel_dir = day_dir / "carousel"
    carousel_dir.mkdir(exist_ok=True)
    for i, photo in enumerate(day.carousel_photos, start=1):
        shutil.copy2(photo, carousel_dir / f"{i:02d}{photo.suffix}")
    shutil.copy2(day.collage_story, day_dir / f"collage_story{day.collage_story.suffix}")
    (day_dir / "caption.txt").write_text(_format_caption(day.caption), encoding="utf-8")
    alt_texts = day.caption.get("alt_texts") or []
    lines = [f"Photo {i}: {t}" for i, t in enumerate(alt_texts, start=1)]
    (day_dir / "alt_texts.txt").write_text("\n".join(lines), encoding="utf-8")


def _export_thursday(day: ThursdayData, day_dir: Path) -> None:
    day_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(day.reel, day_dir / f"reel{day.reel.suffix}")
    (day_dir / "caption.txt").write_text(_format_caption(day.caption), encoding="utf-8")
    alt_texts = day.caption.get("alt_texts") or []
    (day_dir / "alt_text.txt").write_text(alt_texts[0] if alt_texts else "", encoding="utf-8")


def _export_friday(day: FridayData, day_dir: Path) -> None:
    day_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(day.before_after, day_dir / f"before_after_story{day.before_after.suffix}")


def _export_blog(blog: BlogData, blog_dir: Path) -> None:
    blog_dir.mkdir(parents=True, exist_ok=True)
    md = f"# {blog.title}\n\n{blog.body}\n"
    (blog_dir / "draft.md").write_text(md, encoding="utf-8")
    for i, photo in enumerate(blog.photos, start=1):
        shutil.copy2(photo, blog_dir / f"photo_{i:02d}{photo.suffix}")


# ===================================================================
# Text generators
# ===================================================================


def _format_caption(result: dict[str, Any]) -> str:
    """Render caption + hashtags as a copy-pasteable string."""
    caption = result.get("caption", "").strip()
    tags = " ".join(result.get("hashtags", []))
    return f"{caption}\n\n{tags}".rstrip()


def _photo_label(idx: int, photos: list[Path]) -> str:
    """Label for a carousel photo: the trailing number from the filename
    (e.g. "show-277.jpg" -> "277"), falling back to 1-based position.
    Mirrors the Swift exporter's photoLabel so both CAPTIONS.txt match.
    """
    if idx < len(photos):
        stem = photos[idx].stem
        if "-" in stem:
            num = stem.rsplit("-", 1)[1]
            if num:
                return num
    return str(idx + 1)


def _master_captions(data: WeekExport) -> str:
    # (label, caption dict, carousel photos, per-photo tags). Collage-carousel
    # days (Wednesday always; Sun/Mon under the balanced preset) carry per-photo
    # data; the rest get a single shared alt text.
    def _row(label: str, day: Any) -> tuple:
        if isinstance(day, CollageCarouselData):
            return (label, day.caption, day.carousel_photos, day.photo_tags)
        return (label, day.caption, None, None)

    days = [
        _row("SUNDAY", data.sunday),
        _row("MONDAY", data.monday),
        ("TUESDAY", data.tuesday.caption, None, None),
        _row("WEDNESDAY", data.wednesday),
        ("THURSDAY", data.thursday.caption, None, None),
    ]
    # Every handle taggable anywhere this week, for the reel days, which have
    # no per-photo tags of their own and were exporting no tag list at all
    # (#222).
    week_tags = week_tag_list(
        (cap, photo_tags, photos) for _, cap, photos, photo_tags in days
    )
    sections: list[str] = []
    for label, cap, photos, photo_tags in days:
        block = f"=== {label} ===\n{_format_caption(cap)}"

        alt_texts = cap.get("alt_texts") or []
        if alt_texts:
            # Carousel days (photos present) list one labelled alt text per photo.
            if photos:
                alt_body = "\n".join(
                    f"{_photo_label(i, photos)}: {t}"
                    for i, t in enumerate(alt_texts)
                )
            else:
                alt_body = alt_texts[0]
            block += f"\n\nALT TEXT:\n{alt_body}"

        # Carousel days: per-photo people tags, in photo order, only for photos
        # that were actually tagged.
        if photos and photo_tags:
            tag_lines = []
            for i, photo in enumerate(photos):
                # Bare usernames: Instagram's "Tag people" field takes a
                # username, not an @ mention (#221).
                tags = [bare_username(t) for t in (photo_tags.get(str(photo)) or [])]
                tags = [t for t in tags if t]
                if tags:
                    tag_lines.append(f"{_photo_label(i, photos)}: {', '.join(tags)}")
            if tag_lines:
                block += f"\n\n{PHOTO_TAGS}\n" + "\n".join(tag_lines)
        elif label.lower() in REEL_DAYS and week_tags:
            block += f"\n\n{TAG_LIST}\n" + ", ".join(week_tags)

        sections.append(block)
    return "\n\n".join(sections) + "\n"


def _checklist(data: WeekExport) -> str:
    collabs = _collaborator_line(data.performers)

    lines: list[str] = [f"# PostRoll — {data.event} ({data.date})", ""]

    # Sunday/Monday: a single feed photo + story (classic) or a carousel +
    # collage story (balanced), matching how each day was assembled.
    for heading, day_data in (("Sunday", data.sunday), ("Monday", data.monday)):
        if isinstance(day_data, CollageCarouselData):
            post_line = "- [ ] Post carousel to Instagram, Facebook, TikTok, Pinterest, Bluesky"
            story_line = "- [ ] Post collage story to Instagram + Facebook"
        else:
            post_line = "- [ ] Post to Instagram, Facebook, TikTok, Pinterest, Bluesky"
            story_line = "- [ ] Post story to Instagram + Facebook"
        lines += [
            f"### {heading}",
            "",
            post_line,
            f"- [ ] Add as Instagram collaborators: {collabs}",
            story_line,
            "- [ ] Tag story with performer and venue accounts",
            "",
        ]

    lines += [
        "### Tuesday",
        "",
        "- [ ] Post reel to Instagram, Facebook, TikTok, Pinterest, Bluesky",
        f"- [ ] Add as Instagram collaborators: {collabs}",
        "- [ ] Post story cover to Instagram + Facebook",
        "- [ ] Tag story with performer and venue accounts",
        "",
        "### Wednesday",
        "",
        "- [ ] Post carousel to Instagram, Facebook, TikTok, Pinterest, Bluesky",
        f"- [ ] Add as Instagram collaborators: {collabs}",
        "- [ ] Post collage story to Instagram + Facebook",
        "- [ ] Tag story with performer and venue accounts",
        "",
        "### Thursday",
        "",
        "- [ ] Post reel to Instagram, Facebook, TikTok, Pinterest, Bluesky",
        f"- [ ] Add as Instagram collaborators: {collabs}",
        "",
        "### Friday",
        "",
        "- [ ] Post before/after story to Instagram + Facebook",
        "- [ ] Save story to Instagram highlights",
        "",
        "## Post-Week",
        "",
        "- [ ] Add Instagram post link to OmniFocus one-year follow-up",
        "- [ ] Promote Tuesday reel to followers",
        "",
    ]

    return "\n".join(lines)


def _collaborator_line(performers: list[dict]) -> str:
    names = [p["name"] for p in performers if p.get("name")]
    return ", ".join(names) if names else "(no performers listed)"


# ===================================================================
# Utilities
# ===================================================================


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


# ===================================================================
# CLI (manifest-driven)
# ===================================================================


def _collage_carousel_from_dict(day: str, raw_day: dict) -> CollageCarouselData:
    return CollageCarouselData(
        day=day,
        carousel_photos=[Path(p) for p in raw_day["carousel_photos"]],
        collage_story=Path(raw_day["collage_story"]),
        caption=raw_day["caption"],
        photo_tags=raw_day.get("photo_tags", {}),
    )


def _preset_day_from_dict(day: str, raw_day: dict, preset: str) -> SingleDayData | CollageCarouselData:
    """Sunday/Monday: a collage carousel under balanced, a single photo otherwise."""
    if is_collage_carousel(preset, day):
        return _collage_carousel_from_dict(day, raw_day)
    return SingleDayData(
        day=day,
        photo=Path(raw_day["photo"]),
        story=Path(raw_day["story"]),
        caption=raw_day["caption"],
    )


def _from_dict(raw: dict) -> WeekExport:
    """Deserialise a WeekExport from a plain dict (e.g. loaded from JSON)."""
    preset = raw.get("preset", DEFAULT_PRESET)
    return WeekExport(
        event=raw["event"],
        org=raw["org"],
        venue=raw["venue"],
        date=raw["date"],
        performers=raw.get("performers", []),
        preset=preset,
        sunday=_preset_day_from_dict("sunday", raw["sunday"], preset),
        monday=_preset_day_from_dict("monday", raw["monday"], preset),
        tuesday=TuesdayData(
            reel=Path(raw["tuesday"]["reel"]),
            story_cover=Path(raw["tuesday"]["story_cover"]),
            caption=raw["tuesday"]["caption"],
        ),
        wednesday=_collage_carousel_from_dict("wednesday", raw["wednesday"]),
        thursday=ThursdayData(
            reel=Path(raw["thursday"]["reel"]),
            caption=raw["thursday"]["caption"],
        ),
        friday=FridayData(
            before_after=Path(raw["friday"]["before_after"]),
        ),
        blog=BlogData(
            title=raw["blog"]["title"],
            body=raw["blog"]["body"],
            photos=[Path(p) for p in raw["blog"]["photos"]],
        )
        if raw.get("blog")
        else None,
    )


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Export a PostRoll event week")
    parser.add_argument("--manifest", required=True, help="Path to week manifest JSON")
    parser.add_argument("--output", required=True, help="Output directory")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    week = _from_dict(json.loads(manifest_path.read_text(encoding="utf-8")))
    out = export_week(week, Path(args.output))
    print(f"Exported to: {out}")
