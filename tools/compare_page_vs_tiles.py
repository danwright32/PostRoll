"""Whole page at the server's cap, against the same page in tiles (#207, #208).

The first calibration run produced a negative result worth keeping: a cropped
credits block still read perfectly at a rendered line height of 10px, well below
the ~14px the shipped path delivers. So "line height in pixels" is not on its
own the thing that breaks OCR, and a threshold expressed that way would have
been a number that looked measured and predicted nothing.

What differs in the failing case is the WHOLE PAGE. The model the app pins
(claude-sonnet-4-6) downscales an image to a 1568px long edge server side, so
sending a bigger page changes nothing: a 4032px page arrives with its small
print at roughly 14px whatever we upload. Tiling is the only way to put more
pixels on that text, because each tile is its own image and gets its own 1568.

This measures that directly: same page, same reference names, whole versus
tiled, scored the same way.

Usage:
    venv/bin/python tools/compare_page_vs_tiles.py --page <native.png> \
        --truth-file truth.txt --grid 2 2 --out result.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from postroll.ai.claude_client import MAX_IMAGE_EDGE, run_prompt  # noqa: E402

PROMPT = (
    "Transcribe every personal name printed in this image, exactly as it "
    "appears, one per line. Copy the letters you can see; do not correct "
    "spelling, do not guess at a name you cannot read, and do not add names "
    "that are not printed. Output only the names, nothing else."
)


def ask(paths: list[Path]) -> list[str]:
    raw = run_prompt(PROMPT, image_paths=[str(p) for p in paths], timeout=600,
                     step="calibrate:tiles")
    out = []
    for line in raw.splitlines():
        name = line.strip().lstrip("-*0123456789.) ").strip()
        if name and len(name.split()) <= 5:
            out.append(name)
    return out


def score(reference: list[str], got: list[str]) -> dict:
    got_set = {n.lower() for n in got}
    missed = [n for n in reference if n.lower() not in got_set]
    return {"reference": len(reference), "exact": len(reference) - len(missed),
            "missed": missed,
            "rate": round((len(reference) - len(missed)) / len(reference), 3)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--page", required=True, type=Path)
    ap.add_argument("--truth-file", required=True, type=Path)
    ap.add_argument("--grid", nargs=2, type=int, default=[2, 2], metavar=("COLS", "ROWS"))
    ap.add_argument("--overlap", type=float, default=0.06,
                    help="fraction of a tile repeated on each side, so a name "
                         "sitting on a seam is whole in at least one tile")
    ap.add_argument("--out", required=True, type=Path)
    ns = ap.parse_args()

    work = ns.out.parent / "tiles"
    work.mkdir(parents=True, exist_ok=True)
    reference = [l.strip() for l in ns.truth_file.read_text().splitlines() if l.strip()]
    page = Image.open(ns.page)
    print(f"page {page.width}x{page.height}, {len(reference)} reference names",
          flush=True)

    # 1. Whole page, exactly as the shipped path sends it.
    whole = page.copy()
    whole.thumbnail((MAX_IMAGE_EDGE, MAX_IMAGE_EDGE), Image.LANCZOS)
    whole_path = work / "whole.png"
    whole.save(whole_path)
    whole_score = score(reference, ask([whole_path]))
    print(f"whole  {whole.width}x{whole.height}  "
          f"{whole_score['exact']}/{whole_score['reference']}  "
          f"rate={whole_score['rate']}", flush=True)

    # 2. The same page as an overlapping grid of tiles, each capped separately.
    cols, rows = ns.grid
    tiles: list[Path] = []
    tw, th = page.width / cols, page.height / rows
    ox, oy = tw * ns.overlap, th * ns.overlap
    for r in range(rows):
        for c in range(cols):
            box = (max(0, int(c * tw - ox)), max(0, int(r * th - oy)),
                   min(page.width, int((c + 1) * tw + ox)),
                   min(page.height, int((r + 1) * th + oy)))
            tile = page.crop(box)
            tile.thumbnail((MAX_IMAGE_EDGE, MAX_IMAGE_EDGE), Image.LANCZOS)
            p = work / f"tile_r{r}c{c}.png"
            tile.save(p)
            tiles.append(p)
    print(f"tiles  {cols}x{rows}, each up to {MAX_IMAGE_EDGE}px", flush=True)

    # Asked one tile at a time: a name is either legible in its tile or not, and
    # batching them into one request would let a neighbouring tile supply a name
    # this one could not actually read.
    seen: list[str] = []
    for p in tiles:
        got = ask([p])
        seen.extend(got)
        print(f"  {p.name}: {len(got)} names", flush=True)
    tiled_score = score(reference, seen)
    print(f"tiled  {tiled_score['exact']}/{tiled_score['reference']}  "
          f"rate={tiled_score['rate']}", flush=True)

    ns.out.write_text(json.dumps({
        "page": str(ns.page), "page_size": [page.width, page.height],
        "max_image_edge": MAX_IMAGE_EDGE, "grid": ns.grid,
        "whole": whole_score, "tiled": tiled_score,
    }, indent=2))
    print(f"\nwritten to {ns.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
