"""The signature at the foot of the Tuesday reels has to read on a phone.

Dan, 2026-10-03, looking at the slider reel on his phone: "my logo is basically
unreadable at the bottom of the before/after reel. too small." The plate drew
the mark 340px wide, and the file is mostly padding, so the ink was about 286px
across a 1080 frame and the PHOTOGRAPHY.COM line a few pixels tall at phone
size. A design round settled 680 for the plate reels AND the closing before and
after slide they end on, so the reel signs at one size from first frame to last.

Measured as drawn ink on a real render rather than as the constant, because the
constant is a box around padding and the complaint was about what is visible.
"""

from __future__ import annotations

from PIL import Image, ImageChops

from postroll.media.design_tokens import SAFE_BOTTOM
from postroll.media.wordmark import BLACK

#: The mark's ink must span at least half the frame. 680 draws about 572px of
#: ink; the 340 that prompted this drew about 286, and 460 about 387.
MIN_INK_SHARE = 0.5


def _mark_ink(frame: Image.Image) -> tuple[int, int, int, int]:
    """Bounding box of the black ink in the lower part of the frame.

    The mark is the only near black thing down there: the rules are rose gold,
    the placard is rose and warm grey, and the fixture photo is mid brown.
    """
    rgb = frame.convert("RGB")
    top = int(rgb.height * 0.6)
    foot = rgb.crop((0, top, rgb.width, rgb.height))
    # Near black needs every channel dark, so combine per channel masks.
    r, g, b = (ch.point(lambda v: 255 if v < 50 else 0) for ch in foot.split())
    mask = ImageChops.multiply(ImageChops.multiply(r, g), b)
    box = mask.getbbox()
    assert box, "no wordmark ink found at the foot of the frame"
    return (box[0], box[1] + top, box[2], box[3] + top)


def _assert_reads(frame: Image.Image, what: str) -> int:
    left, _, right, bottom = _mark_ink(frame)
    width = right - left
    assert width >= frame.width * MIN_INK_SHARE, (
        f"{what}: the wordmark's ink is {width}px across a {frame.width}px "
        f"frame, under the {MIN_INK_SHARE:.0%} it needs to read on a phone")
    assert bottom <= frame.height - SAFE_BOTTOM, (
        f"{what}: the wordmark ends at y={bottom}, inside the "
        f"{SAFE_BOTTOM}px Instagram lays its caption over")
    return width


def _plate_frame(photo_path: str) -> Image.Image:
    from postroll.media import generate_reel_slider as slider
    photo = Image.open(photo_path).convert("RGB")
    rect, canvases = slider.hang_the_states(photo, photo, photo)
    return slider.draw_branded_chrome(
        canvases[0], "Test", "Org", "Venue", slider.load_logo(BLACK), rect,
        "RAW", "EDIT", 0.0)


def _closing_slide(photo_path: str, out, bw: str | None) -> Image.Image:
    from postroll.media.generate_before_after import generate_before_after
    generate_before_after(
        raw_path=photo_path, edit_path=photo_path, output_path=str(out),
        event_name="Test", org="Org", venue="Venue", logo_path=BLACK,
        bw_path=bw)
    return Image.open(out)


def test_the_plate_reels_sign_large_enough_to_read(sample_photo):
    _assert_reads(_plate_frame(sample_photo), "plate reel")


def test_the_closing_slide_signs_large_enough_to_read(sample_photo, tmp_output):
    _assert_reads(_closing_slide(sample_photo, tmp_output / "two.png", None),
                  "two photo closing slide")
    _assert_reads(_closing_slide(sample_photo, tmp_output / "three.png",
                                 sample_photo),
                  "three photo closing slide")


def test_the_reel_and_its_closing_slide_sign_at_one_size(sample_photo, tmp_output):
    plate = _assert_reads(_plate_frame(sample_photo), "plate reel")
    closing = _assert_reads(
        _closing_slide(sample_photo, tmp_output / "ba.png", None),
        "closing slide")
    assert abs(plate - closing) <= 2, (
        f"the reel signs {plate}px wide and the slide it ends on {closing}px, "
        "so the signature jumps size on the last frame")
