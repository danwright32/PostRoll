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
import time
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


def generate_week(manifest: dict[str, Any], output_path: Path, timing_path: Path | None = None) -> None:
    """Run caption + blog generation for one event week."""
    event         = manifest["event"]
    org           = manifest["org"]
    venue         = manifest["venue"]
    venue_context = manifest.get("venue_context", "") or ""
    date          = manifest["date"]
    shoot_type    = manifest.get("shoot_type", "performance")
    program       = manifest["program"]
    days_data     = manifest.get("days", {})
    blog_photos   = manifest.get("blog_photos", [])
    event_url     = manifest.get("event_url", "")

    results: dict[str, Any] = {}
    errors:  dict[str, str] = {}
    existing_captions: list[str] = []

    t_start = time.time()
    t_captions_start: float | None = None
    t_captions_end: float | None = None
    t_blog_start: float | None = None
    t_blog_end: float | None = None

    for day_name in DAY_ORDER:
        if day_name == "friday":
            results[day_name] = None
            print(f"[generate_week] {day_name}: story-only day, skipping caption", flush=True)
            continue

        day_info = days_data.get(day_name, {})
        photos   = day_info.get("photos", [])

        if not photos:
            results[day_name] = None
            print(f"[generate_week] {day_name}: no photos, skipping", flush=True)
            continue

        post_type    = day_info.get("post_type") or _auto_post_type(day_name, len(photos))
        tag_handles  = day_info.get("tag_handles") or None
        name_mentions = day_info.get("name_mentions") or None
        notes        = day_info.get("notes", "")
        photo_tags   = day_info.get("photo_tags") or None

        # For Thursday's scroll reel: the reel itself can have 50-200+ photos
        # (the visual asset is generated locally by ffmpeg), but Claude only
        # needs a representative sample to write the caption. Wednesday's
        # collage photos are already the curated 10-photo sample of the event,
        # so reuse them as Claude's context — same event, same shoot, no extra
        # selection step, never blows past Claude's request size limit.
        if day_name == "thursday" and post_type == "scroll_reel":
            # Look up Wednesday's photos from either the days dict (when
            # Wednesday is included in this run) OR from the dedicated
            # caption_context_photos field (always present, survives single-day
            # retries that filter Wednesday out of the days dict).
            wed_photos = (days_data.get("wednesday") or {}).get("photos") or []
            if not wed_photos:
                wed_photos = (
                    manifest.get("caption_context_photos") or {}
                ).get("wednesday") or []
            if wed_photos:
                print(
                    f"[generate_week] thursday: using {len(wed_photos)} wednesday "
                    f"photo(s) as caption context (reel uses all {len(photos)})",
                    flush=True,
                )
                photos = list(wed_photos)
            elif len(photos) >= REEL_SELECTION_THRESHOLD:
                # Fallback: no Wednesday photos available — fall back to the
                # old representative-selection path.
                print(
                    f"[generate_week] thursday: no wednesday photos; selecting "
                    f"best {DEFAULT_MAX_REEL_PHOTOS} from {len(photos)} for caption",
                    flush=True,
                )
                try:
                    selected = select_reel_photos(photos, count=DEFAULT_MAX_REEL_PHOTOS)
                    photos = [str(p) for p in selected]
                except Exception as e:
                    print(
                        f"[generate_week] thursday: photo selection failed ({e}); "
                        f"capping at first {DEFAULT_MAX_REEL_PHOTOS} as a safeguard",
                        flush=True, file=sys.stderr,
                    )
                    photos = photos[:DEFAULT_MAX_REEL_PHOTOS]

        print(f"[generate_week] {day_name}: generating {len(photos)} photo(s) ({post_type})", flush=True)
        if t_captions_start is None:
            t_captions_start = time.time()

        try:
            result = generate_caption(
                event=event,
                org=org,
                venue=venue,
                venue_context=venue_context,
                date=date,
                day=day_name,
                photo_paths=photos,
                program=program,
                shoot_type=shoot_type,
                post_type=post_type,
                tag_handles=tag_handles,
                name_mentions=name_mentions,
                notes=notes,
                photo_tags=photo_tags,
                existing_captions=existing_captions if existing_captions else None,
                event_url=event_url,
            )
            results[day_name] = result
            if result.get("caption"):
                existing_captions.append(result["caption"])
            t_captions_end = time.time()
            print(f"[generate_week] {day_name}: done", flush=True)
        except Exception as e:
            t_captions_end = time.time()
            print(f"[generate_week] {day_name}: ERROR — {e}", flush=True, file=sys.stderr)
            errors[day_name] = str(e)
            results[day_name] = None

    # Blog post
    if blog_photos:
        t_blog_start = time.time()
        print(f"[generate_week] blog: generating with {len(blog_photos)} photo(s)", flush=True)
        try:
            blog_result = generate_blog(
                event=event,
                org=org,
                venue=venue,
                venue_context=venue_context,
                date=date,
                program=program,
                photo_paths=blog_photos,
                shoot_type=shoot_type,
                event_url=event_url,
            )
            results["blog"] = blog_result
            t_blog_end = time.time()
            print("[generate_week] blog: done", flush=True)
        except Exception as e:
            t_blog_end = time.time()
            print(f"[generate_week] blog: ERROR — {e}", flush=True, file=sys.stderr)
            errors["blog"] = str(e)
            results["blog"] = None
    else:
        results["blog"] = None

    t_total = time.time()
    results["errors"] = errors

    output_path.write_text(
        json.dumps(results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"[generate_week] output written to {output_path}", flush=True)

    # Write per-phase timing data for the Swift layer to consume
    if timing_path is not None:
        elapsed = t_total - t_start
        captions = (t_captions_end - t_captions_start) if (t_captions_start and t_captions_end) else None
        blog     = (t_blog_end - t_blog_start)         if (t_blog_start and t_blog_end)         else None
        packaging = elapsed - (captions or 0) - (blog or 0) - (t_captions_start - t_start if t_captions_start else 0)
        timing = {
            "total":      elapsed,
            "captions":   captions,
            "blog":       blog,
            "packaging":  max(packaging, 0.0),
        }
        timing_path.write_text(json.dumps(timing), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Generate all captions + blog post for one PostRoll event week"
    )
    parser.add_argument("--manifest", required=True, help="Path to manifest JSON")
    parser.add_argument("--output",   required=True, help="Path to write output JSON")
    parser.add_argument("--timing",   default=None,  help="Optional path to write per-phase timing JSON")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
    generate_week(manifest_data, Path(args.output), Path(args.timing) if args.timing else None)
