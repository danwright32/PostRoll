"""
PostRoll — Week-Level Generator

Generates all captions and an optional blog post for a single event week
by reading a manifest JSON and calling generate_caption + generate_blog.

Manifest format (input):
{
  "event": "Vocal Colors",
  "org": "DCINY",
  "venue": "David Geffen Hall",
  "date": "2026-04-04",
  "shoot_type": "performance",
  "program": { ...OCR output dict... },
  "days": {
    "sunday": {
      "photos": ["/path/to/p1.jpg"],
      "post_type": "feed_photo",       ← optional, auto-detected if omitted
      "tag_handles": ["@dciny"],       ← optional
      "name_mentions": []              ← optional
    },
    ...
  },
  "blog_photos": ["/path/to/p1.jpg", ...]  ← omit or empty to skip blog
}

Output JSON (written to --output file):
{
  "sunday": {"caption": "...", "hashtags": [...], "alt_texts": [...], "scene_labels": [...]},
  "monday": null,          ← null if no photos were assigned
  "tuesday": {...},
  "wednesday": {...},
  "thursday": {...},
  "friday": {...},
  "blog": {"title": "...", "body": "...", "photo_count": 5},
  "errors": {}             ← keyed by day name if any individual day failed
}

Usage:
    python -m postroll.ai.generate_week \\
        --manifest /path/to/manifest.json \\
        --output   /path/to/output.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from .generate_captions import generate_caption
from .generate_blog import generate_blog
from .select_reel_photos import select_reel_photos, DEFAULT_MAX_REEL_PHOTOS


DAY_ORDER = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"]

# When a scroll_reel day has this many photos, ask Claude to pick the best subset
REEL_SELECTION_THRESHOLD = 50


def _auto_post_type(day: str, photo_count: int) -> str:
    """Pick a sensible post_type when the manifest doesn't specify one."""
    if day == "wednesday" and photo_count > 1:
        return "carousel"
    if day in ("thursday",) and photo_count > 1:
        return "scroll_reel"
    return "feed_photo"


def generate_week(manifest: dict[str, Any], output_path: Path) -> None:
    """Run caption + blog generation for one event week."""
    event      = manifest["event"]
    org        = manifest["org"]
    venue      = manifest["venue"]
    date       = manifest["date"]
    shoot_type = manifest.get("shoot_type", "performance")
    program    = manifest["program"]
    days_data  = manifest.get("days", {})
    blog_photos = manifest.get("blog_photos", [])

    results: dict[str, Any] = {}
    errors:  dict[str, str] = {}
    existing_captions: list[str] = []

    for day_name in DAY_ORDER:
        day_info = days_data.get(day_name, {})
        photos   = day_info.get("photos", [])

        if not photos:
            results[day_name] = None
            print(f"[generate_week] {day_name}: no photos, skipping", flush=True)
            continue

        post_type    = day_info.get("post_type") or _auto_post_type(day_name, len(photos))
        tag_handles  = day_info.get("tag_handles") or None
        name_mentions = day_info.get("name_mentions") or None

        # For large scroll reels, let Claude pick the best representative subset
        if post_type == "scroll_reel" and len(photos) >= REEL_SELECTION_THRESHOLD:
            print(
                f"[generate_week] {day_name}: selecting best {DEFAULT_MAX_REEL_PHOTOS} "
                f"from {len(photos)} photos for reel",
                flush=True,
            )
            try:
                selected = select_reel_photos(photos, count=DEFAULT_MAX_REEL_PHOTOS)
                photos = [str(p) for p in selected]
                print(f"[generate_week] {day_name}: selected {len(photos)} photos", flush=True)
            except Exception as e:
                print(
                    f"[generate_week] {day_name}: photo selection failed ({e}), using all {len(photos)} photos",
                    flush=True,
                    file=sys.stderr,
                )

        print(f"[generate_week] {day_name}: generating {len(photos)} photo(s) ({post_type})", flush=True)

        try:
            result = generate_caption(
                event=event,
                org=org,
                venue=venue,
                date=date,
                day=day_name,
                photo_paths=photos,
                program=program,
                shoot_type=shoot_type,
                post_type=post_type,
                tag_handles=tag_handles,
                name_mentions=name_mentions,
                existing_captions=existing_captions if existing_captions else None,
            )
            results[day_name] = result
            if result.get("caption"):
                existing_captions.append(result["caption"])
            print(f"[generate_week] {day_name}: done", flush=True)
        except Exception as e:
            print(f"[generate_week] {day_name}: ERROR — {e}", flush=True, file=sys.stderr)
            errors[day_name] = str(e)
            results[day_name] = None

    # Blog post
    if blog_photos:
        print(f"[generate_week] blog: generating with {len(blog_photos)} photo(s)", flush=True)
        try:
            blog_result = generate_blog(
                event=event,
                org=org,
                venue=venue,
                date=date,
                program=program,
                photo_paths=blog_photos,
                shoot_type=shoot_type,
            )
            results["blog"] = blog_result
            print("[generate_week] blog: done", flush=True)
        except Exception as e:
            print(f"[generate_week] blog: ERROR — {e}", flush=True, file=sys.stderr)
            errors["blog"] = str(e)
            results["blog"] = None
    else:
        results["blog"] = None

    results["errors"] = errors

    output_path.write_text(
        json.dumps(results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"[generate_week] output written to {output_path}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Generate all captions + blog post for one PostRoll event week"
    )
    parser.add_argument("--manifest", required=True, help="Path to manifest JSON")
    parser.add_argument("--output",   required=True, help="Path to write output JSON")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
    generate_week(manifest_data, Path(args.output))
