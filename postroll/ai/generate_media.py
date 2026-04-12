"""
PostRoll — Media Generation Orchestrator

Generates all visual assets for one event week. Takes the same manifest
format as generate_week.py and writes a JSON output listing generated file paths.

Day-specific asset types
────────────────────────
Sunday / Monday   → story image (story template)
Tuesday           → speed edit reel (screen recording + RAW + edited → MP4)
                    Falls back to story template if reel inputs are missing.
Wednesday         → masonry collage (10+ photos required)
                    The collage IS the story — no story template is generated.
Thursday          → photo scroll reel (MP4)
                    Audio auto-fetched from Jamendo if not provided.
Friday            → before/after story (RAW + edited → PNG)
                    Falls back to story template if before/after inputs are missing.

Manifest format (input — same as generate_week.py):
{
  "event": "Vocal Colors",
  "org": "DCINY",
  "venue": "David Geffen Hall",
  "date": "2026-04-04",
  "days": {
    "sunday":    { "photos": ["/path/to/p1.jpg"] },
    "monday":    { "photos": [...] },
    "tuesday":   { "photos": [...],
                   "screen_recording": "/path/to/rec.mov",   # optional → enables reel
                   "raw_photo": "/path/to/raw.jpg",          # optional → enables reel
                   "edited_photo": "/path/to/edit.jpg",      # optional → enables reel
                   "audio": "/path/to/audio.m4a" },          # optional → Jamendo fallback
    "wednesday": { "photos": [...] },
    "thursday":  { "photos": [...],
                   "audio": "/path/to/audio.m4a" },          # optional → Jamendo fallback
    "friday":    { "photos": [...],
                   "raw_photo": "/path/to/raw.jpg",          # optional → enables before/after
                   "edited_photo": "/path/to/edit.jpg" }     # optional → enables before/after
  }
}

Output JSON (written to --output file):
{
  "sunday":    { "story": "/path/to/sunday/story.png" },
  "monday":    { "story": "/path/to/monday/story.png" },
  "tuesday":   { "reel": "/path/to/tuesday/reel_screen.mp4" },  # or "story" if no reel inputs
  "wednesday": { "collage": "/path/to/wednesday/collage.png" }, # no story key — collage IS the story
  "thursday":  { "reel": "/path/to/thursday/reel_scroll.mp4" },
  "friday":    { "before_after": "/path/to/friday/before_after.png" }, # or "story" if no raw/edit
  "errors": {}   <- keyed by day name if a day failed
}
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
from ..media.generate_before_after import generate_before_after

ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
LOGO_WHITE = str(ASSETS_DIR / "logo-white.png")
LOGO_BLACK = str(ASSETS_DIR / "logo-black.png")

DAY_ORDER = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"]

COLLAGE_MIN_PHOTOS = 10
COLLAGE_PHOTO_COUNT = 10


def _slug(text: str) -> str:
    result = text.lower()
    result = re.sub(r"[^a-z0-9]+", "_", result)
    return result.strip("_")


def _has_ffmpeg() -> bool:
    """Return True if ffmpeg is available on PATH."""
    import shutil
    return shutil.which("ffmpeg") is not None


def generate_media(manifest: dict[str, Any], output_dir: Path) -> dict[str, Any]:
    """Generate all visual assets for one event week.

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
    ffmpeg_available = _has_ffmpeg()

    for day_name in DAY_ORDER:
        day_info = days_data.get(day_name, {})
        photos = day_info.get("photos", [])

        if not photos:
            results[day_name] = None
            continue

        day_dir = base_dir / day_name
        day_dir.mkdir(parents=True, exist_ok=True)
        day_result: dict[str, str] = {}

        # ──────────────────────────────────────────────────────────────
        # Sunday / Monday — story template
        # ──────────────────────────────────────────────────────────────
        if day_name in ("sunday", "monday"):
            try:
                story_path = str(day_dir / "story.png")
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

        # ──────────────────────────────────────────────────────────────
        # Tuesday — speed edit reel (screen recording + RAW + edited)
        # Falls back to story template if any required inputs are missing
        # or ffmpeg is unavailable.
        # ──────────────────────────────────────────────────────────────
        elif day_name == "tuesday":
            rec            = day_info.get("screen_recording")
            raw            = day_info.get("raw_photo")
            edit           = day_info.get("edited_photo")
            audio          = day_info.get("audio")
            target_duration = float(day_info.get("target_duration", 20.0))

            if rec and raw and edit and ffmpeg_available:
                try:
                    from ..media.generate_reel_screen import generate_reel_screen
                    reel_path = str(day_dir / "reel_screen.mp4")
                    generate_reel_screen(
                        recording_path=rec,
                        raw_path=raw,
                        edit_path=edit,
                        audio_path=audio,
                        event_name=event,
                        org=org,
                        venue=venue,
                        output_path=reel_path,
                        logo_path=LOGO_WHITE if Path(LOGO_WHITE).exists() else None,
                        target_duration=target_duration,
                    )
                    day_result["reel"] = reel_path
                    print(f"[generate_media] tuesday: reel → {reel_path}", flush=True)
                except Exception as e:
                    msg = f"speed edit reel failed: {e}"
                    print(f"[generate_media] tuesday: ERROR — {msg}", flush=True, file=sys.stderr)
                    errors["tuesday"] = msg
            else:
                # Fallback: story template from first photo
                reason = "ffmpeg not available" if not ffmpeg_available else "missing screen_recording/raw_photo/edited_photo"
                print(f"[generate_media] tuesday: reel skipped ({reason}), generating story", flush=True)
                try:
                    story_path = str(day_dir / "story.png")
                    generate_story(
                        photo_path=photos[0],
                        event_name=event,
                        org=org,
                        venue=venue,
                        output_path=story_path,
                        logo_path=LOGO_WHITE if Path(LOGO_WHITE).exists() else None,
                    )
                    day_result["story"] = story_path
                except Exception as e:
                    errors["tuesday"] = f"story fallback failed: {e}"

        # ──────────────────────────────────────────────────────────────
        # Wednesday — masonry collage (the collage IS the story)
        # ──────────────────────────────────────────────────────────────
        elif day_name == "wednesday":
            if len(photos) >= COLLAGE_MIN_PHOTOS:
                try:
                    collage_path = str(day_dir / "collage.png")
                    selected = photos[:COLLAGE_PHOTO_COUNT]
                    # crop_offsets: list of [x, y] pairs from manifest
                    raw_offsets = day_info.get("crop_offsets")
                    crop_offsets = (
                        [tuple(o) for o in raw_offsets[:COLLAGE_PHOTO_COUNT]]
                        if raw_offsets else None
                    )
                    seed = day_info.get("collage_seed")
                    generate_collage(
                        photo_paths=selected,
                        output_path=collage_path,
                        event_name=event,
                        org=org,
                        venue=venue,
                        logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None,
                        seed=seed,
                        crop_offsets=crop_offsets,
                    )
                    day_result["collage"] = collage_path
                    print(f"[generate_media] wednesday: collage → {collage_path}", flush=True)
                except Exception as e:
                    msg = f"collage failed: {e}"
                    print(f"[generate_media] wednesday: ERROR — {msg}", flush=True, file=sys.stderr)
                    errors["wednesday"] = msg
            else:
                msg = f"collage skipped — needs {COLLAGE_MIN_PHOTOS}+ photos, got {len(photos)}"
                print(f"[generate_media] wednesday: {msg}", flush=True)
                errors["wednesday"] = msg

        # ──────────────────────────────────────────────────────────────
        # Thursday — photo scroll reel (audio auto-fetched if not provided)
        # Requires ffmpeg.
        # ──────────────────────────────────────────────────────────────
        elif day_name == "thursday":
            if ffmpeg_available:
                audio           = day_info.get("audio")
                scroll_duration = float(day_info.get("scroll_duration", 30.0))
                seed            = day_info.get("reel_seed")
                try:
                    from ..media.generate_reel_scroll import generate_reel_scroll
                    reel_path = str(day_dir / "reel_scroll.mp4")
                    generate_reel_scroll(
                        photo_paths=photos,
                        audio_path=audio,
                        event_name=event,
                        org=org,
                        venue=venue,
                        output_path=reel_path,
                        logo_path=LOGO_WHITE if Path(LOGO_WHITE).exists() else None,
                        scroll_duration=scroll_duration,
                        seed=seed,
                    )
                    day_result["reel"] = reel_path
                    print(f"[generate_media] thursday: reel → {reel_path}", flush=True)
                except Exception as e:
                    msg = f"scroll reel failed: {e}"
                    print(f"[generate_media] thursday: ERROR — {msg}", flush=True, file=sys.stderr)
                    errors["thursday"] = msg
            else:
                print("[generate_media] thursday: reel skipped — ffmpeg not available", flush=True)
                errors["thursday"] = "ffmpeg not available — install ffmpeg to generate Thursday reel"

        # ──────────────────────────────────────────────────────────────
        # Friday — before/after story (RAW + edited)
        # Falls back to story template if inputs are missing.
        # ──────────────────────────────────────────────────────────────
        elif day_name == "friday":
            raw  = day_info.get("raw_photo")
            edit = day_info.get("edited_photo")

            if raw and edit:
                try:
                    ba_path = str(day_dir / "before_after.png")
                    generate_before_after(
                        raw_path=raw,
                        edit_path=edit,
                        output_path=ba_path,
                        logo_path=LOGO_WHITE if Path(LOGO_WHITE).exists() else None,
                    )
                    day_result["before_after"] = ba_path
                    print(f"[generate_media] friday: before/after → {ba_path}", flush=True)
                except Exception as e:
                    msg = f"before/after failed: {e}"
                    print(f"[generate_media] friday: ERROR — {msg}", flush=True, file=sys.stderr)
                    errors["friday"] = msg
            else:
                # Fallback: story template
                reason = "missing raw_photo/edited_photo"
                print(f"[generate_media] friday: before/after skipped ({reason}), generating story", flush=True)
                try:
                    story_path = str(day_dir / "story.png")
                    generate_story(
                        photo_path=photos[0],
                        event_name=event,
                        org=org,
                        venue=venue,
                        output_path=story_path,
                        logo_path=LOGO_WHITE if Path(LOGO_WHITE).exists() else None,
                    )
                    day_result["story"] = story_path
                except Exception as e:
                    errors["friday"] = f"story fallback failed: {e}"

        results[day_name] = day_result or None

    results["errors"] = errors
    print(f"[generate_media] done — output in {base_dir}", flush=True)
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Generate day-specific visual assets for one event week"
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
