"""
PostRoll: Instagram grid cover image Stage, one Claude call to pick which
candidate photo or extracted video frame becomes cover.png (Thursday's
scroll reel and Friday's auto-cut clip reel; Tuesday and Wednesday already
get a cover for free from their existing before/after/collage assets).

Mirrors select_reel_clips.py's labeled-candidate pattern (inline
image_labels, not a bare list; feedback_image_filename_correlation
previously caused index/filename correlation bugs when this discipline was
skipped) and its server-side validation of Claude's raw pick.

Unlike select_reel_clips's Stage 2 (where a bad plan simply falls through to
Friday's full before/after fallback), a Thursday or Friday reel with no
cover at all is a real UX gap. So when Claude's response is unusable, this
module falls back to a deterministic first-candidate pick instead of
raising, loudly logged rather than silently pretending it was an AI choice.

Usage:
    from postroll.ai.select_cover_photo import select_cover_photo

    pick = select_cover_photo(candidates)  # candidates: [{"path": ...}, ...]
    # pick == {"index": 0, "path": "...", "rationale": "..."}
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path

from .claude_client import ClaudeError, run_json_prompt
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg
from .select_reel_clips import _extract_representative_frames

# 1-2 frames per selected clip so Claude can pick a still-worthy moment
# without re-sending every frame Stage 2 already saw; only the clips that
# made the final cut are candidates, so this stays small regardless of how
# many clips were imported.
COVER_FRAMES_PER_CLIP = 2

SELECTION_PROMPT = """\
You are picking a single cover image for a photography studio's Instagram
profile grid. You have {count} candidate images, either photos or extracted
video frames from a live event.

Pick the ONE image that works best as a stand-alone cover thumbnail
representing this event: strong, in-focus, and visually striking at small
size, without needing context to read well (a clean soloist or wide shot
usually beats a busy group shot or a mid-motion blur).

Candidates ({count} total), labeled to match the images above:
{candidate_list}

Return JSON ONLY, no markdown fences, no commentary:

{{
  "index": 4,
  "rationale": "one short sentence explaining the pick"
}}

`index` is a 0-based index into the candidate list above.
"""


def _format_candidate_list(labels: list[str]) -> str:
    return "\n".join(f"- {label}" for label in labels)


def apply_cover_pick(data: object, candidates: list[dict]) -> dict:
    """Pure: validate Claude's raw JSON response against `candidates` (in the
    same order the prompt listed them). Never trusts a non-integer or
    out-of-range index.
    """
    if not isinstance(data, dict) or "index" not in data:
        raise ClaudeError(f"Expected JSON with 'index', got: {str(data)[:200]}")

    idx = data.get("index")
    if not isinstance(idx, int) or idx < 0 or idx >= len(candidates):
        raise ClaudeError(f"'index' {idx!r} is out of range for {len(candidates)} candidates")

    rationale = data.get("rationale")
    if not isinstance(rationale, str):
        rationale = ""

    return {"index": idx, "path": candidates[idx]["path"], "rationale": rationale}


def _cover_candidates_from_friday_plan(selections: list[dict], tmp_dir: Path) -> list[dict]:
    """Friday's cover candidates: frames extracted from a clip-reel plan
    (a freshly cut one, or one re-extracted from an already-persisted
    clips_plan, the caller decides which; this only needs each
    selection's clip_path/trim_in/trim_out), mirroring select_reel_clips.py's
    own frame-extraction pattern."""
    candidates: list[dict] = []
    for i, sel in enumerate(selections):
        frames = _extract_representative_frames(
            sel["clip_path"], (sel["trim_in"], sel["trim_out"]),
            COVER_FRAMES_PER_CLIP, tmp_dir, prefix=f"cover{i:02d}_",
        )
        candidates.extend({"path": str(f)} for f in frames)
    return candidates


def _fallback_pick(candidates: list[dict], reason: str) -> dict:
    print(
        f"warning: cover selection failed ({reason}); falling back to first candidate",
        file=sys.stderr, flush=True,
    )
    return {
        "index": 0,
        "path": candidates[0]["path"],
        "rationale": "Automatic selection was unavailable; the first candidate was used instead.",
    }


def _without(candidates: list[dict], exclude_paths) -> list[dict]:
    """Candidates minus anything already showing elsewhere in the week (#144).

    Normalised before comparing, because the used-elsewhere set and the
    candidate list are assembled from different parts of the manifest and one
    may carry a redundant `./` or a symlinked prefix.
    """
    if not exclude_paths:
        return candidates
    used = {os.path.realpath(os.path.normpath(str(p))) for p in exclude_paths}
    return [
        c for c in candidates
        if os.path.realpath(os.path.normpath(str(c["path"]))) not in used
    ]


def select_cover_photo(
    candidates: list[dict],
    *,
    timeout: int = 300,
    tmp_dir: str | Path | None = None,
    exclude_paths: list[str] | tuple[str, ...] | None = None,
) -> dict:
    """Top-level entry: candidate photos/frames -> Claude's cover pick.

    `exclude_paths` are photos already showing elsewhere in the week's grid, so
    each day's cover reads as its own picture rather than a repeat (#144). They
    are removed from the list before Claude sees it rather than described to it
    in the prompt, because this rule is checkable in code and a rule that lives
    only in a prompt is a hope (L27).

    Never raises once at least one candidate is given: an unusable response
    or a Claude API failure falls back to a deterministic first-candidate
    pick rather than leaving the day with no cover at all.
    """
    if not candidates:
        raise ClaudeError("no candidate images for cover selection")

    remaining = _without(candidates, exclude_paths)
    if not remaining:
        # Every candidate is already used somewhere. A repeated cover is a much
        # smaller problem than a day with no cover, so the day takes its pick
        # from the full list. Said out loud because this ships a known defect
        # rather than avoiding one, and a fallback nobody can see firing is how
        # the rare case quietly becomes the common one (L93).
        print(
            "[select_cover_photo] every candidate is already used elsewhere in "
            "the week, so this cover will repeat one of them",
            file=sys.stderr, flush=True,
        )
        remaining = candidates
    candidates = remaining

    if len(candidates) == 1:
        return {"index": 0, "path": candidates[0]["path"], "rationale": "Only one candidate available."}

    def _run(tmp: str) -> dict:
        tmp_path = Path(tmp)
        staged: list[Path] = []
        for i, c in enumerate(candidates):
            src = Path(c["path"])
            if src.suffix.lower() in HEIC_SUFFIXES:
                staged.append(_convert_heic_to_jpeg(src, tmp_path, prefix=f"{i:03d}_"))
            else:
                dest = tmp_path / f"{i:03d}_{src.name}"
                shutil.copy2(src, dest)
                staged.append(dest)

        labels = [f"[{i}] {Path(c['path']).name}" for i, c in enumerate(candidates)]
        prompt = SELECTION_PROMPT.format(
            count=len(candidates),
            candidate_list=_format_candidate_list(labels),
        )

        data = run_json_prompt(prompt, timeout=timeout, image_paths=staged, image_labels=labels, step="select_cover_photo")
        return apply_cover_pick(data, candidates)

    try:
        if tmp_dir is not None:
            Path(tmp_dir).mkdir(parents=True, exist_ok=True)
            return _run(str(tmp_dir))
        with tempfile.TemporaryDirectory(prefix="postroll-selectcover-") as tmp:
            return _run(tmp)
    except ClaudeError as e:
        return _fallback_pick(candidates, str(e))
