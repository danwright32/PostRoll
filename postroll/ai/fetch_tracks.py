"""
PostRoll — Candidate-track fetcher used by the Swift app's music picker pane.

Given a tags string (e.g. "ambient,atmospheric") and a target count, searches
Jamendo, filters out already-seen track IDs, downloads the top N into the
shared audio cache, and writes a JSON result the Swift side can decode.

Usage:
    python -m postroll.ai.fetch_tracks \
        --tags ambient,atmospheric \
        --count 5 \
        --exclude-ids 12345,67890 \
        --output /tmp/tracks.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from ..audio import fetch_audio_candidates


def _main() -> int:
    p = argparse.ArgumentParser(description="Fetch candidate tracks from Jamendo")
    p.add_argument("--tags", required=True, help="Comma-separated Jamendo tags")
    p.add_argument("--count", type=int, default=5, help="How many candidates to return")
    p.add_argument(
        "--exclude-ids",
        default="",
        help="Comma-separated Jamendo track IDs to exclude",
    )
    p.add_argument("--output", required=True, help="Where to write the JSON result")
    p.add_argument("--seed", type=int, default=None)
    args = p.parse_args()

    exclude_ids = tuple(
        x.strip() for x in args.exclude_ids.split(",") if x.strip()
    )

    try:
        tracks = fetch_audio_candidates(
            tags=args.tags,
            count=args.count,
            exclude_ids=exclude_ids,
            seed=args.seed,
        )
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    Path(args.output).write_text(json.dumps({"tracks": tracks}, indent=2))
    print(
        f"[fetch_tracks] tags={args.tags!r} returned={len(tracks)} "
        f"excluded={len(exclude_ids)}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(_main())
