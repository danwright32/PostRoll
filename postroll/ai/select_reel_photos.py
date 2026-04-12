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

from .claude_client import run_json_prompt, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg

# Default reel size for large shoots
DEFAULT_MAX_REEL_PHOTOS = 20

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

The photos are listed below in the order Dan shot them (roughly chronological
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
                s = _convert_heic_to_jpeg(photo, tmp_path)
            else:
                s = tmp_path / f"{i:04d}_{photo.name}"
                shutil.copy2(photo, s)
            staged.append(s)

        photo_list = "\n".join(f"- [{i}] {p}" for i, p in enumerate(staged))

        prompt = SELECTION_PROMPT.format(
            total=len(staged),
            count=count,
            photo_list=photo_list,
        )

        data = run_json_prompt(
            prompt,
            timeout=600,
            allowed_dirs=[tmp_path],
            allowed_tools=["Read"],
        )

    if not isinstance(data, dict) or "selected_indices" not in data:
        raise ClaudeError(
            f"Expected JSON with 'selected_indices', got: {str(data)[:200]}"
        )

    indices = data["selected_indices"]
    if not isinstance(indices, list):
        raise ClaudeError(
            f"'selected_indices' must be a list, got {type(indices).__name__}"
        )

    # Validate and deduplicate, preserving order
    seen: set[int] = set()
    selected: list[Path] = []
    for idx in indices:
        if not isinstance(idx, int) or idx < 0 or idx >= len(resolved):
            continue
        if idx in seen:
            continue
        seen.add(idx)
        selected.append(resolved[idx])

    if not selected:
        raise ClaudeError("Claude returned no valid photo indices")

    # If we got fewer than requested (dedup / validation losses), pad with
    # evenly-spaced photos not already selected
    if len(selected) < count:
        step = max(1, len(resolved) // (count - len(selected) + 1))
        for i in range(0, len(resolved), step):
            if i not in seen and len(selected) < count:
                selected.append(resolved[i])
                seen.add(i)

    return selected[:count]


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
