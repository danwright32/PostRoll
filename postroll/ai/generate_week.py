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
  "errors": {},            ← keyed by day name if any individual day failed
  "warnings": {}           ← keyed by day name; the day still generated, but
                              something about it needs saying (an unreadable
                              photo skipped, #228)
}

Usage:
    python -m postroll.ai.generate_week \\
        --manifest /path/to/manifest.json \\
        --output   /path/to/output.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack
from pathlib import Path
from typing import Any

from . import cap_signals
from .generate_captions import generate_caption
from .blog_repair import deadline_from
from .generate_blog import generate_blog
from .progress import ProgressWriter
from .select_reel_photos import select_reel_photos, DEFAULT_MAX_REEL_PHOTOS
from ..posting_preset import DEFAULT_PRESET, post_type


DAY_ORDER = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"]

# When a scroll_reel day has this many photos, ask Claude to pick the best subset
REEL_SELECTION_THRESHOLD = 50


def _extract_clip_plan_frames(
    selections: list[dict[str, Any]], *, tmp_dir: str | Path
) -> list[str]:
    """Re-extract one mid-point frame per selection in a persisted Friday
    clip plan, for the caption call's `photo_paths`.

    Deliberately does NOT reuse Stage 2's own representative frames: those
    live in a TemporaryDirectory that's already deleted by the time this
    runs, and media generation (which produces the plan) runs concurrently
    with, not strictly before, this caption pass. Self-contained: reads
    only the clip paths and trim windows already persisted in the manifest.

    A selection whose clip file no longer exists is skipped rather than
    failing the whole caption; raises only if NO frame could be extracted
    at all (nothing usable to caption).

    `tmp_dir` is required, and deliberately has no default. It used to fall
    back to a mkdtemp, which meant this function invented a directory whose
    lifetime nobody owned: the caller is the only thing that knows when the
    frames stop being needed, so the caller creates it and the caller closes
    it (#486, L8).
    """
    tmp = Path(tmp_dir)
    tmp.mkdir(parents=True, exist_ok=True)

    frames: list[str] = []
    for i, sel in enumerate(selections):
        clip_path = sel.get("clip_path")
        if not clip_path or not Path(clip_path).exists():
            continue
        trim_in = float(sel.get("trim_in", 0.0))
        trim_out = float(sel.get("trim_out", trim_in))
        midpoint = (trim_in + trim_out) / 2

        out = tmp / f"frame_{i:02d}.png"
        proc = subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-ss", str(midpoint), "-i", str(clip_path),
             "-frames:v", "1", str(out)],
            capture_output=True,
        )
        if proc.returncode == 0 and out.exists():
            frames.append(str(out))

    if not frames:
        raise RuntimeError("no frames could be extracted from the Friday clip plan")
    return frames


class FatalGenerationError(RuntimeError):
    """A condition that makes continuing the run pointless or harmful.

    The motivating case is a usage cap: once it is hit, every remaining day
    would fail the same way, so carrying on wastes time hammering a wall and
    buries the real reason under a pile of per-day errors. Dan's requirement is
    that such a run STOPS and asks him rather than spending anything further.

    Deliberately NOT a subclass of ClaudeError, and deliberately re-raised by
    the per-day handler, because that handler's whole job is to let one bad day
    pass. Anything that must stop the week has to be visibly exempt from it
    (#206).
    """


def _write_results(output_path: Path, results: dict, *, complete: bool,
                   stopped_reason: str | None = None) -> None:
    """Persist what has been generated so far, atomically.

    Called after every day rather than once at the end. A run can be stopped by
    something that is not an exception at all: the app's own watchdog SIGTERMs
    the subprocess at 1800s, and before this the whole week's captions, already
    generated and already paid for, went with it (#206, L5).

    Written to a temp file and moved into place so a kill mid-write cannot
    leave a truncated file where a good one used to be.
    """
    payload = dict(results)
    payload["complete"] = complete
    payload["stopped_reason"] = stopped_reason
    # Carried on the result so the app can show it, not only stderr (#217). A
    # file nothing reads is how the one cheap chance to capture a real cap's
    # wording gets missed.
    payload["unrecognised_failures"] = cap_signals.unrecognised()
    tmp = output_path.with_suffix(output_path.suffix + ".part")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(output_path)


def _auto_post_type(day: str, photo_count: int, preset: str = DEFAULT_PRESET) -> str:
    """Pick a sensible post_type when the manifest doesn't specify one.

    Sunday/Monday/Wednesday are governed by the posting preset: a
    collage_carousel day is a "carousel" (so the caption pipeline emits one alt
    text per photo), a single day is a "feed_photo".

    Delegates rather than restating the rule (#1010). The app has to answer the
    same question to decide whether a layout switch needs a caption rebuild, and
    a second copy of this would drift in whichever direction flattered the side
    a test happened to read.
    """
    return post_type(preset, day, photo_count)


def generate_week(manifest: dict[str, Any], output_path: Path,
                  timing_path: Path | None = None,
                  progress_path: Path | None = None) -> None:
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
    preset        = manifest.get("preset", DEFAULT_PRESET)

    # Every AI call this run makes records against this event, so "what did
    # this week cost" has an answer (#207). One process handles one event, so
    # the label is set once here rather than threaded through every call site.
    os.environ["POSTROLL_EVENT"] = f"{event} {date}".strip()

    # Says which day is being written as it starts. Between days this process
    # is silent for minutes at a time, so without it the app cannot tell a run
    # that is working from one that has died (#95, #96).
    say = ProgressWriter(progress_path)
    step_total = len(DAY_ORDER) + 1  # every day, plus the blog

    results: dict[str, Any] = {}
    errors:  dict[str, str] = {}
    # Separate from `errors` on purpose: a warning means the day GENERATED and
    # is usable, and filing it as an error would either hide a real failure or
    # make a good day look broken (L53: two checks must not share one field).
    warnings: dict[str, list[dict[str, str]]] = {}
    existing_captions: list[str] = []

    t_start = time.time()
    t_captions_start: float | None = None
    t_captions_end: float | None = None
    t_blog_start: float | None = None
    t_blog_end: float | None = None

    # One scratch directory for the whole caption pass, closed on the way
    # out however the pass ends. Friday's frames used to go into a mkdtemp
    # that nothing removed, so the temp volume grew with how often the
    # workflow ran rather than with the work done (#486, L114).
    with ExitStack() as scratch:
        for day_name in DAY_ORDER:
            say.step(f"Writing the {day_name.capitalize()} caption",
                     index=DAY_ORDER.index(day_name) + 1, total=step_total)
            if day_name == "friday":
                day_info = days_data.get("friday", {})
                selections = ((day_info.get("clips_plan") or {}).get("selections")) or []
                if not selections:
                    results[day_name] = None
                    print("[generate_week] friday: no clip plan, skipping caption", flush=True)
                    continue
                try:
                    frames_dir = scratch.enter_context(
                        tempfile.TemporaryDirectory(prefix="postroll-fridaycaptionframes-"))
                    photos = _extract_clip_plan_frames(selections, tmp_dir=frames_dir)
                except Exception as e:
                    print(f"[generate_week] friday: frame extraction failed ({e}), skipping caption",
                          flush=True, file=sys.stderr)
                    errors[day_name] = f"frame extraction failed: {e}"
                    results[day_name] = None
                    continue

                post_type     = "clip_reel"
                tag_handles   = day_info.get("tag_handles") or None
                name_mentions = day_info.get("name_mentions") or None
                notes         = day_info.get("notes", "")
                photo_tags    = None  # per-photo tagging isn't meaningful for a reconstructed reel frame set

            else:
                day_info = days_data.get(day_name, {})
                photos   = day_info.get("photos", [])

                if not photos:
                    results[day_name] = None
                    print(f"[generate_week] {day_name}: no photos, skipping", flush=True)
                    continue

                post_type    = day_info.get("post_type") or _auto_post_type(day_name, len(photos), preset)
                tag_handles  = day_info.get("tag_handles") or None
                name_mentions = day_info.get("name_mentions") or None
                notes        = day_info.get("notes", "")
                photo_tags   = day_info.get("photo_tags") or None

            # For Thursday's scroll reel: the reel itself can have 50-200+ photos
            # (the visual asset is generated locally by ffmpeg), but Claude only
            # needs a representative sample to write the caption. Wednesday's
            # collage photos are already a curated sample of the event (4 or 10
            # depending on the posting preset), so reuse them as Claude's
            # context: same event, same shoot, no extra selection step, never
            # blows past Claude's request size limit.
            # What the POST holds, taken before any sampling below replaces
            # `photos` with a handful of them. Passed to the caption prompt so
            # it is asked about the reel it is actually writing for (#1067).
            post_photo_count = len(photos)
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
                    # Fallback: no Wednesday photos available, so fall back to
                    # the old representative-selection path.
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
                    post_photo_count=post_photo_count,
                )
                results[day_name] = result
                if result.get("skipped_photos"):
                    warnings[day_name] = result["skipped_photos"]
                    for s_ in result["skipped_photos"]:
                        print(f"[generate_week] {day_name}: skipped {s_['file']} "
                              f"(could not be read); the day generated from the rest",
                              flush=True, file=sys.stderr)
                if result.get("caption"):
                    existing_captions.append(result["caption"])
                t_captions_end = time.time()
                print(f"[generate_week] {day_name}: done", flush=True)
            except FatalGenerationError as e:
                # Never swallowed. Everything finished so far is already on disk
                # from the write below; record why the run stopped and re-raise so
                # the caller can ask Dan what to do (#206).
                t_captions_end = time.time()
                print(f"[generate_week] {day_name}: STOPPING: {e}", flush=True, file=sys.stderr)
                results["errors"] = errors
                results["warnings"] = warnings
                _write_results(output_path, results, complete=False, stopped_reason=str(e))
                raise
            except Exception as e:
                t_captions_end = time.time()
                # A usage cap makes every remaining day fail the same way, so it is
                # promoted out of this handler rather than filed as one bad day and
                # hammered five more times (#211). Only a RECOGNISED cap: an
                # unfamiliar error stays ordinary, because halting on anything we
                # do not understand turns every new error string into a cancelled
                # evening.
                signal = cap_signals.classify(str(e))
                if cap_signals.should_halt(signal):
                    reason = "Claude usage limit reached"
                    if signal.resets_at:
                        reason += f", resets at {signal.resets_at}"
                    reason += ". Everything generated so far is saved."
                    # Persisted HERE rather than relying on the FatalGenerationError
                    # clause above: that clause is a sibling of this one, so an
                    # exception raised inside this handler is not caught by it and
                    # the partial week would be lost on the way out (#206, #211).
                    print(f"[generate_week] {day_name}: STOPPING: {reason}",
                          flush=True, file=sys.stderr)
                    results["errors"] = errors
                    results["warnings"] = warnings
                    _write_results(output_path, results, complete=False,
                                   stopped_reason=reason)
                    raise FatalGenerationError(reason) from e
                print(f"[generate_week] {day_name}: ERROR: {e}", flush=True, file=sys.stderr)
                errors[day_name] = str(e)
                results[day_name] = None

            # Persist after every day, so a kill at any point keeps what finished.
            results["errors"] = errors
            results["warnings"] = warnings
            _write_results(output_path, results, complete=False)

    # Blog post
    if blog_photos:
        t_blog_start = time.time()
        say.step("Writing the blog post", index=step_total, total=step_total)
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
                progress=say,
                # The blog is the LAST step, after seven days of captions have
                # already spent most of the 1,800 second process ceiling, so
                # the repair pass gets what is left of it and not a constant
                # (#1133, L227, L522). t_start is this process's own start.
                repair_deadline=deadline_from(started_at=t_start,
                                              now=time.time),
            )
            results["blog"] = blog_result
            t_blog_end = time.time()
            print("[generate_week] blog: done", flush=True)
        except FatalGenerationError as e:
            t_blog_end = time.time()
            print(f"[generate_week] blog: STOPPING: {e}", flush=True, file=sys.stderr)
            results["errors"] = errors
            results["warnings"] = warnings
            _write_results(output_path, results, complete=False, stopped_reason=str(e))
            raise
        except Exception as e:
            t_blog_end = time.time()
            print(f"[generate_week] blog: ERROR: {e}", flush=True, file=sys.stderr)
            errors["blog"] = str(e)
            results["blog"] = None
    else:
        results["blog"] = None

    t_total = time.time()
    results["errors"] = errors
    results["warnings"] = warnings

    _write_results(output_path, results, complete=True)
    say.finish()

    # Said on the way out, every run, while the file has anything in it (#217).
    if (report := cap_signals.report_unrecognised()):
        print(f"[generate_week] {report}", file=sys.stderr, flush=True)
    # And every run regardless, while the cap guard is still a hypothesis. The
    # report above speaks only once a failure has been recorded, so before any
    # cap is ever hit the dormant state is silent. This used to be tracked by an
    # open issue whose only job was to stay open (#258); the state reports
    # itself now.
    if (notice := cap_signals.calibration_notice()):
        print(f"[generate_week] {notice}", file=sys.stderr, flush=True)
    print(f"[generate_week] output written to {output_path}", flush=True)

    # Write per-phase timing data for the Swift layer to consume
    if timing_path is not None:
        elapsed = t_total - t_start
        captions = (t_captions_end - t_captions_start) if (t_captions_start and t_captions_end) else None
        blog     = (t_blog_end - t_blog_start)         if (t_blog_start and t_blog_end)         else None
        packaging = elapsed - (captions or 0) - (blog or 0) - (t_captions_start - t_start if t_captions_start else 0)
        # No "total". It was reported and read by nothing, because the app runs
        # its own stopwatch over the same span (the only difference being the
        # few seconds spent launching this process). Two measurements of one
        # thing is how two numbers that must agree start disagreeing, so the
        # duplicate goes rather than gaining a reader (#262, L53). `elapsed` is
        # still what `packaging` is derived from below.
        timing = {
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
    parser.add_argument("--progress", default=None,
                        help="Optional path to write the current step, so a caller "
                             "can tell a working run from a hung one (#95, #96)")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
    generate_week(manifest_data, Path(args.output),
                  Path(args.timing) if args.timing else None,
                  Path(args.progress) if args.progress else None)
