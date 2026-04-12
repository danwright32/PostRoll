"""
PostRoll — Phase 3 Export Pipeline

Organises all generated assets for one event week into a clean folder
ready for manual upload across platforms. No APIs, no scheduling —
just a dated folder you can open in Finder.

Output structure:

    {org_slug}_{event_slug}_{date}/
        sunday/
            photo.<ext>
            story.<ext>
            caption.txt         ← caption + hashtags, copy-pasteable
            alt_text.txt
        monday/                 ← same layout as sunday
        tuesday/
            reel.<ext>
            story_cover.<ext>   ← before/after closing frame
            caption.txt
        wednesday/
            carousel/
                01.<ext> … 10.<ext>
            collage_story.<ext>
            caption.txt
            alt_texts.txt       ← numbered, one per photo
        thursday/
            reel.<ext>
            caption.txt
        friday/
            before_after_story.<ext>
        blog/
            draft.md
            photo_01.<ext> … photo_n.<ext>
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
from dataclasses import dataclass
from pathlib import Path
from typing import Any


# ===================================================================
# Data model
# ===================================================================


@dataclass
class SingleDayData:
    """Sunday or Monday: one feed photo + story image."""

    day: str          # "sunday" | "monday"
    photo: Path
    story: Path
    caption: dict[str, Any]   # {caption, hashtags, alt_texts, scene_labels}


@dataclass
class TuesdayData:
    """Tuesday: slider/screen reel + story cover image."""

    reel: Path
    story_cover: Path    # before/after closing frame PNG
    caption: dict[str, Any]


@dataclass
class WednesdayData:
    """Wednesday: carousel photos + collage story image."""

    carousel_photos: list[Path]   # typically 10 photos
    collage_story: Path
    caption: dict[str, Any]       # alt_texts is a list here


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
    sunday: SingleDayData
    monday: SingleDayData
    tuesday: TuesdayData
    wednesday: WednesdayData
    thursday: ThursdayData
    friday: FridayData
    blog: BlogData | None = None


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
    export_dir.mkdir(parents=True, exist_ok=True)

    _export_single_day(data.sunday, export_dir / "sunday")
    _export_single_day(data.monday, export_dir / "monday")
    _export_tuesday(data.tuesday, export_dir / "tuesday")
    _export_wednesday(data.wednesday, export_dir / "wednesday")
    _export_thursday(data.thursday, export_dir / "thursday")
    _export_friday(data.friday, export_dir / "friday")

    if data.blog:
        _export_blog(data.blog, export_dir / "blog")

    (export_dir / "CAPTIONS.txt").write_text(_master_captions(data), encoding="utf-8")
    (export_dir / "CHECKLIST.md").write_text(_checklist(data), encoding="utf-8")

    return export_dir


# ===================================================================
# Per-day helpers
# ===================================================================


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


def _export_wednesday(day: WednesdayData, day_dir: Path) -> None:
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


def _master_captions(data: WeekExport) -> str:
    days = [
        ("SUNDAY", data.sunday.caption),
        ("MONDAY", data.monday.caption),
        ("TUESDAY", data.tuesday.caption),
        ("WEDNESDAY", data.wednesday.caption),
        ("THURSDAY", data.thursday.caption),
    ]
    sections = [f"=== {label} ===\n{_format_caption(cap)}" for label, cap in days]
    return "\n\n".join(sections) + "\n"


def _checklist(data: WeekExport) -> str:
    collabs = _collaborator_line(data.performers)

    lines: list[str] = [f"# PostRoll — {data.event} ({data.date})", ""]

    # Days with feed post + story + collaborators
    for heading in ("Sunday", "Monday"):
        lines += [
            f"### {heading}",
            "",
            "- [ ] Post to Instagram, Facebook, TikTok, Pinterest, Bluesky",
            f"- [ ] Add as Instagram collaborators: {collabs}",
            "- [ ] Post story to Instagram + Facebook",
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


def _from_dict(raw: dict) -> WeekExport:
    """Deserialise a WeekExport from a plain dict (e.g. loaded from JSON)."""
    return WeekExport(
        event=raw["event"],
        org=raw["org"],
        venue=raw["venue"],
        date=raw["date"],
        performers=raw.get("performers", []),
        sunday=SingleDayData(
            day="sunday",
            photo=Path(raw["sunday"]["photo"]),
            story=Path(raw["sunday"]["story"]),
            caption=raw["sunday"]["caption"],
        ),
        monday=SingleDayData(
            day="monday",
            photo=Path(raw["monday"]["photo"]),
            story=Path(raw["monday"]["story"]),
            caption=raw["monday"]["caption"],
        ),
        tuesday=TuesdayData(
            reel=Path(raw["tuesday"]["reel"]),
            story_cover=Path(raw["tuesday"]["story_cover"]),
            caption=raw["tuesday"]["caption"],
        ),
        wednesday=WednesdayData(
            carousel_photos=[Path(p) for p in raw["wednesday"]["carousel_photos"]],
            collage_story=Path(raw["wednesday"]["collage_story"]),
            caption=raw["wednesday"]["caption"],
        ),
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
