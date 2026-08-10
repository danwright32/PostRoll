"""
PostRoll — Thursday reel preview builder.

Writes just the masonry strip PNG (and its layout sidecar) for the
Thursday scroll reel, without running the ffmpeg video encode. Used by
the caption review step to load a fast, interactive strip the user can
pan/zoom per cell before committing a full regeneration.

Usage:
    python -m postroll.ai.build_reel_preview \
        --manifest /path/to/manifest.json \
        --output   /path/to/reel_preview.png

Manifest shape:
    {
      "photos": ["/abs/path/1.jpg", ...],
      "seed": 1234,                          // optional — reel layout seed
      "crop_offsets": [[x, y, zoom], ...]    // optional — parallel to photos
    }
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from ..media.generate_reel_scroll import build_reel_preview


def _main() -> int:
    parser = argparse.ArgumentParser(description="Build the Thursday reel preview PNG")
    parser.add_argument("--manifest", required=True, help="JSON with photos + optional seed/crop_offsets")
    parser.add_argument("--output",   required=True, help="Where to write the preview PNG")
    args = parser.parse_args()

    try:
        manifest = json.loads(Path(args.manifest).read_text())
    except Exception as e:
        print(f"error: could not read manifest: {e}", file=sys.stderr)
        return 1

    photos = manifest.get("photos") or []
    if not photos:
        print("error: manifest has no photos", file=sys.stderr)
        return 1

    seed = manifest.get("seed")
    raw_offsets = manifest.get("crop_offsets")
    crop_offsets = None
    if raw_offsets:
        crop_offsets = [
            (float(t[0]), float(t[1]), float(t[2]))
            for t in raw_offsets if len(t) >= 3
        ]

    print(f"[build_reel_preview] photos from manifest ({len(photos)}):", flush=True)
    for i, p in enumerate(photos):
        print(f"  [{i}] {Path(p).name}", flush=True)
    try:
        png_path = build_reel_preview(
            photo_paths=photos,
            output_path=args.output,
            seed=seed,
            crop_offsets=crop_offsets,
        )
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    # No result JSON. This used to write {"png": ..., "layout": ...} and
    # nothing ever read it: the app passes the PNG path in via --output and
    # derives the layout sidecar's name from it, so a reader would only be
    # handed back what it already sent (#262). Deleted rather than wired,
    # because a write with no reader looks alive to any is-this-used check.
    print(f"[build_reel_preview] png={png_path}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(_main())
