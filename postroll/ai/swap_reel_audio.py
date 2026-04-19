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
    audio_file: str | Path | None = None,
) -> dict:
    """Replace the audio track on `reel_path` in place using ffmpeg stream-copy.

    Args:
        reel_path: Existing .mp4 to overwrite.
        shoot_type: Same shoot_type used when the reel was originally generated.
        pieces: Program pieces list (title + composer) for mood tag derivation.
        seed: Jamendo selection seed; None = random (so each call picks fresh).
        audio_file: If provided, use this audio file instead of fetching from Jamendo.

    Returns:
        {"reel": <path>, "audio_source": <cached track path>, "tags": <tags>}
    """
    reel = Path(reel_path).resolve()
    if not reel.exists():
        raise FileNotFoundError(f"Reel not found: {reel}")

    if audio_file:
        audio_path = str(Path(audio_file).resolve())
        if not Path(audio_path).exists():
            raise FileNotFoundError(f"Audio file not found: {audio_path}")
        tags = "user-provided"
    else:
        tags = _derive_audio_tags(shoot_type, pieces)
        effective_seed = seed if seed is not None else random.randint(1, 10_000_000)
        audio_path = fetch_audio(tags, seed=effective_seed)

    # Probe video duration so we can fade the audio out before it ends.
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(reel)],
        capture_output=True, text=True,
    )
    video_dur = float(probe.stdout.strip()) if probe.returncode == 0 else 36.0
    fade_dur = 5.0
    fade_start = max(0, video_dur - fade_dur)

    # Copy video stream, re-encode audio with trim + fade-out so the music
    # doesn't cut off abruptly regardless of the source track length.
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
        "-af", f"atrim=0:{video_dur},afade=t=out:st={fade_start}:d={fade_dur}",
        "-t", str(video_dur),
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
    parser.add_argument("--audio", default=None, help="Path to a user-provided audio file (skips Jamendo)")
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
            audio_file=args.audio,
        )
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    Path(args.output).write_text(json.dumps(result, indent=2))
    print(f"[swap_reel_audio] tags={result['tags']!r} audio={result['audio_source']}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(_main())
