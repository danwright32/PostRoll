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
                   "bw_photo": "/path/to/bw.jpg",            # optional → 3-photo reveal (color over B&W)
                   "audio": "/path/to/audio.m4a" },          # optional → Jamendo fallback
    "wednesday": { "photos": [...] },
    "thursday":  { "photos": [...],
                   "audio": "/path/to/audio.m4a" },          # optional → Jamendo fallback
    "friday":    { "photos": [...],
                   "raw_photo": "/path/to/raw.jpg",          # optional → enables before/after
                   "edited_photo": "/path/to/edit.jpg",      # optional → enables before/after
                   "bw_photo": "/path/to/bw.jpg" }           # optional → 3-photo graphic (RAW / color / B&W)
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
import random
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

from ..media.generate_story import generate_story
from ..media.generate_collage import generate_collage
from ..media.generate_before_after import generate_before_after

ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
LOGO_WHITE = str(ASSETS_DIR / "logo-white.png")
LOGO_BLACK = str(ASSETS_DIR / "logo-black.png")

DAY_ORDER = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"]

# On-disk folder names used for exports. Numbered so Finder sorts chronologically.
# Must match DayName.folderName in PostRollApp/Sources/Models/Event.swift.
DAY_FOLDER_NAMES = {
    "sunday":    "1. Sunday",
    "monday":    "2. Monday",
    "tuesday":   "3. Tuesday",
    "wednesday": "4. Wednesday",
    "thursday":  "5. Thursday",
    "friday":    "6. Friday",
}

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


# Thursday's audio tag derivation lives in postroll.ai.audio_tags so the
# Swift-side track picker can call the same logic via a CLI shim.
from .audio_tags import thursday_tags as _derive_audio_tags  # noqa: E402


def generate_media(
    manifest: dict[str, Any],
    output_dir: Path,
    *,
    static_only: bool = False,
    only_days: set[str] | None = None,
    final_export: bool = False,
) -> dict[str, Any]:
    """Generate all visual assets for one event week.

    Args:
        manifest: Event manifest dict.
        output_dir: Root directory; a slug subfolder is created inside it.
        static_only: When True, skip video reel generation (Tuesday speed edit
            and Thursday scroll reel). Tuesday generates a before/after PNG if
            raw/edited photos are available, or falls back to a story template.
            Thursday generates a story template from its first photo. Use this
            for fast preview generation before export.
        final_export: When True, suppress caption-review editor sidecars —
            Wednesday's collage_layout.json, Thursday's reel_preview.png +
            reel_preview_layout.json — and write Tuesday's before/after PNG
            to a temp path (still needed as the reel's closing frame) so it
            doesn't end up in the final export folder.

    Returns a dict mapping day names → generated file paths, plus an
    'errors' dict for any days that failed.
    """
    event      = manifest["event"]
    org        = manifest["org"]
    venue      = manifest["venue"]
    shoot_type = manifest.get("shoot_type", "performance")
    pieces     = manifest.get("pieces", [])
    days_data  = manifest.get("days", {})

    folder_name = f"{_slug(org)}_{_slug(event)}_{manifest.get('date', 'undated')}"
    base_dir = output_dir / folder_name
    base_dir.mkdir(parents=True, exist_ok=True)

    results: dict[str, Any] = {}
    errors: dict[str, str] = {}
    ffmpeg_available = _has_ffmpeg()

    for day_name in DAY_ORDER:
        if only_days is not None and day_name not in only_days:
            continue
        day_info = days_data.get(day_name, {})
        photos = day_info.get("photos", [])

        if not photos:
            # Tuesday and Friday can operate without the generic photos list —
            # they use raw_photo / edited_photo instead.
            if day_name not in ("tuesday", "friday") or (
                not day_info.get("raw_photo") and not day_info.get("edited_photo")
            ):
                results[day_name] = None
                continue

        day_dir = base_dir / DAY_FOLDER_NAMES[day_name]
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
                    logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None,
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
            bw             = day_info.get("bw_photo")   # optional B&W after → 3-photo treatment
            audio          = day_info.get("audio")
            target_duration = float(day_info.get("target_duration", 20.0))

            # 3-photo mode (B&W present) always uses the slider reveal so the
            # color-over-B&W reveal reads consistently; otherwise pick a style.
            reel_style = "slider" if bw else (
                day_info.get("reel_style") or random.choice(["slider", "morph"])
            )

            # Also generate the standalone before/after PNG. Serves two roles:
            #   1. Closing frame for the slider/morph reel (always needed on disk).
            #   2. Standalone story cover in the final export folder.
            # On final export we only need (1), so write to a temp path that
            # gets cleaned up at the end of this branch.
            tuesday_ba_tempfile: tempfile._TemporaryFileWrapper | None = None
            if final_export:
                tuesday_ba_tempfile = tempfile.NamedTemporaryFile(
                    suffix="_tuesday_before_after.png", delete=False,
                )
                tuesday_ba_tempfile.close()
                ba_path = tuesday_ba_tempfile.name
            else:
                ba_path = str(day_dir / "before_after.png")
            if raw and edit:
                try:
                    generate_before_after(
                        raw_path=raw,
                        edit_path=edit,
                        output_path=ba_path,
                        event_name=event,
                        org=org,
                        venue=venue,
                        logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None,
                        bw_path=bw,
                    )
                    if not final_export:
                        day_result["story_cover"] = ba_path
                    print(f"[generate_media] tuesday: before/after → {ba_path}", flush=True)
                except Exception as e:
                    print(f"[generate_media] tuesday: before/after failed (non-fatal): {e}", flush=True, file=sys.stderr)
                    ba_path = None

            if ffmpeg_available and not static_only and raw and edit:
                # Screen recording reel takes priority when available — except in
                # 3-photo mode, which always uses the still-image slider reveal.
                if rec and not bw:
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
                        print(f"[generate_media] tuesday: screen reel → {reel_path}", flush=True)
                    except Exception as e:
                        msg = f"speed edit reel failed: {e}"
                        print(f"[generate_media] tuesday: ERROR — {msg}", flush=True, file=sys.stderr)
                        errors["tuesday"] = msg
                else:
                    # Still-image reel: slider reveal or split-compare morph
                    try:
                        if reel_style == "morph":
                            from ..media.generate_reel_morph import generate_reel_morph
                            reel_path = str(day_dir / "reel_morph.mp4")
                            generate_reel_morph(
                                raw_path=raw,
                                edit_path=edit,
                                audio_path=audio,
                                output_path=reel_path,
                                event_name=event,
                                org=org,
                                venue=venue,
                                closing_frame_path=ba_path,
                                logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None,
                            )
                        else:  # slider (default)
                            from ..media.generate_reel_slider import generate_reel_slider
                            reel_path = str(day_dir / "reel_slider.mp4")
                            generate_reel_slider(
                                raw_path=raw,
                                edit_path=edit,
                                audio_path=audio,
                                output_path=reel_path,
                                event_name=event,
                                org=org,
                                venue=venue,
                                closing_frame_path=ba_path,
                                logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None,
                                bw_path=bw,
                            )
                        day_result["reel"] = reel_path
                        print(f"[generate_media] tuesday: {reel_style} reel → {reel_path}", flush=True)
                    except Exception as e:
                        msg = f"{reel_style} reel failed: {e}"
                        print(f"[generate_media] tuesday: ERROR — {msg}", flush=True, file=sys.stderr)
                        errors["tuesday"] = msg
            elif not ffmpeg_available:
                print("[generate_media] tuesday: reel skipped (ffmpeg not available)", flush=True)
            elif static_only:
                print("[generate_media] tuesday: reel skipped (static-only preview)", flush=True)
            else:
                print("[generate_media] tuesday: reel skipped (no raw/edited photos assigned)", flush=True)

            # Story fallback if no reel was produced
            if "reel" not in day_result and photos:
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

            # Clean up the temp before/after PNG (used only as the reel's
            # closing frame during final export).
            if tuesday_ba_tempfile is not None:
                try:
                    Path(tuesday_ba_tempfile.name).unlink(missing_ok=True)
                except Exception:
                    pass

        # ──────────────────────────────────────────────────────────────
        # Wednesday — masonry collage (the collage IS the story)
        # ──────────────────────────────────────────────────────────────
        elif day_name == "wednesday":
            if len(photos) >= COLLAGE_MIN_PHOTOS:
                try:
                    collage_path = str(day_dir / "collage.png")
                    selected = photos[:COLLAGE_PHOTO_COUNT]
                    # crop_offsets: list of [x, y, zoom] triples from manifest
                    raw_offsets = day_info.get("crop_offsets")
                    crop_offsets = (
                        [tuple(o) for o in raw_offsets[:COLLAGE_PHOTO_COUNT]]
                        if raw_offsets else None
                    )
                    seed = day_info.get("collage_seed")
                    # cell_layout: user-dragged frame positions — skips masonry if present
                    cell_layout = day_info.get("cell_layout")
                    generate_collage(
                        photo_paths=selected,
                        output_path=collage_path,
                        event_name=event,
                        org=org,
                        venue=venue,
                        logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None,
                        seed=seed,
                        crop_offsets=crop_offsets,
                        cell_layout=cell_layout,
                        write_layout_sidecar=not final_export,
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
            if ffmpeg_available and not static_only:
                audio           = day_info.get("audio")
                scroll_duration = float(day_info.get("scroll_duration", 40.0))
                seed            = day_info.get("reel_seed")
                crop_offsets    = day_info.get("crop_offsets")  # list[(x, y, zoom)] parallel to photos
                audio_tags      = _derive_audio_tags(shoot_type, pieces)
                print(f"[generate_media] thursday: audio tags → {audio_tags!r}", flush=True)
                print(f"[generate_media] thursday: {len(photos)} photos from manifest:", flush=True)
                for i, p in enumerate(photos):
                    print(f"  [{i}] {Path(p).name}", flush=True)
                try:
                    from ..media.generate_reel_scroll import generate_reel_scroll, build_reel_preview
                    reel_path = str(day_dir / "reel_scroll.mp4")
                    generate_reel_scroll(
                        photo_paths=photos,
                        audio_path=audio,
                        audio_tags=audio_tags,
                        pieces=pieces,
                        event_name=event,
                        org=org,
                        venue=venue,
                        output_path=reel_path,
                        logo_path=LOGO_WHITE if Path(LOGO_WHITE).exists() else None,
                        scroll_duration=scroll_duration,
                        seed=seed,
                        crop_offsets=crop_offsets,
                    )
                    # Also write a fast preview PNG + layout sidecar so the
                    # caption-review step can open the per-cell editor without
                    # re-running ffmpeg. Skipped on final export — these are
                    # review-only artifacts.
                    if not final_export:
                        try:
                            preview_png = str(day_dir / "reel_preview.png")
                            build_reel_preview(
                                photo_paths=photos,
                                output_path=preview_png,
                                seed=seed,
                                crop_offsets=crop_offsets,
                            )
                            day_result["reel_preview"] = preview_png
                        except Exception as preview_err:
                            print(f"[generate_media] thursday: preview skipped — {preview_err}", flush=True)
                    day_result["reel"] = reel_path
                    print(f"[generate_media] thursday: reel → {reel_path}", flush=True)
                except Exception as e:
                    msg = f"scroll reel failed: {e}"
                    print(f"[generate_media] thursday: ERROR — {msg}", flush=True, file=sys.stderr)
                    errors["thursday"] = msg
            else:
                if static_only:
                    print("[generate_media] thursday: reel skipped (static-only preview), generating story", flush=True)
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
                        errors["thursday"] = f"story fallback failed: {e}"
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
            bw   = day_info.get("bw_photo")   # optional B&W after → 3-photo graphic

            if raw and edit:
                try:
                    ba_path = str(day_dir / "before_after.png")
                    generate_before_after(
                        raw_path=raw,
                        edit_path=edit,
                        output_path=ba_path,
                        event_name=event,
                        org=org,
                        venue=venue,
                        logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None,
                        bw_path=bw,
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
                if photos:
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
    parser.add_argument(
        "--static-only",
        action="store_true",
        help="Skip video reel generation (Tuesday speed edit and Thursday scroll). "
             "Use for fast preview generation before export.",
    )
    parser.add_argument(
        "--only-days",
        nargs="+",
        metavar="DAY",
        help="Regenerate only these days (e.g. --only-days sunday wednesday). "
             "Other days are skipped entirely.",
    )
    parser.add_argument(
        "--final-export",
        action="store_true",
        help="Suppress caption-review editor sidecars (collage_layout.json, "
             "reel_preview.png, reel_preview_layout.json) and write Tuesday's "
             "before/after PNG to a temp path. Use when generating into the "
             "user's final export folder.",
    )
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    result = generate_media(
        manifest_data,
        output_dir,
        static_only=args.static_only,
        only_days=set(args.only_days) if args.only_days else None,
        final_export=args.final_export,
    )

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"[generate_media] result written to {output_path}", flush=True)
