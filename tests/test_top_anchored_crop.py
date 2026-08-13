"""Auto-cropping discards from the bottom, never the top (#167).

Dan shoots performing arts, where the subject is composed in the upper part of
the frame, so a centred fill quietly takes a slice off the heads. Every surface
that crops a photo to fill a cell funnels through `crop_to_fill`, so the rule
lives in one place per language. The Swift side is pinned by
TopAnchoredCropTests; the two must agree or the editor shows one framing and the
export produces another.
"""

from __future__ import annotations

from PIL import Image

from postroll.media.generate_collage import (
    DEFAULT_CROP_OFFSET,
    TOP_ANCHORED_CROP_Y,
    crop_to_fill,
)

from tests.source_text import swift_without_comments


def _striped_portrait() -> Image.Image:
    """A 100x200 photo whose top half is white and bottom half is black, so
    which half survived a crop is readable from the pixels."""
    photo = Image.new("RGB", (100, 200), (0, 0, 0))
    photo.paste(Image.new("RGB", (100, 100), (255, 255, 255)), (0, 0))
    return photo


def test_default_keeps_the_top_and_discards_the_bottom():
    result = crop_to_fill(_striped_portrait(), 100, 100)

    assert result.size == (100, 100)
    assert result.getpixel((50, 2)) == (255, 255, 255), "the top row survived"
    assert result.getpixel((50, 97)) == (255, 255, 255), (
        "the whole cell is the photo's top half: nothing was taken off the top"
    )


def test_an_explicit_centred_crop_is_still_centred():
    result = crop_to_fill(_striped_portrait(), 100, 100, crop_offset_y=0.0)

    # A centred crop of a 200px photo into 100px takes rows 50..150, so the top
    # half of the result is white and the bottom half black.
    #
    # There was a third assertion above these, ending in `or True` (#435). Both
    # of its disjuncts were false for this fixture, so somebody had silenced a
    # wrong assertion rather than deleting it: it was permanently green, and it
    # told the next reader the opposite of what a centred crop does. The two
    # below were already doing the real work.
    assert result.getpixel((50, 10)) == (255, 255, 255)
    assert result.getpixel((50, 90)) == (0, 0, 0)


def test_an_explicit_bottom_crop_still_keeps_the_bottom():
    result = crop_to_fill(_striped_portrait(), 100, 100, crop_offset_y=1.0)

    assert result.getpixel((50, 2)) == (0, 0, 0), "rows 100..200, the black half"
    assert result.getpixel((50, 97)) == (0, 0, 0)


def test_horizontal_framing_is_unchanged():
    # A 200x100 landscape into a 100x100 cell: still centred left to right.
    photo = Image.new("RGB", (200, 100), (0, 0, 0))
    photo.paste(Image.new("RGB", (50, 100), (255, 255, 255)), (75, 0))  # white band, centred

    result = crop_to_fill(photo, 100, 100)

    assert result.getpixel((50, 50)) == (255, 255, 255), "the centred band is still centred"


def test_a_zoomed_out_photo_is_not_pinned_to_the_top():
    # zoom < 1 places the photo on a blurred background: there is no crop to
    # take off the bottom, so the default must not shove it against the top.
    photo = _striped_portrait()

    default = crop_to_fill(photo, 100, 100, zoom=0.5)
    centred = crop_to_fill(photo, 100, 100, crop_offset_y=0.0, zoom=0.5)

    assert list(default.getdata()) == list(centred.getdata())


def test_the_shared_default_tuple_carries_the_rule():
    # The three call sites (planned cells, dragged-cell override, reel strip)
    # all fall back to this one tuple, so the rule can't be half-applied.
    assert DEFAULT_CROP_OFFSET[1] is None, "None means unset, resolved per branch"
    assert TOP_ANCHORED_CROP_Y == -1.0


def test_the_reel_strip_uses_the_same_crop():
    from postroll.media.generate_reel_scroll import _crop_to_fill

    assert _crop_to_fill is crop_to_fill, (
        "the Thursday reel strip must not grow a second crop implementation"
    )


def test_swift_and_python_agree_on_the_anchor():
    """The editor draws in Swift and the export renders in Python. If these two
    constants drift, the preview shows one framing and the exported file
    carries another, which is the exact bug this app has shipped before."""
    from pathlib import Path

    swift = Path(__file__).resolve().parents[1] / "PostRollApp/Sources/Models/Event.swift"
    # Comments stripped first. A comment carrying the marker would decide which
    # text the split below reads, so the guard would measure the prose and never
    # reach the declaration (#436).
    source = swift_without_comments(swift.read_text())
    marker = "static let topAnchoredY: Double = "
    assert marker in source, "Swift lost its named anchor constant"
    value = source.split(marker, 1)[1].split("\n", 1)[0].strip()
    assert float(value) == TOP_ANCHORED_CROP_Y, (
        f"Swift anchors at {value}, Python at {TOP_ANCHORED_CROP_Y}"
    )
