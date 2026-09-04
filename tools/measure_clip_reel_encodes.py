"""What the clip reel's intermediate encodes cost, and what they buy (#826).

#819 measured ONE lever, the x264 preset on `render_clip_reel._prepare_segment`,
and left it alone: dropping `veryfast` took a 30s reel from 16.6s to 37.8s for
1.0 dB of PSNR against a lossless intermediate. The other lever was never
measured. Keeping `veryfast` and lowering the intermediate's `-crf` costs
bitrate and disk rather than CPU, and generation loss is what carries into the
delivered file, so it might buy the same fidelity for none of the time.

That measurement was taken by hand and only its conclusion survived, in a
comment. This is the same comparison, written down, so the next person to ask
re-takes the readings rather than re-inventing the method (L31, L107). It moves
`render_clip_reel.SEGMENT_PRESET` and `SEGMENT_CRF`, which is what the encode
itself reads, so what is measured is the pipeline rather than a copy of it.

    venv/bin/python tools/measure_clip_reel_encodes.py
    venv/bin/python tools/measure_clip_reel_encodes.py --clips a.mov b.mov c.mov

What it reports, per variant:

  * wall clock for the whole reel render, which is what Dan waits for;
  * PSNR and SSIM of the delivered file against the SAME reel rendered from
    LOSSLESS intermediates, which is the best material the last pass could
    possibly have, so the difference is exactly what the intermediate encode
    threw away;
  * the delivered file's size.

Without `--clips` it synthesises its own footage: a photograph panned across the
frame with film grain laid over it. Grain is the hardest thing there is for an
encoder, and panning means no two frames are alike, so at the default `--grain`
this is the worst case rather than a flattering one. `--grain 8` is the second
reading, on footage nearer what a camera produces, which is what says whether an
answer holds outside the worst case.

Real Friday clips are better than either and `--clips` takes them. There were
none on this machine when the readings recorded in `render_clip_reel.py` were
taken, so both of those are synthetic.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from postroll.media import render_clip_reel as clip  # noqa: E402


@dataclass(frozen=True)
class Variant:
    """One way of encoding the intermediates, and why it is here."""

    name: str
    preset: str
    crf: str
    why: str


#: Lossless first, because everything else is measured against it. `-qp 0` is
#: x264's lossless mode: the intermediates then throw nothing away, so a
#: delivered file rendered from them carries only what the LAST pass cost, which
#: is the reference every other row is compared against.
VARIANTS: tuple[Variant, ...] = (
    Variant("lossless", "veryfast", "0",
            "the reference: intermediates that threw nothing away"),
    Variant("veryfast crf 20", "veryfast", "20", "what ships today"),
    Variant("veryfast crf 16", "veryfast", "16", "the lever #826 asks about"),
    Variant("medium crf 20", "medium", "20", "the lever #819 measured and left"),
)

REFERENCE = VARIANTS[0].name


def _synthetic_clips(workspace: Path, *, count: int, seconds: float,
                     grain: int) -> list[Path]:
    """Footage that is hard to encode, rather than footage that flatters one.

    A still panned across the frame with grain over it. Flat colour or a held
    frame would compress to nothing at any setting and every variant would read
    the same, which is a measurement that cannot answer the question.

    `grain` is worth moving rather than fixing. Heavy grain is the worst case an
    encoder meets, and a conclusion drawn only there could be an artifact of
    footage that is nearly incompressible; a second reading on gentler footage
    says whether the answer holds where real clips live.
    """
    clips = []
    for index in range(count):
        path = workspace / f"source{index}.mp4"
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error",
             "-f", "lavfi",
             "-i", f"testsrc2=s=2560x1440:d={seconds}:r=30",
             "-vf", (f"noise=alls={grain}:allf=t+u,"
                     f"crop=1920:1080:x='(in_w-out_w)*t/{seconds}':y='(in_h-out_h)/2'"),
             "-c:v", "libx264", "-preset", "veryfast", "-qp", "0",
             "-pix_fmt", "yuv420p", str(path)],
            check=True, capture_output=True)
        clips.append(path)
    return clips


def _selections(clips: list[Path], *, seconds: float) -> list[dict]:
    return [{"clip_path": str(path), "trim_in": 0.0, "trim_out": seconds,
             "transition_after": "cut"} for path in clips]


def render(variant: Variant, selections: list[dict], out: Path) -> float:
    """Render the reel with `variant`'s intermediate settings. Returns seconds.

    The settings are put back afterwards whatever happens, because this runs
    every variant in one process and a raised ffmpeg error would otherwise leave
    the next variant measuring the wrong thing under the right name.
    """
    before = (clip.SEGMENT_PRESET, clip.SEGMENT_CRF)
    clip.SEGMENT_PRESET, clip.SEGMENT_CRF = variant.preset, variant.crf
    started = time.monotonic()
    try:
        clip.render_clip_reel(selections, out)
    finally:
        clip.SEGMENT_PRESET, clip.SEGMENT_CRF = before
    return time.monotonic() - started


def _ffmpeg_metric(actual: Path, reference: Path, filter_name: str,
                   marker: str) -> str:
    """Run one of ffmpeg's comparison filters and hand back its summary line.

    Found by the marker the SUMMARY carries rather than by the filter's name,
    which also appears in ffmpeg's per-frame progress and in the filter graph it
    echoes back. Raises rather than returning a blank when the marker is absent:
    an empty answer would print as a dash and read as two files that match (L11).
    """
    completed = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(actual), "-i", str(reference),
         "-lavfi", f"[0:v][1:v]{filter_name}", "-f", "null", "-"],
        capture_output=True, text=True)
    for line in reversed(completed.stderr.splitlines()):
        if marker in line:
            return line.strip()
    raise RuntimeError(
        f"ffmpeg's {filter_name} printed no {marker!r} for {actual.name}, so "
        f"nothing here measured it:\n{completed.stderr.strip()[-800:]}")


def psnr_db(actual: Path, reference: Path) -> float:
    line = _ffmpeg_metric(actual, reference, "psnr", "average:")
    found = re.search(r"average:([0-9.]+|inf)", line)
    if found is None:
        raise RuntimeError(f"no average in ffmpeg's psnr line: {line}")
    return float("inf") if found.group(1) == "inf" else float(found.group(1))


def ssim(actual: Path, reference: Path) -> float:
    line = _ffmpeg_metric(actual, reference, "ssim", "All:")
    found = re.search(r"All:([0-9.]+)", line)
    if found is None:
        raise RuntimeError(f"no All: in ffmpeg's ssim line: {line}")
    return float(found.group(1))


def _say(message: str) -> None:
    """Progress, flushed.

    This renders four reels and takes minutes. Python block-buffers stdout when
    it is redirected, so without the flush a run that is working looks exactly
    like a run that has hung, which is the one thing a long step must never do.
    """
    print(message, flush=True)


def measure(clips: list[Path], workspace: Path, *, seconds: float,
            log=None) -> list[dict]:
    """Render every variant and read each one against the lossless reference."""
    if log is None:
        log = _say
    selections = _selections(clips, seconds=seconds)
    rendered: dict[str, Path] = {}
    took: dict[str, float] = {}

    for index, variant in enumerate(VARIANTS, start=1):
        out = workspace / f"reel-{variant.name.replace(' ', '-')}.mp4"
        log(f"[{index} of {len(VARIANTS)}] rendering {variant.name} "
            f"({variant.why}); this takes minutes")
        took[variant.name] = render(variant, selections, out)
        rendered[variant.name] = out
        log(f"    {took[variant.name]:.1f}s, {out.stat().st_size / 1e6:.1f} MB")

    reference = rendered[REFERENCE]
    log(f"reading each variant against {REFERENCE}")
    rows = []
    for variant in VARIANTS:
        out = rendered[variant.name]
        rows.append({
            "name": variant.name,
            "why": variant.why,
            "seconds": took[variant.name],
            "megabytes": out.stat().st_size / 1e6,
            # Against the reference, so the reference's own row reads inf and 1,
            # which is worth printing rather than hiding: a row that did not
            # read perfectly there would mean the comparison is wrong.
            "psnr": psnr_db(out, reference),
            "ssim": ssim(out, reference),
        })
    return rows


def table(rows: list[dict]) -> str:
    lines = [f"{'variant':<18}{'seconds':>9}{'MB':>8}{'PSNR dB':>10}{'SSIM':>9}  why"]
    for row in rows:
        psnr = "inf" if row["psnr"] == float("inf") else f"{row['psnr']:.2f}"
        lines.append(
            f"{row['name']:<18}{row['seconds']:>9.1f}{row['megabytes']:>8.1f}"
            f"{psnr:>10}{row['ssim']:>9.4f}  {row['why']}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--clips", nargs="*", type=Path, default=None,
                        help="real footage to measure on (best); omit to synthesise")
    parser.add_argument("--seconds", type=float, default=10.0,
                        help="seconds taken from each clip (default: 10)")
    parser.add_argument("--count", type=int, default=3,
                        help="how many synthetic clips to make (default: 3)")
    parser.add_argument("--grain", type=int, default=28,
                        help="how much grain the synthetic footage carries "
                             "(default: 28, which is the worst case)")
    args = parser.parse_args(argv)

    if not shutil.which("ffmpeg"):
        print("ffmpeg is not on PATH, so there is nothing here to measure.",
              file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="postroll-encode-measure-") as workspace:
        where = Path(workspace)
        if args.clips:
            missing = [str(path) for path in args.clips if not path.is_file()]
            if missing:
                print(f"these clips are not there: {', '.join(missing)}", file=sys.stderr)
                return 1
            clips = list(args.clips)
            _say(f"measuring on {len(clips)} real clip(s)")
        else:
            hardest = " which is the hardest case an encoder meets" \
                if args.grain >= 28 else ""
            _say(f"no clips given, so measuring on {args.count} synthetic ones: "
                 f"a panned photograph with grain {args.grain},{hardest}")
            clips = _synthetic_clips(where, count=args.count, seconds=args.seconds,
                                     grain=args.grain)

        rows = measure(clips, where, seconds=args.seconds)

    print()
    print(table(rows))
    print()
    print(f"PSNR and SSIM are against the {REFERENCE} row, which is the same reel "
          f"rendered from")
    print("intermediates that threw nothing away, so the difference is what the "
          "intermediate")
    print("encode cost and nothing else.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
