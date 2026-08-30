"""How the scroll reel's frames are BUILT, as distinct from what they show.

#. The render was measured on 2026-08-30 against the event it was reported on
   (Battery Dance Festival, 234 photos, a 35s scroll, 1230 frames): 160.4s end
   to end, of which the frame loop was the overwhelming majority and PNG
   compression was 93% of a frame. Two costs paid per frame were the same work
   every time:

     * `draw_branded_chrome` re-laid-out the title, the band, the hairlines and
       the footer on all 1230 frames, and drew exactly the same pixels each
       time, because none of it moves.
     * every frame was compressed to a PNG in a temp directory (2.1 GB) purely
       to be handed to ffmpeg, which decompressed it again.

   Neither changes a pixel of the design. Both are removed here, and these are
   the checks that say so.

The equality check is the load bearing one. An overlay drawn once and pasted is
only a saving if it is the SAME picture as the per-frame draw, and "looks fine"
is not a reading (L1, L63): it is asserted pixel for pixel, against the drawing
routine itself, so the two cannot drift apart silently.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from PIL import Image, ImageChops

from postroll.media import generate_reel_scroll as scroll_mod


EVENT = ("Battery Dance Festival", "Battery Dance", "Wagner Park")


def _strip(height: int = 4000) -> Image.Image:
    """A strip with structure in it, so a lost or shifted paste shows up.

    Flat colour would let a frame assembled in the wrong order compare equal.
    """
    strip = Image.new("RGB", (scroll_mod.CANVAS_W, height), (20, 90, 160))
    for y in range(0, height, 17):
        for x in range(0, scroll_mod.CANVAS_W, 23):
            strip.putpixel((x, y), ((x * 7) % 256, (y * 13) % 256, (x + y) % 256))
    return strip


@pytest.fixture(scope="module")
def strip() -> Image.Image:
    return _strip()


def test_chrome_overlay_is_the_same_picture_as_drawing_it_per_frame(strip):
    """The cached overlay must not change what a frame looks like.

    Both sides come from the same drawing code, which is the point: this fails
    the moment the overlay is built from a restatement of the chrome rather
    than from the routine that draws it (L107).
    """
    for scroll_y in (0, 137, scroll_mod.max_scroll_for(strip.height)):
        bare = scroll_mod.place_strip(strip, scroll_y)
        drawn = scroll_mod.draw_branded_chrome(bare.copy(), *EVENT)
        pasted = scroll_mod.apply_chrome(bare.copy(), *EVENT)

        diff = ImageChops.difference(drawn, pasted)
        assert diff.getbbox() is None, (
            f"at scroll_y={scroll_y} the pasted chrome differs from the drawn "
            f"chrome in {diff.convert('L').getbbox()}"
        )


def test_the_chrome_is_laid_out_once_however_many_frames_are_rendered(strip, monkeypatch):
    """The saving itself, asserted as a count rather than as a duration.

    A wall clock reading here would measure what else this machine is running
    (L224). What the change actually promises is that the text layout happens
    once, so that is what is counted.
    """
    # The overlay is cached across calls, and across TESTS: without this the
    # count is 0 whenever another test warmed it first, and a check that can
    # pass by measuring nothing is not a check (L205).
    scroll_mod.chrome_tiles.cache_clear()

    calls = []
    real = scroll_mod._draw_chrome_onto
    monkeypatch.setattr(scroll_mod, "_draw_chrome_onto",
                        lambda *a, **k: (calls.append(1), real(*a, **k))[1])

    frames = list(scroll_mod.scroll_frames(
        strip, event_name=EVENT[0], org=EVENT[1], venue=EVENT[2],
        scroll_duration=1.0, fps=12, closing_frame=None))

    assert len(frames) > 12, "the fixture must render enough frames to prove reuse"
    assert len(calls) == 1, (
        f"the chrome was laid out {len(calls)} times over {len(frames)} frames; "
        "it does not move, so it is drawn once"
    )


def test_a_render_writes_no_frame_images_to_disk(tmp_path, monkeypatch):
    """Frames reach ffmpeg over a pipe, not through 2.1 GB of temp PNGs.

    Measured where the writes LAND rather than trusting the command line
    (L322): a `-f rawvideo` argument proves nothing if the loop still saves.
    """
    written: list[str] = []
    real_save = Image.Image.save

    def watched_save(self, fp, *a, **k):
        written.append(str(fp))
        return real_save(self, fp, *a, **k)

    monkeypatch.setattr(Image.Image, "save", watched_save)

    photos = []
    for i in range(6):
        p = tmp_path / f"p{i}.jpg"
        Image.new("RGB", (1200, 800), (i * 30, 80, 160)).save(p)
        photos.append(str(p))
    audio = tmp_path / "silence.m4a"
    subprocess.run(
        ["ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
         "-t", "12", "-c:a", "aac", str(audio)],
        check=True, capture_output=True)

    monkeypatch.setattr(scroll_mod, "FPS", 4)
    out = tmp_path / "reel.mp4"
    scroll_mod.generate_reel_scroll(
        photos, str(audio), str(out), event_name=EVENT[0], org=EVENT[1],
        venue=EVENT[2], scroll_duration=1.0)

    # The positive half first. An empty `written` proves nothing on its own:
    # a render that failed before the frame loop writes no frames either, and
    # would satisfy the assertion below while measuring nothing (L98, L159).
    assert out.exists() and out.stat().st_size > 0, (
        "the render did not produce a reel, so what it wrote says nothing")

    frame_files = [w for w in written if "frame_" in Path(w).name]
    assert not frame_files, (
        f"{len(frame_files)} frame images were written to disk, first "
        f"{frame_files[:1]}; frames go to ffmpeg's stdin"
    )
