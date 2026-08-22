"""How much of each side the phone crops, recorded per device (#775).

`design_tokens.SAFE_SIDE` is the only one of the four safe-area tokens that is
genuinely device dependent. How much of a 9:16 frame is cut off follows from the
phone's own aspect ratio: a 16:9 screen crops nothing and letterboxes instead,
and a taller screen crops more. The other three describe furniture whose size
barely moves between phones.

So the number has to be the widest crop SEEN rather than the only crop measured,
and it started as the second: one reading, on Dan's iPhone 16 Pro Max, written
into a code comment as prose. A comment cannot hold a second reading without
somebody deciding by hand which of the two the token should follow, and the
reading that gets replaced is the one nobody can check afterwards.

This file holds the table to two rules. Every reading names the device and the
day it was taken, so a figure can be traced to a phone rather than standing as
an anonymous constant; and the token is never narrower than the widest reading
in it, so adding a phone that crops more raises the floor rather than sitting
beside it being ignored (L41).
"""

from __future__ import annotations

import re

from postroll.media import design_tokens as tokens
from postroll.media.design_tokens import SideCropReading


def test_there_is_at_least_one_reading():
    # Every check below compares against this table. An empty one would make
    # each of them pass over nothing at all, and the widest of no readings is
    # a number no phone produced (L98).
    assert len(tokens.SIDE_CROP_READINGS) >= 1


def test_every_reading_names_the_phone_it_came_from():
    # The whole point of the table. A reading with no device is a constant
    # again, and the next person cannot tell whether it has been superseded.
    for reading in tokens.SIDE_CROP_READINGS:
        assert reading.device.strip(), reading
        assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", reading.measured), (
            f"{reading.device} has no measurement date, so nothing says how "
            f"old this reading is: {reading.measured!r}")


def test_every_reading_names_the_surface_it_was_seen_on():
    """How much is lost depends on the SURFACE, not only on the phone (#805).

    `SAFE_SIDE` was set from two published REELS on Dan's iPhone 16 Pro Max,
    where Instagram filled the screen with the 1080 wide frame and cut about 57
    canvas pixels off each side. Measured on the same phone on 2026-08-21, a
    published STORY was fitted to the 1320px screen width with black bands above
    and below: all 1080 pixels visible, no side crop at all.

    Nothing beside the token recorded that, so a reader would reasonably
    conclude every full-frame asset loses its edges on every surface.
    """
    for reading in tokens.SIDE_CROP_READINGS:
        assert reading.surface.strip(), (
            f"{reading.device} on {reading.measured} records no surface, so "
            "nothing says whether it was seen as a reel or a story, and the two "
            "measured differently on the same phone (#805)")


def test_a_readings_surface_is_one_this_repo_knows():
    """A free string quietly makes a third surface out of a typo.

    The set is small and deliberate. Adding to it is a decision (a new place
    Instagram shows a full frame), and the guard makes it one somebody takes
    rather than one a spelling takes for them (L113).
    """
    unknown = sorted({reading.surface for reading in tokens.SIDE_CROP_READINGS}
                     - tokens.SIDE_CROP_SURFACES)

    assert not unknown, (
        f"these readings name a surface nothing here knows: {unknown}. Add it "
        "to SIDE_CROP_SURFACES if it is real, so the vocabulary stays one that "
        f"was chosen. Known: {sorted(tokens.SIDE_CROP_SURFACES)}")


def test_both_surfaces_measured_on_the_same_phone_are_kept():
    """The finding is the DIFFERENCE, so both halves have to survive.

    A table holding only the reel reading is the state that made this worth
    filing, and one holding only the story reading would drop SAFE_SIDE to zero
    the day somebody computed the token from it.
    """
    same_phone = {reading.surface for reading in tokens.SIDE_CROP_READINGS
                  if reading.device == "iPhone 16 Pro Max"}

    assert {"reel", "story"} <= same_phone, (
        "the iPhone 16 Pro Max readings no longer cover both a reel and a "
        f"story, so the difference between them is not recorded: {same_phone}")


def test_a_letterboxed_surface_does_not_lower_the_token():
    """The control for the reading being safe to add at all (L159).

    The story reads zero, and the token is the WIDEST crop seen. If the table
    were ever reduced by an average or a latest-wins rule, adding a surface that
    crops nothing would narrow the safe area on a phone that really does crop,
    which is the direction that declares a column safe while it is cut off.
    """
    letterboxed = SideCropReading(device="iPhone 16 Pro Max", surface="story",
                                  measured="2026-08-21",
                                  screen=(1320, 2868), shown=1320, window=1320)

    assert letterboxed.canvas_pixels_per_side == 0
    assert tokens.widest_side_crop((letterboxed,) + tokens.SIDE_CROP_READINGS) \
        == tokens.widest_side_crop(tokens.SIDE_CROP_READINGS), (
            "a surface that crops nothing changed the widest crop, so the token "
            "no longer follows the worst case")


def test_a_reading_derives_its_crop_from_what_was_actually_measured():
    """The arithmetic, against the reading it was first worked out from.

    Instagram draws the 1080 wide frame at `shown` screen pixels inside a
    `window` of fewer, so the overflow is cut off, half from each side, and that
    is converted back into canvas pixels by the same scale.

    Checked against the figures #768 recorded in prose on 2026-08-20: a 1080
    frame shown at 1476 in a 1320 window, which is 78 screen pixels a side and
    57 canvas pixels a side.
    """
    reading = SideCropReading(device="iPhone 16 Pro Max", surface="reel",
                              measured="2026-08-20",
                              screen=(1320, 2868), shown=1476, window=1320)

    assert reading.screen_pixels_per_side == 78
    assert round(reading.canvas_pixels_per_side) == 57


def test_a_phone_that_crops_nothing_reads_as_nothing():
    """A 16:9 screen letterboxes rather than cropping, so it must read as zero.

    The control for the arithmetic above (L159): a formula that only ever sees
    cropping phones could be scaled wrongly and still look plausible on every
    one of them. This is the case where the answer is known exactly.
    """
    reading = SideCropReading(device="a 16:9 screen", surface="reel",
                              measured="2026-08-20",
                              screen=(1080, 1920), shown=1080, window=1080)

    assert reading.canvas_pixels_per_side == 0


def test_the_token_is_never_narrower_than_the_widest_reading():
    # The rule the table exists to enforce. A token under the widest reading
    # would declare a column safe that a phone in use is cutting off.
    assert tokens.SAFE_SIDE >= tokens.widest_side_crop(), (
        f"SAFE_SIDE is {tokens.SAFE_SIDE} and the widest crop measured is "
        f"{tokens.widest_side_crop():.1f} canvas pixels, on "
        f"{max(tokens.SIDE_CROP_READINGS, key=lambda r: r.canvas_pixels_per_side).device}. "
        "Raise SAFE_SIDE to cover it rather than leaving the reading in the "
        "table with nothing acting on it.")


def test_a_wider_reading_would_actually_raise_the_floor():
    """The control for the check above.

    A guard is only real once it has been seen to fail (L1). `widest_side_crop`
    takes a table so this can hand it a phone that crops more than the token
    allows and watch the comparison go the other way, without touching the
    committed readings.
    """
    hungry = SideCropReading(device="a taller phone than any seen",
                             surface="reel", measured="2026-08-20",
                             screen=(1320, 3200), shown=1800, window=1320)
    widest = tokens.widest_side_crop(tokens.SIDE_CROP_READINGS + (hungry,))

    assert widest > tokens.SAFE_SIDE, (
        "the synthetic phone this control is built on does not crop more than "
        f"SAFE_SIDE ({widest:.1f} against {tokens.SAFE_SIDE}), so the check "
        "above has not been shown able to fail")


def test_the_token_still_covers_the_only_phone_measured_so_far():
    # Named rather than implied. This is the reading SAFE_SIDE was set from, and
    # a table that had silently lost it would leave the token unexplained.
    devices = [reading.device for reading in tokens.SIDE_CROP_READINGS]

    assert "iPhone 16 Pro Max" in devices, devices
