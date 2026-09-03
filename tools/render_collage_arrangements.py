"""Render every collage arrangement the chooser could hand over (#923).

`PhoneChromeOverlay` draws the phone's chrome over the collage that WAS
rendered, so it answers "is this frame safe". It cannot answer "is every
arrangement the chooser might hand me safe", because the pool the arrangement
was drawn from is never drawn at all.

That is why #921 survived despite the overlay existing: the collage on screen
looked fine, and the one that buried three of seven photographs was a different
draw of the same seed space, one press of "New layout" away.

So this draws the POOL. One tile per arrangement `fitting_collage_splits`
offers, each with Instagram's chrome shaded over it and its verdict written on
it, and a contact sheet of all of them. The arrangements
`chrome_safe_collage_splits` REJECTS are drawn too, next to the ones that
survived, which is what makes the filter itself something you can look at rather
than infer from a test.

    venv/bin/python tools/render_collage_arrangements.py --count 7
    venv/bin/python tools/render_collage_arrangements.py --photos /path/to/day

With `--photos` the real photographs are pasted, so the tiles are what would
ship. Without, each cell is a flat block, which still answers the question the
sheet exists for: where the photographs LAND is decided by the arrangement and
the shapes, not by what is in them.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from postroll.media.design_tokens import (  # noqa: E402
    ROSE_GOLD,
    SAFE_BOTTOM,
    SAFE_TOP,
    TEXT_DARK,
    load_font,
)
from postroll.media.generate_collage import (  # noqa: E402
    CANVAS_H,
    CANVAS_W,
    MOSTLY_HIDDEN,
    STRIP_H,
    STRIP_CREAM,
    chrome_safe_collage_splits,
    fitting_collage_splits,
    hidden_by_the_caption,
    plan_collage_cells,
)

#: How wide each tile is drawn. The full canvas is 1080 wide; a sheet of ten of
#: those is unreadable on a screen, and the question here is where the rows sit
#: rather than what is in them.
TILE_W = 240

#: A default set of 3:2 landscapes, which is what Dan shoots. An upright set
#: arranges differently, and a sheet drawn from shapes he does not shoot would
#: be a picture of a pool the chooser never offers him (L48).
DEFAULT_RATIO = 1.5

#: Shading for the two bands Instagram covers, and for a cell that is mostly
#: gone behind the caption.
CHROME_TINT = (20, 20, 24)
CHROME_ALPHA = 130
BURIED_TINT = (200, 40, 40)
BURIED_ALPHA = 90


def _default_out() -> Path:
    """Where the sheet lands, and never inside the checkout.

    The repo lives under a synced folder, so a build directory in it is
    uploaded and conflict copied, which is why `tests/test_build_cache_location`
    refuses one. `make collage-arrangements` passes the shared build location
    rather than letting this guess; on a bare run the system temp folder is the
    honest answer, and the path is printed either way.
    """
    shared = os.environ.get("POSTROLL_DERIVED_DATA")
    root = Path(shared) if shared else Path(tempfile.gettempdir())
    return root / "collage-arrangements"


def _photo_ratios(folder: Path | None, count: int) -> tuple[list[float], list[Path]]:
    """The shapes to arrange, and the files to paste if there are any."""
    if folder is None:
        return [DEFAULT_RATIO] * count, []

    files = sorted(
        path for path in folder.iterdir()
        if path.suffix.lower() in {".jpg", ".jpeg", ".png"})
    if not files:
        raise SystemExit(f"no photographs in {folder}")

    ratios = []
    for path in files:
        with Image.open(path) as image:
            ratios.append(image.width / image.height)
    return ratios, files


def draw_arrangement(split, ratios, files) -> Image.Image:
    """One arrangement at full canvas size, with the chrome shaded over it.

    The cells come from `plan_collage_cells`, the planner the renderer itself
    uses, so a tile cannot show an arrangement the collage would not draw.
    """
    import random

    top_pattern, bottom_pattern = split
    cells, strip_y = plan_collage_cells(
        list(ratios), list(top_pattern), list(bottom_pattern), random.Random(0))

    canvas = Image.new("RGB", (CANVAS_W, CANVAS_H), STRIP_CREAM)
    draw = ImageDraw.Draw(canvas)

    band_top = CANVAS_H - SAFE_BOTTOM
    for cell in cells:
        box = (cell["x"], cell["y"], cell["x"] + cell["w"], cell["y"] + cell["h"])
        if files and cell["index"] < len(files):
            with Image.open(files[cell["index"]]) as photo:
                canvas.paste(photo.convert("RGB").resize((cell["w"], cell["h"])),
                             (cell["x"], cell["y"]))
        else:
            shade = 150 + (cell["index"] * 37) % 80
            draw.rectangle(box, fill=(shade, shade - 30, shade - 60))
        draw.rectangle(box, outline=TEXT_DARK, width=2)

        # A cell mostly behind the caption is the thing being hunted, so it is
        # marked on the tile rather than left to be worked out from the numbers.
        hidden = max(0, box[3] - max(box[1], band_top)) / max(1, cell["h"])
        if hidden > MOSTLY_HIDDEN:
            overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
            ImageDraw.Draw(overlay).rectangle(box, fill=BURIED_TINT + (BURIED_ALPHA,))
            canvas = Image.alpha_composite(canvas.convert("RGBA"), overlay).convert("RGB")
            draw = ImageDraw.Draw(canvas)

    draw.rectangle((0, strip_y, CANVAS_W, strip_y + STRIP_H), fill=ROSE_GOLD)

    chrome = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    chrome_draw = ImageDraw.Draw(chrome)
    chrome_draw.rectangle((0, 0, CANVAS_W, SAFE_TOP), fill=CHROME_TINT + (CHROME_ALPHA,))
    chrome_draw.rectangle((0, band_top, CANVAS_W, CANVAS_H),
                          fill=CHROME_TINT + (CHROME_ALPHA,))
    return Image.alpha_composite(canvas.convert("RGBA"), chrome).convert("RGB")


def label_for(split, ratios, kept: bool) -> tuple[str, str]:
    """Two short lines rather than one long one.

    A single line ran wider than its tile and printed over the neighbouring
    column's, so the sheet was least readable exactly where two verdicts sat
    side by side, which is the comparison it exists for (L21).
    """
    top_pattern, bottom_pattern = split
    worst = hidden_by_the_caption(split, ratios)
    verdict = "KEPT" if kept else "REJECTED"
    return (f"{verdict}  worst row {worst:.0%} hidden",
            f"{list(top_pattern)} over {list(bottom_pattern)}")


def build_sheet(ratios: list[float], files: list[Path]) -> tuple[Image.Image, list[dict]]:
    """The contact sheet, and what each tile says."""
    count = len(ratios)
    offered = fitting_collage_splits(count, ratios)
    safe = {repr(split) for split in chrome_safe_collage_splits(count, ratios)}
    if not offered:
        raise SystemExit(
            f"the crop budget offers no arrangement for {count} photographs, so "
            f"there is no pool to draw")

    scale = TILE_W / CANVAS_W
    tile_h = int(CANVAS_H * scale)
    caption_h = 34
    columns = min(5, len(offered))
    rows = (len(offered) + columns - 1) // columns

    sheet = Image.new(
        "RGB", (columns * (TILE_W + 12) + 12, rows * (tile_h + caption_h + 12) + 12),
        (245, 243, 240))
    draw = ImageDraw.Draw(sheet)
    font = load_font("detail", 11)

    entries = []
    for index, split in enumerate(offered):
        kept = repr(split) in safe
        tile = draw_arrangement(split, ratios, files).resize((TILE_W, tile_h))
        x = 12 + (index % columns) * (TILE_W + 12)
        y = 12 + (index // columns) * (tile_h + caption_h + 12)
        sheet.paste(tile, (x, y))
        verdict_line, split_line = label_for(split, ratios, kept)
        draw.text((x, y + tile_h + 3), verdict_line,
                  fill=BURIED_TINT if not kept else TEXT_DARK, font=font)
        draw.text((x, y + tile_h + 17), split_line, fill=TEXT_DARK, font=font)
        entries.append({"split": split, "kept": kept,
                        "hidden": hidden_by_the_caption(split, ratios)})

    return sheet, entries


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=7,
                        help="how many photographs to arrange (ignored with --photos)")
    parser.add_argument("--photos", type=Path, default=None,
                        help="a folder of real photographs to paste")
    parser.add_argument("--out", type=Path, default=_default_out(),
                        help="where to write the sheet")
    args = parser.parse_args(argv)

    ratios, files = _photo_ratios(args.photos, args.count)
    sheet, entries = build_sheet(ratios, files)

    args.out.mkdir(parents=True, exist_ok=True)
    path = args.out / f"arrangements-{len(ratios)}.png"
    sheet.save(path)

    kept = sum(1 for entry in entries if entry["kept"])
    print(f"{len(entries)} arrangement(s) for {len(ratios)} photographs: "
          f"{kept} kept, {len(entries) - kept} rejected")
    for entry in entries:
        verdict_line, split_line = label_for(entry["split"], ratios, entry["kept"])
        print(f"  {verdict_line:34s} {split_line}")
    print(f"\nsheet: {path}")

    # A sheet showing only survivors cannot show what the filter DOES, which is
    # half of what this exists for. Said rather than left to be noticed.
    if kept == len(entries):
        print("\nEvery arrangement in this pool is safe, so nothing here shows "
              "the filter rejecting one. Try a count with a tighter pool.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
