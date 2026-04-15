"""
PostRoll — Swap audio on an existing reel without re-rendering video.

Re-muxes the video stream (copy, no re-encode) with a freshly fetched
Jamendo track. Typical runtime: ~3-5 seconds; no Claude API calls.

Usage:
    python -m postroll.ai.swap_reel_audio \
        --reel /path/to/reel.mp4 \
        --manifest /path/to/manifest.json \
        --output /path/to/result.json \
        [--seed N]

The manifest only needs to contain the fields used for audio tag derivation:
    {"shoot_type": "performance", "pieces": [{"title": "...", "composer": "..."}]}
"""

from __future__ import annotations

import argparse
import json
import random
import subprocess
import sys
from pathlib import Path

from ..audio import fetch_audio
from .generate_media import _derive_audio_tags


def swap_reel_audio(
    reel_path: str | Path,
    *,
    shoot_type: str,
    pieces: list[dict],
    seed: int | None = None,
) -> dict:
    """Replace the audio track on `reel_path` in place using ffmpeg stream-copy.

    Args:
        reel_path: Existing .mp4 to overwrite.
        shoot_type: Same shoot_type used when the reel was originally generated.
        pieces: Program pieces list (title + composer) for mood tag derivation.
        seed: Jamendo selection seed; None = random (so each call picks fresh).

    Returns:
        {"reel": <path>, "audio_source": <cached track path>, "tags": <tags>}
    """
    reel = Path(reel_path).resolve()
    if not reel.exists():
        raise FileNotFoundError(f"Reel not found: {reel}")

    tags = _derive_audio_tags(shoot_type, pieces)
    effective_seed = seed if seed is not None else random.randint(1, 10_000_000)
    audio_path = fetch_audio(tags, seed=effective_seed)

    # Copy video stream, replace audio stream. `-shortest` trims output to the
    # shorter of the two inputs so the reel keeps its original visual length.
    tmp = reel.with_suffix(".swap.mp4")
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", str(reel),
        "-i", audio_path,
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-c:v", "copy",
        "-c:a", "aac",
        "-b:a", "192k",
        "-shortest",
        str(tmp),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        if tmp.exists():
            tmp.unlink()
        raise RuntimeError(f"ffmpeg failed: {result.stderr.strip()}")
    tmp.replace(reel)

    return {
        "reel": str(reel),
        "audio_source": audio_path,
        "tags": tags,
    }


def _main() -> int:
    parser = argparse.ArgumentParser(description="Swap audio on an existing reel")
    parser.add_argument("--reel", required=True, help="Path to the .mp4 reel (overwritten in place)")
    parser.add_argument("--manifest", required=True, help="JSON with shoot_type + pieces")
    parser.add_argument("--output", required=True, help="Where to write the JSON result")
    parser.add_argument("--seed", type=int, default=None)
    args = parser.parse_args()

    try:
        manifest = json.loads(Path(args.manifest).read_text())
    except Exception as e:
        print(f"error: could not read manifest: {e}", file=sys.stderr)
        return 1

    try:
        result = swap_reel_audio(
            args.reel,
            shoot_type=manifest.get("shoot_type", "performance"),
            pieces=manifest.get("pieces", []),
            seed=args.seed,
        )
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    Path(args.output).write_text(json.dumps(result, indent=2))
    print(f"[swap_reel_audio] tags={result['tags']!r} audio={result['audio_source']}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(_main())
