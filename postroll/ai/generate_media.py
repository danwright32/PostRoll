"""
PostRoll — Media Generation Orchestrator

Generates all visual assets (story images, Wednesday collage) for one
event week. Takes the same manifest format as generate_week.py and writes
a JSON output listing the generated file paths.

Story images are generated for every day that has photos.
A masonry collage is generated for Wednesday when there are 10+ photos.

Reels are NOT generated here — they require ffmpeg and are out of scope
for the basic GUI export. Run the reel generators manually if needed.

Manifest format (input — same as generate_week.py):
{
  "event": "Vocal Colors",
  "org": "DCINY",
  "venue": "David Geffen Hall",
  "date": "2026-04-04",
  "days": {
    "sunday": { "photos": ["/path/to/p1.jpg"] },
    "monday": { "photos": [...] },
    "wednesday": { "photos": [...] },
    ...
  }
}

Output JSON (written to --output file):
{
  "sunday":    { "story": "/path/to/sunday/story.png" },
  "monday":    { "story": "/path/to/monday/story.png" },
  "wednesday": { "story": "/path/to/wednesday/story.png",
                 "collage": "/path/to/wednesday/collage.png" },
  ...
  "errors": {}   <- keyed by day name if a day failed
}

All outputs are placed under --output-dir/{org_slug}_{event_slug}_{date}/.

Usage:
    python -m postroll.ai.generate_media \\
        --manifest /path/to/manifest.json \\
        --output-dir /path/to/export/root \\
        --output /path/to/result.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from ..media.generate_story import generate_story
from ..media.generate_collage import generate_collage

ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
LOGO_WHITE = str(ASSETS_DIR / "logo-white.png")
LOGO_BLACK = str(ASSETS_DIR / "logo-black.png")

DAY_ORDER = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"]

# Wednesday needs at least this many photos for a collage
COLLAGE_MIN_PHOTOS = 10
COLLAGE_PHOTO_COUNT = 10  # collage always uses exactly 10


def _slug(text: str) -> str:
    result = text.lower()
    result = re.sub(r"[^a-z0-9]+", "_", result)
    return result.strip("_")


def generate_media(manifest: dict[str, Any], output_dir: Path) -> dict[str, Any]:
    """Generate story images (+ Wednesday collage) for one event week.

    Returns a dict mapping day names → generated file paths, plus an
    'errors' dict for any days that failed.
    """
    event = manifest["event"]
    org = manifest["org"]
    venue = manifest["venue"]
    days_data = manifest.get("days", {})

    folder_name = f"{_slug(org)}_{_slug(event)}_{manifest.get('date', 'undated')}"
    base_dir = output_dir / folder_name
    base_dir.mkdir(parents=True, exist_ok=True)

    results: dict[str, Any] = {}
    errors: dict[str, str] = {}

    for day_name in DAY_ORDER:
        day_info = days_data.get(day_name, {})
        photos = day_info.get("photos", [])

        if not photos:
            results[day_name] = None
            continue

        day_dir = base_dir / day_name
        day_dir.mkdir(parents=True, exist_ok=True)
        day_result: dict[str, str] = {}

        # === Story image (all days) ===
        try:
            story_path = str(day_dir / "story.png")
            # Use the first photo for the story hero
            generate_story(
                photo_path=photos[0],
                event_name=event,
                org=org,
                venue=venue,
                output_path=story_path,
                logo_path=LOGO_WHITE if Path(LOGO_WHITE).exists() else None,
            )
            day_result["story"] = story_path
            print(f"[generate_media] {day_name}: story → {story_path}", flush=True)
        except Exception as e:
            msg = f"story failed: {e}"
            print(f"[generate_media] {day_name}: ERROR — {msg}", flush=True, file=sys.stderr)
            errors[day_name] = msg

        # === Wednesday collage (10+ photos) ===
        if day_name == "wednesday" and len(photos) >= COLLAGE_MIN_PHOTOS:
            try:
                collage_path = str(day_dir / "collage.png")
                selected = photos[:COLLAGE_PHOTO_COUNT]
                generate_collage(
                    photo_paths=selected,
                    output_path=collage_path,
                    event_name=event,
                    org=org,
                    venue=venue,
                    logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None,
                )
                day_result["collage"] = collage_path
                print(f"[generate_media] wednesday: collage → {collage_path}", flush=True)
            except Exception as e:
                msg = f"collage failed: {e}"
                print(f"[generate_media] wednesday collage: ERROR — {msg}", flush=True, file=sys.stderr)
                errors.setdefault("wednesday_collage", msg)

        results[day_name] = day_result or None

    results["errors"] = errors
    print(f"[generate_media] done — output in {base_dir}", flush=True)
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Generate story images and collage for one event week"
    )
    parser.add_argument("--manifest", required=True, help="Path to manifest JSON")
    parser.add_argument("--output-dir", required=True, help="Root directory for generated assets")
    parser.add_argument("--output", required=True, help="Path to write output JSON")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    result = generate_media(manifest_data, output_dir)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"[generate_media] result written to {output_path}", flush=True)
