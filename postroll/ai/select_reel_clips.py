"""
PostRoll: Friday clip reel Stage 2, one Claude call to select, order, and
trim clips.

Mirrors select_reel_photos.py's run_json_prompt/image_labels pattern: the
same inline image_labels discipline (bare vision prompts previously caused
index/filename correlation bugs in this codebase, feedback_image_filename_correlation),
the same index validate-and-dedup logic, and the same ClaudeError fail-loud
behavior.

The one addition that pattern doesn't need: server-side clamping. Whatever
trim window Claude proposes is clamped in Python to Stage 1's own
valid_trim range before it is ever used, so a bad AI pick (a trim outside
the range Stage 1 already validated as usable) is structurally impossible,
not merely unlikely.

Usage:
    from postroll.ai.select_reel_clips import select_reel_clips

    scored = score_clips(clip_paths)  # Stage 1
    plan = select_reel_clips(scored)  # Stage 2
    # plan == {"selections": [{clip_path, trim_in, trim_out, transition_after}, ...],
    #          "rationale": "..."}
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from .claude_client import ClaudeError, run_json_prompt

# 2-3 frames per clip (start/mid/end) so Claude can judge motion, not just a
# single still.
FRAMES_PER_CLIP = 3

TARGET_DURATION_MIN = 20.0
TARGET_DURATION_MAX = 30.0

# Candidates are chosen by score until their combined valid_trim duration
# covers this budget, not a fixed clip count: a week with plenty of good,
# longer footage should offer Claude enough clips to comfortably hit the
# target with room to choose a subset/order, rather than an arbitrary count
# that ignores how much usable footage actually exists (2026-07-08, Dan's
# call, once the JPEG frame fix removed the payload-size reason a fixed
# cap of 8 originally existed for). 1.5x the max target gives real slack.
CANDIDATE_DURATION_BUDGET = TARGET_DURATION_MAX * 1.5
# Hard backstop so a week with dozens of usable clips can't balloon the
# image payload/API cost unbounded.
MAX_CANDIDATES_CEILING = 20

SELECTION_PROMPT = """\
You are cutting a highlight reel for a photography studio's Instagram from
short video clips shot at a live event. You have {count} candidate clips,
each already screened for quality (in focus, not incoherent footage) and
given a validated trim range (the part of the clip that's actually usable).

Pick which clips make the final cut, their order, a trim window for each
(within its valid range), and how each clip transitions to the next one.

Target total reel duration: {min_duration:.0f} to {max_duration:.0f} seconds.
This is a real requirement, not a suggestion: sum up trim_out - trim_in
across every selection before finalizing your answer, and keep adding
clips (or widening trim windows within their valid range) until the total
lands inside {min_duration:.0f}-{max_duration:.0f} seconds. A reel built
from only one or two clips will almost always fall short of this; prefer
using most or all of the {count} candidates over leaning on a couple of
long ones.

Selection guidance:
1. Order for a dramatic arc, not necessarily the order the clips were shot in.
   Open strong, build, and close on the most compelling moment.
2. Prefer clips with a higher score (stronger, more in-focus detail) when
   duration budget forces a choice between similar clips.
3. Choose "crossfade" only where a smooth blend fits the pacing between two
   clips; otherwise use "cut" for a punchier feel typical of a highlight reel.
4. A trim window must stay within the clip's own valid range below. Frames
   for each clip are labeled "[clip i, frame j]" so you can see roughly what
   happens across the clip before choosing where to trim.
5. Keep the cut varied: no single clip's trim window should make up more
   than roughly a third of the total reel duration. A highlight reel reads
   as one long clip with two short add-ons is a miss, not a good cut.

Candidate clips ({count} total):
{clip_list}

Return JSON ONLY, no markdown fences, no commentary:

{{
  "selections": [
    {{"clip_index": 2, "trim_in": 1.2, "trim_out": 4.8, "transition_after": "cut"}},
    ...
  ],
  "rationale": "one short sentence summarising the cut"
}}

`selections` is ordered (first entry plays first). `clip_index` is a 0-based
index into the candidate list above. `transition_after` describes how this
clip transitions to the next one in the list ("cut" or "crossfade"); the
value on the last selection is ignored.
"""


def _format_clip_list(candidates: list[dict]) -> str:
    lines = []
    for i, c in enumerate(candidates):
        valid_in, valid_out = c["valid_trim"]
        lines.append(
            f"- [{i}] duration={c['duration']:.1f}s score={c['score']:.1f} "
            f"valid_range=({valid_in:.1f}, {valid_out:.1f})"
        )
    return "\n".join(lines)


def _extract_representative_frames(
    path: str, valid_trim: tuple[float, float], count: int, out_dir: Path, prefix: str
) -> list[Path]:
    """Extract `count` frames spread across `valid_trim` (start/mid/end for
    count=3) via ffmpeg, so Claude can judge motion across the usable window
    rather than guessing from a single still."""
    start, end = valid_trim
    if count <= 1:
        times = [(start + end) / 2]
    else:
        step = (end - start) / (count - 1)
        times = [start + step * i for i in range(count)]

    frames: list[Path] = []
    for i, t in enumerate(times):
        # JPEG, not PNG: claude_client.py's _image_block only recompresses
        # smaller on downscale for JPEG-mimetype images, keeping PNG at full
        # quality (meant for OCR program pages with text to preserve, not
        # video frames). A 4K PNG frame stays ~1.7MB even after downscaling;
        # the same frame as JPEG is ~0.2MB. Sending a full candidate batch
        # of PNG frames hit a real 413 request_too_large once enough real
        # clips passed Stage 1 to fill the candidate budget (2026-07-08).
        out = out_dir / f"{prefix}{i}.jpg"
        proc = subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-ss", str(t), "-i", str(path),
             "-frames:v", "1", str(out)],
            capture_output=True,
        )
        if proc.returncode == 0 and out.exists():
            frames.append(out)
    return frames


def _as_float(value: object, default: float) -> float:
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(value, high))


# Slack before flagging a duration miss: a cut a second or two under the
# target isn't worth a warning, only a real shortfall is.
DURATION_SHORTFALL_TOLERANCE = 2.0


def _annotate_duration_shortfall(selections: list[dict], rationale: str) -> str:
    """Claude can undershoot its own stated target duration substantially
    while its rationale claims otherwise (real behavior seen 2026-07-08).
    A miss this large must be visible in the review UI, not silent, so
    it's appended to the rationale rather than swallowed."""
    total = sum(s["trim_out"] - s["trim_in"] for s in selections)
    if total < TARGET_DURATION_MIN - DURATION_SHORTFALL_TOLERANCE:
        note = (
            f"Note: this cut runs about {total:.1f}s, under the "
            f"{TARGET_DURATION_MIN:.0f} to {TARGET_DURATION_MAX:.0f}s target. "
            "Consider adding or lengthening clips with the override editor."
        )
        return f"{rationale} {note}".strip() if rationale else note
    return rationale


def apply_selection(data: object, candidates: list[dict]) -> dict:
    """Pure: validate Claude's raw JSON response against `candidates` (Stage
    1's scored clips, in the same order the prompt listed them) and clamp
    every trim window to its clip's own valid_trim range. Never trusts a
    trim window outside what Stage 1 already validated as usable.
    """
    if not isinstance(data, dict) or "selections" not in data:
        raise ClaudeError(f"Expected JSON with 'selections', got: {str(data)[:200]}")

    raw_selections = data["selections"]
    if not isinstance(raw_selections, list):
        raise ClaudeError(f"'selections' must be a list, got {type(raw_selections).__name__}")

    seen: set[int] = set()
    selections: list[dict] = []
    for item in raw_selections:
        if not isinstance(item, dict):
            continue
        idx = item.get("clip_index")
        if not isinstance(idx, int) or idx < 0 or idx >= len(candidates):
            continue
        if idx in seen:
            continue
        seen.add(idx)

        clip = candidates[idx]
        valid_in, valid_out = clip["valid_trim"]
        trim_in = _clamp(_as_float(item.get("trim_in"), valid_in), valid_in, valid_out)
        trim_out = _clamp(_as_float(item.get("trim_out"), valid_out), valid_in, valid_out)
        if trim_out <= trim_in:
            # An inverted or zero-width window is not a usable trim: fall
            # back to the clip's whole validated range rather than produce
            # a zero-length or backwards cut.
            trim_in, trim_out = valid_in, valid_out

        transition = item.get("transition_after")
        if transition not in ("cut", "crossfade"):
            transition = "cut"

        selections.append({
            "clip_path": clip["path"],
            "trim_in": trim_in,
            "trim_out": trim_out,
            "transition_after": transition,
        })

    if not selections:
        raise ClaudeError("Claude returned no valid clip selections")

    rationale = data.get("rationale")
    if not isinstance(rationale, str):
        rationale = ""
    rationale = _annotate_duration_shortfall(selections, rationale)

    return {"selections": selections, "rationale": rationale}


def _select_candidates(usable: list[dict]) -> list[dict]:
    """Highest-scored usable clips (Stage 1's score, not a re-judgment),
    kept until their combined valid_trim duration covers
    CANDIDATE_DURATION_BUDGET or MAX_CANDIDATES_CEILING is hit, whichever
    comes first. Always includes at least one clip, even if its own span
    alone exceeds the budget."""
    ranked = sorted(usable, key=lambda c: c["score"], reverse=True)
    candidates: list[dict] = []
    total_span = 0.0
    for clip in ranked:
        if candidates and (
            total_span >= CANDIDATE_DURATION_BUDGET or len(candidates) >= MAX_CANDIDATES_CEILING
        ):
            break
        candidates.append(clip)
        valid_in, valid_out = clip["valid_trim"]
        total_span += valid_out - valid_in
    return candidates


def select_reel_clips(
    scored_clips: list[dict],
    *,
    timeout: int = 600,
    tmp_dir: str | Path | None = None,
) -> dict:
    """Top-level entry: Stage 1's scored clips -> Claude's selection, order,
    trim, and transition plan, clamped to each clip's own valid_trim.

    Only clips with usable=True are considered; which ones become Stage 2's
    candidates is decided by _select_candidates (a duration budget, not a
    fixed count, so a week with plenty of good footage offers Claude more
    to choose from).
    """
    usable = [c for c in scored_clips if c.get("usable")]
    candidates = _select_candidates(usable)
    if not candidates:
        raise ClaudeError("no usable clips to select from")

    def _run(tmp: str) -> dict:
        tmp_path = Path(tmp)
        staged: list[Path] = []
        labels: list[str] = []
        for i, clip in enumerate(candidates):
            frames = _extract_representative_frames(
                clip["path"], clip["valid_trim"], FRAMES_PER_CLIP, tmp_path, prefix=f"{i:02d}_"
            )
            for j, frame in enumerate(frames):
                staged.append(frame)
                labels.append(f"[clip {i}, frame {j}]")

        prompt = SELECTION_PROMPT.format(
            count=len(candidates),
            clip_list=_format_clip_list(candidates),
            min_duration=TARGET_DURATION_MIN,
            max_duration=TARGET_DURATION_MAX,
        )

        data = run_json_prompt(prompt, timeout=timeout, image_paths=staged, image_labels=labels)
        return apply_selection(data, candidates)

    if tmp_dir is not None:
        Path(tmp_dir).mkdir(parents=True, exist_ok=True)
        return _run(str(tmp_dir))
    with tempfile.TemporaryDirectory(prefix="postroll-selectclips-") as tmp:
        return _run(tmp)
