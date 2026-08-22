"""#826: the encode comparison is a tool, so the next person re-takes the readings.

#819 measured one lever by hand and only its conclusion survived, in a comment,
so #826 could not check the second lever without inventing the method again.
`tools/measure_clip_reel_encodes.py` is that method written down.

Nothing here renders: a reading takes minutes and four of them take most of an
hour, and what can go wrong in this tool is not the encoding. It is reporting a
number nobody measured, measuring a variant nothing ships, and leaving the
module's settings moved after a render that raised.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from postroll.media import render_clip_reel as clip
from tools.measure_clip_reel_encodes import (
    REFERENCE,
    VARIANTS,
    Variant,
    psnr_db,
    render,
    ssim,
    table,
)


def test_the_shipping_row_is_what_actually_ships():
    """A guard, not a comment (L41).

    One row claims to be the setting the pipeline uses, and the readings are
    read as "this is what today costs". If the pipeline moved and this table did
    not, that row would be a measurement of something nobody renders while
    reading as the baseline everything else is compared to.
    """
    ships = [v for v in VARIANTS if v.why == "what ships today"]
    assert len(ships) == 1, "exactly one row is the shipping setting"
    assert (ships[0].preset, ships[0].crf) == (clip.SEGMENT_PRESET, clip.SEGMENT_CRF), (
        f"the table says today's intermediates are "
        f"{ships[0].preset} crf {ships[0].crf} and render_clip_reel asks for "
        f"{clip.SEGMENT_PRESET} crf {clip.SEGMENT_CRF}")


def test_the_reference_row_throws_nothing_away():
    """Every other reading is a difference FROM this one.

    A reference encoded lossily would make each variant read better than it is,
    by exactly as much as the reference itself lost, and the whole table would
    be wrong in the flattering direction.
    """
    reference = [v for v in VARIANTS if v.name == REFERENCE]
    assert len(reference) == 1
    assert reference[0].crf == "0", (
        f"the reference is encoded at crf {reference[0].crf}, so it is not "
        f"lossless and every reading against it is measured from a moved point")


def test_the_settings_go_back_after_a_render_that_raised(tmp_path, monkeypatch):
    """The failure path, which is the one that quietly corrupts a table.

    Every variant is rendered in one process. A render that raises with the
    settings still moved would leave the NEXT variant encoding at this one's
    quality under its own name, and the table would report readings for a
    variant nobody rendered with no sign anything went wrong.
    """
    before = (clip.SEGMENT_PRESET, clip.SEGMENT_CRF)

    def explode(selections, out, **kwargs):
        raise clip.RenderClipReelError("ffmpeg died")

    monkeypatch.setattr(clip, "render_clip_reel", explode)

    with pytest.raises(clip.RenderClipReelError):
        render(Variant("hot", "placebo", "1", "why"), [], tmp_path / "reel.mp4")

    assert (clip.SEGMENT_PRESET, clip.SEGMENT_CRF) == before, (
        "a render that raised left its settings behind, so the next variant "
        "would be measured under the wrong name")


def _ffmpeg_saying(text: str):
    def fake_run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr=text)
    return fake_run


def test_a_reading_ffmpeg_never_printed_is_refused(monkeypatch):
    """An absent measurement must not read as two files that match (L11).

    Both metrics are pulled out of ffmpeg's stderr, which also carries its
    progress and the filter graph echoed back, so "the word psnr appeared" is
    not the same as "a summary was printed". A blank returned here would print
    as a dash in a table of otherwise real numbers.
    """
    monkeypatch.setattr(subprocess, "run",
                        _ffmpeg_saying("frame=  898 fps=106 q=-0.0\n"
                                       "[Parsed_psnr_0 @ 0x1] initialising"))

    with pytest.raises(RuntimeError, match="no 'average:'"):
        psnr_db(Path("a.mp4"), Path("b.mp4"))
    with pytest.raises(RuntimeError, match="no 'All:'"):
        ssim(Path("a.mp4"), Path("b.mp4"))


def test_the_summary_is_read_and_not_the_progress(monkeypatch):
    """The positive half of the check above, in the same fixture (L159)."""
    monkeypatch.setattr(subprocess, "run", _ffmpeg_saying(
        "frame=  898 fps=106 q=-0.0 psnr running\n"
        "[Parsed_psnr_0 @ 0x1] PSNR y:37.12 u:44.0 v:44.1 average:37.12 min:30 max:50\n"
        "[Parsed_ssim_0 @ 0x1] SSIM Y:0.91 U:0.98 V:0.98 All:0.9150 (10.71)"))

    assert psnr_db(Path("a.mp4"), Path("b.mp4")) == pytest.approx(37.12)
    assert ssim(Path("a.mp4"), Path("b.mp4")) == pytest.approx(0.9150)


def test_a_lossless_reading_prints_as_infinite_rather_than_a_crash():
    # The reference compared with itself really is infinite PSNR, and a table
    # that could not print it would fail on its own control row.
    printed = table([{"name": REFERENCE, "why": "the reference", "seconds": 108.5,
                      "megabytes": 308.2, "psnr": float("inf"), "ssim": 1.0}])

    assert "inf" in printed
    assert REFERENCE in printed
