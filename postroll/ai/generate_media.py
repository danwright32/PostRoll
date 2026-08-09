"""
PostRoll — Media Generation Orchestrator

Generates all visual assets for one event week. Takes the same manifest
format as generate_week.py and writes a JSON output listing generated file paths.

Day-specific asset types
────────────────────────
Sunday / Monday / Wednesday → governed by the posting preset (see
                    postroll.posting_preset). In the "balanced" default each is
                    a 4 photo carousel whose collage doubles as the story. In
                    "classic" Sunday/Monday are single feed photos + story and
                    Wednesday is a 10 photo carousel + collage.
Tuesday           → speed edit reel (screen recording + RAW + edited → MP4)
                    Falls back to story template if reel inputs are missing.
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
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from ..media.generate_story import generate_story
from ..media.generate_collage import generate_collage
from ..media.generate_before_after import generate_before_after
from ..media.clip_scorer import score_clips, InsufficientClipsError
from ..media.render_clip_reel import render_clip_reel, DEFAULT_DUCK_GAIN_DB
from ..media.generate_title_card import apply_title_card, TitleCardError
from .audio_tags import resolve_reel_audio
from .select_reel_clips import select_reel_clips
from .select_cover_photo import (
    select_cover_photo,
    # Re-exported: the cover tests pin the per-clip frame count through this
    # module, which is where the behaviour lives from their point of view.
    COVER_FRAMES_PER_CLIP,  # noqa: F401
    _cover_candidates_from_photos,
    _cover_candidates_from_friday_plan,
)
from ..posting_preset import (
    DEFAULT_PRESET,
    COLLAGE_CAROUSEL,
    SINGLE,
    day_format,
)

ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
LOGO_WHITE = str(ASSETS_DIR / "logo-white.png")
LOGO_BLACK = str(ASSETS_DIR / "logo-black.png")

# The scroll reel's footer is cream, not a photo, so the mark has to be the dark
# one. It shipped as LOGO_WHITE and rendered white-on-cream: invisible.
THURSDAY_REEL_LOGO = LOGO_BLACK

DAY_ORDER = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"]


def resolve_tuesday_reel_style(bw, requested: str | None) -> str:
    """Which Tuesday reel style to render.

    3-photo mode (a B&W after present) keeps the slider reveal so the
    color-over-B&W reveal reads consistently. Otherwise an explicit request wins,
    and the default is the program-plate morph (the approved Tuesday reel look).
    """
    if bw:
        return "slider"
    return requested or "morph"

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

def _slug(text: str) -> str:
    result = text.lower()
    result = re.sub(r"[^a-z0-9]+", "_", result)
    return result.strip("_")


from ..media.ffmpeg_check import ffmpeg_status  # noqa: E402


def _has_ffmpeg() -> bool:
    """Return True if the whole ffmpeg toolchain (ffmpeg AND ffprobe) is on PATH."""
    return ffmpeg_status().available


# Thursday's audio tag derivation lives in postroll.ai.audio_tags so the
# Swift-side track picker can call the same logic via a CLI shim.
from .audio_tags import thursday_tags as _derive_audio_tags  # noqa: E402

from ..media.missing_media import MissingMediaError, require_present  # noqa: E402


def _record_error(errors: dict, day: str, message: str) -> None:
    """Add a failure to a day's report without erasing what's already there.

    A day can fail for more than one reason at once (a missing B&W photo AND no
    ffmpeg installed). Each write used to replace the last, so whichever check
    ran second silently erased the first and the report claimed one cause when
    there were two. Identical messages are not repeated.
    """
    existing = errors.get(day)
    if not existing:
        errors[day] = message
        return
    if message in existing:
        return
    errors[day] = f"{existing}; {message}"


#: Photos a before/after or a speed-edit reel cannot be made without. Their
#: absence blocks the render, because a substitute would be a different post.
REQUIRED_PHOTO_SLOTS = (("raw_photo", "RAW photo"), ("edited_photo", "edited photo"))

#: Photos that change the treatment when present and are simply not used when
#: absent. Their absence is REPORTED but never blocks: optional has to mean
#: optional, or choosing a file quietly makes it mandatory (Dan, 2026-08-07).
OPTIONAL_PHOTO_SLOTS = (("bw_photo", "B&W photo"),)


def _missing_photos(day_info: dict, slots) -> str | None:
    """Message naming every photo in `slots` this day CHOSE that is not on disk.

    A slot left empty is not missing, so it is not reported; a slot holding a
    path to a file that no longer exists is. One check for both the before/after
    graphic and the reel, so the same input can't crash one surface and quietly
    change the other (#180).
    """
    problems: list[str] = []
    for key, label in slots:
        try:
            require_present(day_info.get(key), label)
        except MissingMediaError as exc:
            problems.append(str(exc))
    return "; ".join(problems) if problems else None


def _resolve_photo_inputs(day_info: dict, day_name: str, errors: dict) -> tuple[str | None, bool]:
    """Report every chosen-but-missing photo, and say whether to render.

    Returns the B&W path to actually use (None when it is unset OR missing) and
    whether the day's required inputs are intact. A missing OPTIONAL photo is
    named in the day's errors and the day still renders, in the form it would
    have taken without that photo. A missing REQUIRED photo stops the render.
    """
    for message in (_missing_photos(day_info, OPTIONAL_PHOTO_SLOTS),
                    _missing_photos(day_info, REQUIRED_PHOTO_SLOTS)):
        if message:
            print(f"[generate_media] {day_name}: ERROR: {message}", flush=True, file=sys.stderr)
            _record_error(errors, day_name, message)

    bw = day_info.get("bw_photo")
    bw_usable = bool(bw) and Path(bw).exists()
    can_render = _missing_photos(day_info, REQUIRED_PHOTO_SLOTS) is None
    return (bw if bw_usable else None), can_render


def _render_cover(
    *,
    day_name: str,
    day_dir: Path,
    day_info: dict,
    build_candidates,
    event: str,
    org: str,
    venue: str,
    day_result: dict,
    errors: dict,
    persist_pick_to: Path | None = None,
) -> None:
    """Sticky-gate cover render, generic across days: reuses a persisted
    cover_source without touching Claude (or the representative-sampling
    call that itself hits Claude) when one exists; otherwise builds
    candidates lazily via `build_candidates` (only invoked when actually
    needed) and picks fresh. Renders through generate_story.py's exact
    template, reusing the same design rather than forking a second one.
    """
    cover_source = day_info.get("cover_source")
    try:
        if cover_source:
            source_path = cover_source
        else:
            candidates = build_candidates()
            if not candidates:
                return
            pick = select_cover_photo(candidates)
            source_path = pick["path"]
            if persist_pick_to is not None:
                # The winning candidate may live in a temp dir (Friday's
                # extracted frames) that's cleaned up right after this call
                # returns; persist it so a later sticky-gate regen can still
                # find it via the source_path saved below.
                shutil.copy2(source_path, persist_pick_to)
                source_path = str(persist_pick_to)
            day_result["cover_pick"] = {"source_path": source_path, "rationale": pick["rationale"]}

        cover_path = str(day_dir / "cover.png")
        generate_story(
            photo_path=source_path,
            event_name=event,
            org=org,
            venue=venue,
            output_path=cover_path,
            logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None,
        )
        day_result["cover"] = cover_path
        print(f"[generate_media] {day_name}: cover → {cover_path}", flush=True)
    except Exception as e:
        msg = f"cover failed: {e}"
        print(f"[generate_media] {day_name}: ERROR: {msg}", flush=True, file=sys.stderr)
        _record_error(errors, day_name, msg)


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
    preset     = manifest.get("preset", DEFAULT_PRESET)

    folder_name = f"{_slug(org)}_{_slug(event)}_{manifest.get('date', 'undated')}"
    base_dir = output_dir / folder_name
    base_dir.mkdir(parents=True, exist_ok=True)

    results: dict[str, Any] = {}
    errors: dict[str, str] = {}
    tools = ffmpeg_status()
    ffmpeg_available = tools.available

    for day_name in DAY_ORDER:
        if only_days is not None and day_name not in only_days:
            continue
        day_info = days_data.get(day_name, {})
        photos = day_info.get("photos", [])

        if not photos:
            # Tuesday and Friday can operate without the generic photos list —
            # Tuesday uses raw_photo/edited_photo, Friday uses those OR clips
            # (the auto-cut reel path, which needs no stills at all).
            if day_name == "tuesday":
                if not day_info.get("raw_photo") and not day_info.get("edited_photo"):
                    results[day_name] = None
                    continue
            elif day_name == "friday":
                if (
                    not day_info.get("raw_photo") and not day_info.get("edited_photo")
                    and not day_info.get("clips")
                ):
                    results[day_name] = None
                    continue
            else:
                results[day_name] = None
                continue

        day_dir = base_dir / DAY_FOLDER_NAMES[day_name]
        day_dir.mkdir(parents=True, exist_ok=True)
        day_result: dict[str, str] = {}

        # ──────────────────────────────────────────────────────────────
        # Preset-governed days (Sunday / Monday / Wednesday). The preset
        # decides whether each is a single feed photo + story or a carousel
        # whose collage doubles as the story.
        # ──────────────────────────────────────────────────────────────
        day_fmt = day_format(preset, day_name)
        if day_fmt is not None:
            kind, count = day_fmt
            if kind == SINGLE:
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
                    _record_error(errors, day_name, msg)
            elif kind == COLLAGE_CAROUSEL:
                try:
                    collage_path = str(day_dir / "collage.png")
                    selected = photos[:count]
                    # crop_offsets: list of [x, y, zoom] triples from manifest
                    raw_offsets = day_info.get("crop_offsets")
                    crop_offsets = (
                        [tuple(o) for o in raw_offsets[:count]]
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
                    print(f"[generate_media] {day_name}: collage ({len(selected)} photos) → {collage_path}", flush=True)
                except Exception as e:
                    msg = f"collage failed: {e}"
                    print(f"[generate_media] {day_name}: ERROR — {msg}", flush=True, file=sys.stderr)
                    _record_error(errors, day_name, msg)

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

            # A chosen photo that has gone missing is a fixable input problem,
            # named in this day's errors. A missing OPTIONAL photo still lets
            # the day render in its without-that-photo form; a missing REQUIRED
            # one stops it, because there is no before/after without a before.
            bw, inputs_ok = _resolve_photo_inputs(day_info, "tuesday", errors)
            missing_inputs = not inputs_ok

            # Resolved AFTER the check: the 3-photo style is picked from the
            # B&W photo's presence, so a missing file has to fall back here too
            # or the style and the render disagree about which post this is.
            reel_style = resolve_tuesday_reel_style(bw, day_info.get("reel_style"))

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
            if raw and edit and not missing_inputs:
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

            if ffmpeg_available and not static_only and raw and edit and not missing_inputs:
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
                            # The DARK mark (#169). The screen reel's footer is
                            # cream at CREAM_OPACITY over the video, so it
                            # composites light whatever the footage is doing, and
                            # the white mark washed out on it, worst over a
                            # bright stage. Fourth time white-on-cream has
                            # shipped invisibly here, so the contrast is pinned
                            # by a measured pixel test.
                            logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None,
                            target_duration=target_duration,
                        )
                        day_result["reel"] = reel_path
                        print(f"[generate_media] tuesday: screen reel → {reel_path}", flush=True)
                    except Exception as e:
                        msg = f"speed edit reel failed: {e}"
                        print(f"[generate_media] tuesday: ERROR — {msg}", flush=True, file=sys.stderr)
                        _record_error(errors, "tuesday", msg)
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
                        _record_error(errors, "tuesday", msg)
            elif not ffmpeg_available:
                # Not a log line and a still image: the reel that was asked for
                # cannot be made, and the person needs the install command (#87).
                print(f"[generate_media] tuesday: ERROR: {tools.message}", flush=True, file=sys.stderr)
                _record_error(errors, "tuesday", tools.message)
            elif static_only:
                print("[generate_media] tuesday: reel skipped (static-only preview)", flush=True)
            else:
                print("[generate_media] tuesday: reel skipped (no raw/edited photos assigned)", flush=True)

            # Story fallback if no reel was produced. Not offered when an input
            # is missing: a story in place of the reel is a different post, and
            # the person needs to fix the file, not receive a substitute.
            if "reel" not in day_result and photos and not missing_inputs:
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
                    _record_error(errors, "tuesday", f"story fallback failed: {e}")

            # Clean up the temp before/after PNG (used only as the reel's
            # closing frame during final export).
            if tuesday_ba_tempfile is not None:
                try:
                    Path(tuesday_ba_tempfile.name).unlink(missing_ok=True)
                except Exception:
                    pass

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
                        logo_path=THURSDAY_REEL_LOGO,
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
                    _record_error(errors, "thursday", msg)
            else:
                if static_only:
                    # No story substitute (#166). Thursday IS the scroll reel
                    # and Dan posts no story that day, so a story.png here is
                    # an asset he will never use, and putting it in the day
                    # result made a skipped reel look like a finished day.
                    print("[generate_media] thursday: reel skipped (static-only preview)", flush=True)
                else:
                    print(f"[generate_media] thursday: ERROR: {tools.message}", flush=True, file=sys.stderr)
                    _record_error(errors, "thursday", tools.message)

            _render_cover(
                day_name="thursday",
                day_dir=day_dir,
                day_info=day_info,
                # B023 is a false positive here: _render_cover calls
                # build_candidates() synchronously, so the lambda never outlives
                # this loop iteration and the late binding cannot bite.
                build_candidates=lambda: _cover_candidates_from_photos(photos),  # noqa: B023
                event=event, org=org, venue=venue,
                day_result=day_result, errors=errors,
            )

        # ──────────────────────────────────────────────────────────────
        # Friday — before/after story (RAW + edited)
        # Falls back to story template if inputs are missing.
        # ──────────────────────────────────────────────────────────────
        elif day_name == "friday":
            raw   = day_info.get("raw_photo")
            edit  = day_info.get("edited_photo")
            bw    = day_info.get("bw_photo")   # optional B&W after → 3-photo graphic
            clips = day_info.get("clips") or []

            # Same named condition as Tuesday, resolved the same way: the two
            # days share these photos, so they must not disagree about what a
            # missing one means (#180).
            bw, inputs_ok = _resolve_photo_inputs(day_info, "friday", errors)
            missing_inputs = not inputs_ok

            # Auto-cut clip reel: only attempted when clips were imported.
            # Any failure (too few usable clips, Claude error, ffmpeg crash)
            # falls through to exactly today's before/after/story behavior
            # below: Friday must never silently produce nothing just
            # because the reel attempt didn't pan out.
            reel_rendered = False
            if clips and not ffmpeg_available and not static_only:
                # Clips were imported for a reel that can't be encoded. The
                # before/after below still runs, but the person is told why the
                # reel isn't there (#87).
                print(f"[generate_media] friday: ERROR: {tools.message}", flush=True, file=sys.stderr)
                _record_error(errors, "friday", tools.message)
            if ffmpeg_available and not static_only and clips:
                try:
                    scored = score_clips(clips)
                    plan = select_reel_clips(scored)
                    music_path = resolve_reel_audio(
                        day_info.get("audio"), shoot_type=shoot_type, pieces=pieces
                    )
                    duck_gain_db = float(day_info.get("clip_duck_db", DEFAULT_DUCK_GAIN_DB))
                    mute_clip_audio = bool(day_info.get("clip_audio_muted", False))

                    reel_path = str(day_dir / "reel_clip.mp4")
                    render_clip_reel(
                        plan["selections"], reel_path,
                        audio_path=music_path,
                        duck_gain_db=duck_gain_db,
                        mute_clip_audio=mute_clip_audio,
                    )

                    # Title card overlay (plan #148, Phase 3): on by default,
                    # skippable per event via title_card_muted. A finishing
                    # touch, not the product itself, so a failure here must
                    # never cost the reel Stage 1/2/3 already built.
                    if not bool(day_info.get("title_card_muted", False)):
                        titled_path = str(day_dir / "reel_clip_titled.mp4.tmp")
                        try:
                            apply_title_card(reel_path, event, titled_path)
                            Path(titled_path).replace(reel_path)
                        except TitleCardError as e:
                            print(f"[generate_media] friday: title card skipped: {e}", flush=True)
                        finally:
                            Path(titled_path).unlink(missing_ok=True)

                    day_result["reel"] = reel_path
                    # Translated to Swift's FridayClipPlan field names
                    # (transition_after -> transition) so PythonBridge.swift
                    # can decode this straight into event.days["friday"].fridayClipPlan.
                    day_result["friday_clip_plan"] = {
                        "selections": [
                            {
                                "clip_path": sel["clip_path"],
                                "trim_in": sel["trim_in"],
                                "trim_out": sel["trim_out"],
                                "transition": sel["transition_after"],
                                # Plan #148 Phase 2: apply_selection always
                                # returns these (0/0/"low" when the crop gate
                                # denied or Claude proposed none), and they
                                # must survive to Swift's FridayClipSelection
                                # or the per-shot crop feature never surfaces.
                                "crop_x": sel["crop_x"],
                                "crop_y": sel["crop_y"],
                                "crop_confidence": sel["crop_confidence"],
                            }
                            for sel in plan["selections"]
                        ],
                        "rationale": plan.get("rationale", ""),
                    }
                    print(
                        f"[generate_media] friday: clip reel "
                        f"({len(plan['selections'])} clips) → {reel_path}", flush=True,
                    )
                    reel_rendered = True
                except InsufficientClipsError as e:
                    # Distinguishable prefix (not a human-facing message the
                    # UI would have to string-match against): the "< 3
                    # usable clips" case gets two specific escape-hatch
                    # buttons the UI can't infer from generic error text.
                    msg = f"insufficient_clips: {e}"
                    print(f"[generate_media] friday: {msg}", flush=True, file=sys.stderr)
                    _record_error(errors, "friday", msg)
                except Exception as e:
                    msg = f"clip reel skipped: {e}"
                    print(f"[generate_media] friday: {msg}", flush=True, file=sys.stderr)
                    _record_error(errors, "friday", msg)

            if reel_rendered:
                with tempfile.TemporaryDirectory(prefix="postroll-coverframes-") as cover_tmp:
                    _render_cover(
                        day_name="friday",
                        day_dir=day_dir,
                        day_info=day_info,
                        # Called synchronously inside _render_cover, so the
                        # loop variable cannot change under it (B023).
                        build_candidates=lambda: _cover_candidates_from_friday_plan(
                            plan["selections"], Path(cover_tmp)  # noqa: B023
                        ),
                        event=event, org=org, venue=venue,
                        day_result=day_result, errors=errors,
                        persist_pick_to=day_dir / "cover_frame.jpg",
                    )

            if not reel_rendered and raw and edit and not missing_inputs:
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
                    _record_error(errors, "friday", msg)
            elif not reel_rendered and not missing_inputs:
                # Fallback: story template. Only when the inputs were never
                # chosen, never as a substitute for one that has gone missing.
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
                        msg = f"story fallback failed: {e}"
                        _record_error(errors, "friday", msg)

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
