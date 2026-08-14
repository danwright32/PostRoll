"""The photographs, audio and closing graphic every rendered-reel check needs.

Shared by `test_frame_legibility.py` and `test_thursday_reel_legibility.py`
since #512 split them apart. One definition rather than a copy per file: these
are not incidental scaffolding, they are the inputs the checks are calibrated
against, and two copies of a fixture drift until two files that read as the
same check are measuring different pictures.

Registered as a pytest plugin by `tests/conftest.py`, so the fixtures here are
available by name without either file importing them.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from PIL import Image

from postroll.media.generate_before_after import generate_before_after

REPO_ROOT = Path(__file__).resolve().parent.parent
LOGO = str(REPO_ROOT / "postroll" / "assets" / "logo-black.png")

#: The size every photo fixture here is built at. The morph's print rectangle
#: is a function of it, so the bands are derived from this rather than read back
#: off the module after a render (L70, #323).
PHOTO_SIZE = (2000, 1332)

#: How many frames each reel is read at. Spread across the whole file, because
#: the placards crossfade and the labels slide: an element that is only wrong
#: halfway through is exactly what one frame cannot show.
SAMPLES = 12

#: Enough photographs that the strip is genuinely taller than the canvas.
#:
#: Measured rather than guessed: at ten the generator prints "strip shorter than
#: canvas, scroll collapsed to a hold" and the colophon sits in one place for the
#: whole file. A moving-band check recorded against that would be a check of a
#: still, passing forever while the thing it exists to follow never moved (L84).
SCROLLING_PHOTOS = 16


def structured_photo(path: Path, seed: int) -> str:
    """A structured stand-in, not flat colour: a flat photo makes every band it
    touches trivially uniform and hides a placement regression."""
    img = Image.new("RGB", PHOTO_SIZE)
    pixels = img.load()
    for y in range(0, PHOTO_SIZE[1], 2):
        for x in range(0, PHOTO_SIZE[0], 4):
            shade = ((x // 40) + (y // 40) + seed) % 3
            colour = [(150, 96, 74), (66, 52, 48), (196, 158, 120)][shade]
            for dx in range(4):
                pixels[x + dx, y] = colour
                pixels[x + dx, y + 1] = colour
    img.save(path, "JPEG", quality=92)
    return str(path)


@pytest.fixture
def photos(tmp_path) -> list[str]:
    return [structured_photo(tmp_path / f"p{seed}.jpg", seed) for seed in range(10)]


@pytest.fixture
def many_photos(tmp_path) -> list[str]:
    return [structured_photo(tmp_path / f"m{seed}.jpg", seed)
            for seed in range(SCROLLING_PHOTOS)]


@pytest.fixture
def silent_audio(tmp_path) -> str:
    """A local silent track: handed no audio the generators fetch from Jamendo,
    so a test that passed None would call a third-party service on every run."""
    path = tmp_path / "silence.m4a"
    subprocess.run(
        ["ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
         "-t", "45", "-c:a", "aac", str(path)],
        check=True, capture_output=True)
    return str(path)


@pytest.fixture
def closing_graphic(photos, tmp_path) -> str:
    """The before/after graphic every Tuesday reel ends on.

    Rendered by the shipped generator rather than stood in for, because the
    reel dissolves into THIS image and holds on it for three seconds: a
    stand-in would put a different design in the window under test.
    """
    path = tmp_path / "closing.png"
    generate_before_after(
        raw_path=photos[0], edit_path=photos[1], output_path=str(path),
        event_name="Reference Event", org="Reference Org",
        venue="Reference Venue", logo_path=LOGO)
    return str(path)
