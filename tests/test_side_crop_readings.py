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


def test_a_reading_derives_its_crop_from_what_was_actually_measured():
    """The arithmetic, against the reading it was first worked out from.

    Instagram draws the 1080 wide frame at `shown` screen pixels inside a
    `window` of fewer, so the overflow is cut off, half from each side, and that
    is converted back into canvas pixels by the same scale.

    Checked against the figures #768 recorded in prose on 2026-08-20: a 1080
    frame shown at 1476 in a 1320 window, which is 78 screen pixels a side and
    57 canvas pixels a side.
    """
    reading = SideCropReading(device="iPhone 16 Pro Max", measured="2026-08-20",
                              screen=(1320, 2868), shown=1476, window=1320)

    assert reading.screen_pixels_per_side == 78
    assert round(reading.canvas_pixels_per_side) == 57


def test_a_phone_that_crops_nothing_reads_as_nothing():
    """A 16:9 screen letterboxes rather than cropping, so it must read as zero.

    The control for the arithmetic above (L159): a formula that only ever sees
    cropping phones could be scaled wrongly and still look plausible on every
    one of them. This is the case where the answer is known exactly.
    """
    reading = SideCropReading(device="a 16:9 screen", measured="2026-08-20",
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
                             measured="2026-08-20",
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
