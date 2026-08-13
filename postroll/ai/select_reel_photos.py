"""
PostRoll — Representative Photo Selector

When a posting day has 50+ photos (typical of a full-show Thursday scroll
reel), this module asks Claude to pick the best representative subset.
"Best" means: visual variety across the show arc, strong individual
frames, and coverage of different moments/scenes rather than clusters of
near-identical shots.

The result is a filtered list of photo paths that is then passed into
generate_caption (which treats them as a scroll_reel and generates an
event-level caption from them).

Usage:
    from postroll.ai.select_reel_photos import select_reel_photos

    # Returns a list of Path objects (subset of photo_paths, in a good order)
    selected = select_reel_photos(photo_paths, count=20)

CLI:
    python -m postroll.ai.select_reel_photos \\
        --photos /path/to/photo1.jpg /path/to/photo2.jpg ... \\
        --count 20 \\
        --output selected.json
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path

import re

from .claude_client import run_json_prompt, ClaudeError
from .ocr_batching import batch_images
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg

# Default reel size for large shoots
DEFAULT_MAX_REEL_PHOTOS = 20

#: Ceiling for one selection request's images, in base64 bytes. The same
#: headroom the OCR path uses against the API's 32 MB refusal (#216).
MAX_REQUEST_BYTES = 25_000_000

#: Ceiling for one request's image COUNT. This is the limit a photo set hits
#: first: reel photos are individually small, so a full show clears the byte
#: budget comfortably and is still far too many images to attach to one call.
#: Measuring only bytes is how this module came to be refused on exactly the
#: large days it exists for (#470).
MAX_REQUEST_IMAGES = 100

SELECTION_PROMPT = """\
You are selecting representative photos for a photography portfolio reel.
Dan Wright is a concert and theatrical photographer. He has shot this event
and has {total} photos from the session. You need to pick the best {count}
to include in a scroll reel — a short video that shows highlights from the
night.

Selection criteria (apply in order of importance):
1. **Coverage** — the {count} selected photos should cover the full arc of the
   show: early scenes, middle moments, climactic scenes, and closing scenes.
   Avoid selecting 10 near-identical shots from one section.
2. **Visual variety** — mix of wide/intimate shots, different lighting moods,
   different groupings (soloists, full chorus, conductors, ensemble).
3. **Frame quality** — prefer sharp focus, good exposure, compelling
   composition over technically weak shots.
4. **Representativeness** — if the show has multiple distinct sections/scenes,
   try to include at least one strong photo from each.

{slice_note}The photos are listed below in the order Dan shot them (roughly chronological
through the event). Read each photo, evaluate it, then select {count} that
best satisfy the criteria above.

Photos ({total} total):
{photo_list}

Return JSON ONLY — no markdown fences, no commentary:

{{
  "selected_indices": [3, 7, 12, ...],
  "rationale": "one short sentence summarising the selection strategy"
}}

`selected_indices` must be a list of exactly {count} integers, each being
a 0-based index into the photo list above. Order them roughly chronologically
(i.e. preserve the rough narrative arc — don't scramble the order).
"""


#: How the slice note names which stretch a split call is looking at, and the
#: pattern that reads the asked-for count back out of a finished prompt. One
#: definition, so a reworded prompt cannot drift from what parses it.
_SLICE_NOTE = (
    "IMPORTANT: these are NOT all of the photos from the evening. They are "
    "stretch {index} of {total_batches}, one continuous chronological stretch "
    "of the night. Other stretches are being chosen from separately, so do NOT "
    "try to cover the whole show from what you can see here. Cover THIS "
    "stretch: pick the {count} frames that best represent it, with the variety "
    "and quality criteria above applied within it.\n\n"
)

_COUNT_ASKED = re.compile(r"to include in a scroll reel", re.IGNORECASE)


def _count_asked_for(prompt: str) -> int:
    """How many photos a finished prompt asks for.

    Read back out of the prompt rather than tracked beside it: the number the
    model was actually given is the one the response has to be judged against,
    and a second copy of it is free to disagree.
    """
    match = re.search(r"pick the best (\d+)\s*\n?to include in a scroll reel",
                      prompt)
    if not match:
        match = re.search(r"pick the best (\d+)", prompt)
    return int(match.group(1)) if match else 0


def _shares(batches: list[list[str]], count: int) -> list[int]:
    """How many photos to take from each stretch, summing to exactly `count`.

    Proportional to the length of each stretch, so a busy hour contributes more
    frames than a quiet one and the evening is covered evenly in TIME. An even
    split across batches would over-sample whichever stretch happened to be
    shortest, which on a trailing part-full batch is the end of the night.

    The remainder goes to the longest stretches rather than being dropped: the
    shares have to sum to `count` exactly, or the reel comes back short.
    """
    total = sum(len(b) for b in batches)
    if not total:
        return [0] * len(batches)

    exact = [len(b) * count / total for b in batches]
    shares = [int(e) for e in exact]

    # Hand out what rounding left over, largest fractional part first, and
    # never more than a stretch actually holds.
    remainder = count - sum(shares)
    order = sorted(range(len(batches)), key=lambda i: exact[i] - shares[i],
                   reverse=True)
    while remainder > 0:
        progressed = False
        for i in order:
            if remainder == 0:
                break
            if shares[i] < len(batches[i]):
                shares[i] += 1
                remainder -= 1
                progressed = True
        if not progressed:
            break
    return shares


def select_reel_photos(
    photo_paths: list[str | Path],
    count: int = DEFAULT_MAX_REEL_PHOTOS,
) -> list[Path]:
    """Pick the best `count` representative photos from a large set.

    Returns a list of `count` Path objects (absolute paths) from
    photo_paths, ordered to preserve the narrative arc of the event.

    If photo_paths has fewer than or equal to `count` items, it is
    returned as-is (no Claude call needed).
    """
    resolved = [Path(p).expanduser().resolve() for p in photo_paths]
    if len(resolved) <= count:
        return resolved

    with tempfile.TemporaryDirectory(prefix="postroll-select-") as tmp:
        tmp_path = Path(tmp)

        # Stage photos (handle HEIC conversion)
        staged: list[Path] = []
        for i, photo in enumerate(resolved):
            if not photo.exists():
                raise FileNotFoundError(f"Photo not found: {photo}")
            if photo.suffix.lower() in HEIC_SUFFIXES:
                s = _convert_heic_to_jpeg(photo, tmp_path, prefix=f"{i:04d}_")
            else:
                s = tmp_path / f"{i:04d}_{photo.name}"
                shutil.copy2(photo, s)
            staged.append(s)

        # Split into requests that fit BOTH ceilings (#470). The batches are
        # contiguous chronological stretches, so covering the whole evening
        # survives the split: each call covers its own stretch, and the
        # stretches laid end to end are the night.
        batches = batch_images(staged, limit_bytes=MAX_REQUEST_BYTES,
                               max_images=MAX_REQUEST_IMAGES)
        shares = _shares(batches, count)
        if len(batches) > 1:
            print(f"[select_reel_photos] {len(staged)} photos exceed one "
                  f"request; choosing {shares} across {len(batches)} "
                  "chronological stretches", flush=True, file=sys.stderr)

        offset = 0
        picked: set[int] = set()
        for position, (batch, share) in enumerate(zip(batches, shares), start=1):
            batch_paths = [Path(b) for b in batch]
            if share <= 0:
                offset += len(batch_paths)
                continue

            # Labels are per batch, so an index in the answer is an index into
            # THIS call's list. `offset` puts it back on the whole evening.
            labels = [f"[{i}] {p.name}" for i, p in enumerate(batch_paths)]
            slice_note = "" if len(batches) == 1 else _SLICE_NOTE.format(
                index=position, total_batches=len(batches), count=share)
            prompt = SELECTION_PROMPT.format(
                total=len(batch_paths),
                count=share,
                photo_list="\n".join(f"- {label}" for label in labels),
                slice_note=slice_note,
            )

            data = run_json_prompt(
                prompt,
                timeout=600,
                image_paths=batch_paths,
                image_labels=labels,
                step="select_reel_photos",
            )

            picked.update(
                offset + i for i in _valid_indices(data, len(batch_paths)))
            offset += len(batch_paths)

    if not picked:
        raise ClaudeError("Claude returned no valid photo indices")

    # Chronological, because the reel is cut in this order.
    selected = [resolved[i] for i in sorted(picked)]

    # If we got fewer than requested (dedup / validation losses), pad with
    # evenly-spaced photos not already selected
    if len(selected) < count:
        step = max(1, len(resolved) // (count - len(selected) + 1))
        for i in range(0, len(resolved), step):
            if i not in picked and len(selected) < count:
                picked.add(i)
        selected = [resolved[i] for i in sorted(picked)]

    return selected[:count]


def _valid_indices(data: object, batch_size: int) -> list[int]:
    """The usable 0-based indices in one batch's answer.

    Raises rather than returning nothing on a malformed answer: a batch that
    answered with the wrong shape is a batch that was paid for and produced
    nothing, and swallowing it here would silently shrink the reel's coverage
    of that stretch of the evening.
    """
    if not isinstance(data, dict) or "selected_indices" not in data:
        raise ClaudeError(
            f"Expected JSON with 'selected_indices', got: {str(data)[:200]}"
        )
    indices = data["selected_indices"]
    if not isinstance(indices, list):
        raise ClaudeError(
            f"'selected_indices' must be a list, got {type(indices).__name__}"
        )

    seen: set[int] = set()
    out: list[int] = []
    for idx in indices:
        if not isinstance(idx, int) or idx < 0 or idx >= batch_size:
            continue
        if idx in seen:
            continue
        seen.add(idx)
        out.append(idx)
    return out


# ===================================================================
# CLI
# ===================================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Select representative reel photos from a large shoot"
    )
    parser.add_argument(
        "--photos",
        nargs="+",
        required=True,
        type=Path,
        help="Photo paths to select from",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=DEFAULT_MAX_REEL_PHOTOS,
        help=f"Number of photos to select (default: {DEFAULT_MAX_REEL_PHOTOS})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Write selected paths as JSON array to this file (default: stdout)",
    )
    args = parser.parse_args()

    try:
        selected = select_reel_photos(args.photos, count=args.count)
    except (ClaudeError, FileNotFoundError) as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    result = json.dumps([str(p) for p in selected], indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(result + "\n", encoding="utf-8")
        print(f"wrote {args.output}")
    else:
        print(result)
