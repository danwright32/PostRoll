"""The 3-photo Tuesday reel, on the program plate (#164).

A Tuesday reel renders as a program plate. When Dan supplies a B&W after, the
day routes to the slider instead, which kept the pre-redesign flat-cream look,
so a 3-photo Tuesday reel was visually inconsistent with every other one.

Settled with Dan from an encoded prototype, not a description: one full-size
print moving through RAW, the colour edit, then the B&W; the sweep stays and the
SECOND one reverses, so the divider exits the right edge and returns from it
rather than repeating the same move; about 15.7 seconds.

These are the assertions that can go wrong quietly, so they are written against
what the render measurably does rather than against the caption text. All three
captions are the same ink in the same band, and `illegible` reports a band only
when its ink appears in NO frame, so checking that the caption changed would
pass identically on a two-photo reel: the very bug it would claim to catch.
"""

from __future__ import annotations

import subprocess

import pytest
from PIL import Image

from conftest import needs_ffmpeg, needs_mac_fonts
from postroll.media import generate_reel_slider as slider_mod
from postroll.media import program_plate as plate_mod

# Deliberately NOT marked slow, despite rendering real reels. Measured on
# 2026-08-21 it costs 25.7s of the suite's 785s, which is under the floor
# `tests/file_durations.py` sets, so `make test-python-fast` runs it. It carried
# the marker until #766 because the fast run's exclusions were derived from the
# reference-frames matrix, and this file is in that matrix for a different
# reason: its renders need the macOS system faces.



# ── the sweep, as geometry ───────────────────────────────────────────────────


def test_the_first_sweep_travels_left_to_right():
    rect = plate_mod.print_rect((3000, 2000))
    positions = [slider_mod.divider_x(rect, p / 10, rightward=True) for p in range(11)]

    assert positions == sorted(positions), positions
    assert positions[0] == rect[0]
    assert positions[-1] == rect[0] + rect[2]


def test_the_second_sweep_travels_back_the_other_way():
    rect = plate_mod.print_rect((3000, 2000))
    positions = [slider_mod.divider_x(rect, p / 10, rightward=False) for p in range(11)]

    assert positions == sorted(positions, reverse=True), positions
    assert positions[0] == rect[0] + rect[2]
    assert positions[-1] == rect[0]


def test_the_second_sweep_starts_where_the_first_finished():
    # What makes it read as one gesture returning rather than the same move
    # performed twice: the divider leaves the right edge and comes back from it.
    rect = plate_mod.print_rect((3000, 2000))

    assert (slider_mod.divider_x(rect, 1.0, rightward=True)
            == slider_mod.divider_x(rect, 0.0, rightward=False))


def test_the_sweep_never_leaves_the_print():
    # Clipped to the print, so the cream mat either side never moves. The old
    # divider ran the full height of the canvas.
    rect = plate_mod.print_rect((2000, 2500))
    for rightward in (True, False):
        for step in range(21):
            x = slider_mod.divider_x(rect, step / 20, rightward=rightward)
            assert rect[0] <= x <= rect[0] + rect[2], (rightward, step, x)


# ── one rectangle for all three photographs ──────────────────────────────────


def test_all_three_states_hang_in_the_same_rectangle():
    # Photos of deliberately different shapes. Every fixture in this repo is
    # 2000x1332, so an equal-aspect test would take the same branch forever and
    # never exercise this at all (L101).
    raw = Image.new("RGB", (3000, 2000), (140, 90, 70))
    edit = Image.new("RGB", (2000, 2500), (90, 140, 70))
    bw = Image.new("RGB", (2000, 2000), (70, 90, 140))

    rect, canvases = slider_mod.hang_the_states(raw, edit, bw)

    assert rect == plate_mod.print_rect(edit.size), (
        "the rectangle is taken from the EDIT, which is the photograph the reel "
        "is about and the one the caption hangs under")
    assert len(canvases) == 3
    for canvas in canvases:
        assert canvas.size == (plate_mod.CANVAS_W, plate_mod.CANVAS_H)


def test_a_photo_of_another_shape_is_cropped_rather_than_squashed():
    # Filling one rectangle with photos of different aspects means cropping.
    # Squashing would distort a face, which is worse than losing an edge.
    raw = Image.new("RGB", (3000, 2000), (140, 90, 70))
    edit = Image.new("RGB", (2000, 2500), (90, 140, 70))

    rect, canvases = slider_mod.hang_the_states(raw, edit, edit)
    _, _, width, height = rect

    # The raw is landscape in a portrait rectangle: it must fill it completely,
    # with no mat showing through inside the print.
    inside = canvases[0].crop((rect[0] + 4, rect[1] + 4,
                              rect[0] + width - 4, rect[1] + height - 4))
    assert plate_mod.CREAM not in inside.getdata(), (
        "the print has mat showing through it, so the photo was fitted rather "
        "than filled")


# ── the reel is one length, and it is the settled one ────────────────────────


def test_the_reel_runs_about_fifteen_point_seven_seconds():
    assert slider_mod.TOTAL_DURATION == pytest.approx(15.7, abs=0.05)


def test_the_phases_add_up_to_the_total():
    # A total that is not the sum of its parts dumps the difference into
    # whichever phase runs last, which on this reel is a hold on the closing
    # frame: a reel that silently freezes for seconds longer than intended.
    parts = (slider_mod.HOLD_RAW + slider_mod.SWEEP_DURATION
             + slider_mod.HOLD_COLOUR + slider_mod.SWEEP_DURATION
             + slider_mod.HOLD_BW + slider_mod.TRANSITION_DURATION
             + slider_mod.CLOSING_FRAME_DURATION)

    assert parts == pytest.approx(slider_mod.TOTAL_DURATION, abs=0.001)


# ── a B&W is required, because nothing else can reach this reel ──────────────


def test_rendering_without_a_black_and_white_photo_is_refused(tmp_path):
    # `resolve_tuesday_reel_style` routes here only when a B&W is present, and
    # nothing in the app writes the style override that was the other way in
    # (#324). A two-photo reel through here would be a shape the product cannot
    # produce, carrying a duration built for two sweeps.
    photo = tmp_path / "p.jpg"
    Image.new("RGB", (600, 400), (120, 90, 70)).save(photo)

    with pytest.raises(ValueError, match="black and white"):
        slider_mod.generate_reel_slider(
            raw_path=str(photo), edit_path=str(photo), bw_path=None,
            audio_path=None, output_path=str(tmp_path / "out.mp4"))


# ── read back out of the encoded file ────────────────────────────────────────


@pytest.fixture
def three_photos(tmp_path) -> tuple[str, str, str]:
    """A RAW, a colour edit and a B&W, from one structured source.

    The B&W is a real desaturation of the edit rather than a different picture,
    which is what makes the saturation assertion below mean something.
    """
    base = Image.new("RGB", (2000, 1332))
    px = base.load()
    for y in range(0, 1332, 2):
        for x in range(0, 2000, 4):
            colour = [(180, 70, 50), (60, 150, 90), (200, 170, 60)][
                ((x // 40) + (y // 40)) % 3]
            for dx in range(4):
                px[x + dx, y] = colour
                px[x + dx, y + 1] = colour

    paths = []
    for name, img in [("raw", base), ("edit", base),
                      ("bw", base.convert("L").convert("RGB"))]:
        path = tmp_path / f"{name}.jpg"
        img.save(path, "JPEG", quality=92)
        paths.append(str(path))
    return tuple(paths)


@pytest.fixture
def silent_audio(tmp_path) -> str:
    path = tmp_path / "silence.m4a"
    subprocess.run(
        ["ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
         "-t", "45", "-c:a", "aac", str(path)],
        check=True, capture_output=True)
    return str(path)


def saturation_in_the_print(frame, rect) -> float:
    """Mean saturation inside the print, 0 for a black and white photograph."""
    left, top, width, height = rect
    patch = frame.convert("RGB").crop(
        (left + 20, top + 20, left + width - 20, top + height - 20))
    pixels = list(patch.getdata())
    return sum(max(p) - min(p) for p in pixels) / len(pixels)


@needs_ffmpeg
@needs_mac_fonts
def test_the_reel_really_passes_through_a_black_and_white_state(
        three_photos, silent_audio, tmp_path):
    """The assertion that catches a reel which skipped the third photograph.

    Measured from the PHOTOGRAPH, not the caption. All three captions are the
    same ink in the same band, so a caption check would pass on a two-photo reel
    exactly as it does on a three-photo one, which is the bug it would claim to
    catch (L63: assert the quantity, never a proxy for it).
    """
    from postroll.media import frame_legibility as legibility

    raw, edit, bw = three_photos
    video = slider_mod.generate_reel_slider(
        raw_path=raw, edit_path=edit, bw_path=bw, audio_path=silent_audio,
        output_path=str(tmp_path / "slider.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        logo_path=str(slider_mod.DEFAULT_LOGO_FOR_TESTS))

    frames = legibility.sample_frames(video, 16)
    rect = plate_mod.print_rect(Image.open(edit).size)
    saturations = [saturation_in_the_print(f, rect) for f in frames]

    assert max(saturations) > 25, (
        f"no frame shows a colour photograph in the print: {saturations}")
    assert min(saturations) < 8, (
        "no frame shows a black and white photograph in the print, so the reel "
        f"never reached its third state: {saturations}")
