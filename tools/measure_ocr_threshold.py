"""Find how small program text can get before the model starts misreading it (#207).

#200 established that the shipped path's downscale to a 1568px long edge turns
the performer name "Safa" into "5afa", deterministically. What it did NOT
establish is where the boundary sits, and a scale factor is the wrong thing to
carry between programs: 0.45 of native means something different on a phone
photo of a page than on a 150dpi export.

What transfers is the size of a line of text, in pixels, in the image the model
actually receives. `tools/measure_text_size.swift` measures that locally and
free with Vision. This script calibrates it: it renders one real, dense credits
block at a range of rendered line heights and asks the model to transcribe it,
so the threshold is measured rather than guessed.

Ground truth is deliberately not "whatever Vision said". Vision and the model
are independent readers, so the reference set is only the names BOTH read the
same way at native resolution. A name they disagree on is dropped rather than
scored, because we cannot tell which of them is right.

Usage:
    ANTHROPIC_API_KEY=... venv/bin/python tools/measure_ocr_threshold.py \
        --page <native-res-page.png> --region 0.30 0.30 0.62 0.40 \
        --truth-file truth.txt --heights 10 12 14 16 20 24

Cost: one API call per height plus one reference call, a few cents in total.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from postroll.ai.claude_client import run_prompt  # noqa: E402

PROMPT = (
    "Transcribe every personal name printed in this image, exactly as it "
    "appears, one per line. Copy the letters you can see; do not correct "
    "spelling, do not guess at a name you cannot read, and do not add names "
    "that are not printed. Output only the names, nothing else."
)


def crop_region(page: Path, region: tuple[float, float, float, float]) -> Image.Image:
    """Crop by fractions of the page (x, y, w, h), y measured from the top."""
    img = Image.open(page)
    x, y, w, h = region
    box = (int(x * img.width), int(y * img.height),
           int((x + w) * img.width), int((y + h) * img.height))
    return img.crop(box)


def render_at(crop: Image.Image, native_line_px: float, target_px: float) -> Image.Image:
    """Resize so a line of text lands at `target_px` tall."""
    scale = target_px / native_line_px
    if scale >= 1.0:
        return crop.copy()
    size = (max(1, int(crop.width * scale)), max(1, int(crop.height * scale)))
    return crop.resize(size, Image.LANCZOS)


def read_names(image: Image.Image, tmp: Path, label: str) -> list[str]:
    path = tmp / f"{label}.png"
    image.save(path)
    raw = run_prompt(PROMPT, image_paths=[str(path)], timeout=300, step="calibrate:ocr")
    names = [re.sub(r"^[\-\*\d\.\)\s]+", "", ln).strip() for ln in raw.splitlines()]
    return [n for n in names if n and len(n.split()) <= 5]


def score(reference: list[str], got: list[str]) -> dict:
    """How much of the agreed reference set survived, and what it turned into."""
    got_set = {n.lower() for n in got}
    exact = [n for n in reference if n.lower() in got_set]
    missed = [n for n in reference if n.lower() not in got_set]
    return {
        "reference": len(reference),
        "exact": len(exact),
        "missed": missed,
        "rate": round(len(exact) / len(reference), 3) if reference else None,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--page", required=True, type=Path)
    ap.add_argument("--region", nargs=4, type=float, required=True,
                    metavar=("X", "Y", "W", "H"))
    ap.add_argument("--native-line-px", type=float, required=True,
                    help="line height in the NATIVE crop, from measure_text_size.swift")
    ap.add_argument("--truth-file", type=Path, required=True,
                    help="names Vision read at native resolution, one per line")
    ap.add_argument("--heights", nargs="+", type=float,
                    default=[10, 12, 14, 16, 20, 24])
    ap.add_argument("--out", type=Path, required=True)
    ns = ap.parse_args()

    tmp = ns.out.parent / "renders"
    tmp.mkdir(parents=True, exist_ok=True)
    crop = crop_region(ns.page, tuple(ns.region))
    print(f"crop {crop.width}x{crop.height}, native line {ns.native_line_px}px",
          flush=True)

    vision = [ln.strip() for ln in ns.truth_file.read_text().splitlines() if ln.strip()]
    native_read = read_names(crop, tmp, "native")

    # Only names two independent readers agree on at native resolution count as
    # ground truth. Either one alone would be scoring the model against a
    # transcript that might itself be wrong.
    vision_set = {n.lower() for n in vision}
    reference = [n for n in native_read if n.lower() in vision_set]
    print(f"vision {len(vision)}, model-at-native {len(native_read)}, "
          f"agreed reference {len(reference)}", flush=True)
    if len(reference) < 8:
        print("reference set too small to measure a threshold; widen the region",
              file=sys.stderr)
        return 1

    results = []
    for target in sorted(ns.heights, reverse=True):
        rendered = render_at(crop, ns.native_line_px, target)
        got = read_names(rendered, tmp, f"h{int(target)}")
        row = {"target_line_px": target,
               "image": f"{rendered.width}x{rendered.height}",
               **score(reference, got)}
        results.append(row)
        print(f"{target:>5.0f}px  {rendered.width}x{rendered.height}  "
              f"{row['exact']}/{row['reference']} exact  rate={row['rate']}",
              flush=True)

    ns.out.write_text(json.dumps(
        {"page": str(ns.page), "region": ns.region,
         "native_line_px": ns.native_line_px,
         "reference": reference, "results": results}, indent=2))
    print(f"\nwritten to {ns.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
