"""No collage arrangement buries a photograph under Instagram's caption (#921).

The collage is the only STATIC template whose layout changes from render to
render. Every other one has a fixed design that somebody positioned against the
phone chrome once and for all (#753, #778, #898). The collage draws an
arrangement at random from a pool filtered on CROPPING alone, so nothing ever
asked where the photographs land, and the pool contains arrangements that put a
whole row inside the band Instagram lays its account row and caption over.

Measured on 2026-08-28, on seven real 3:2 photographs from Battery Dance
Festival, rendering every arrangement the crop budget admits and shading
`SAFE_BOTTOM` over it: the worst offender hides 88.9% of its bottom row, which
is three of the seven photographs effectively absent from the post. The file as
written to disk is perfectly correct, which is why no check caught it.

## The line, and why it is a meaning rather than a fitted number

More than HALF the photograph behind the caption. That is a sentence somebody
can act on, and unlike a threshold fitted to a gap it does not need clear air
either side: an arrangement moving from 51% to 49% has genuinely become
acceptable rather than crossing an arbitrary mark.

It also happens to sit in real clear air at both counts that ship, which is the
check that it is not accidentally excluding everything (L172):

    7 photos, landscape:  kept 18.5% to 33.0%   rejected 53.6% to 88.9%
   10 photos, landscape:  kept 26.5% to 42.1%   rejected 53.6% to 64.0%

Some overlap is unavoidable and is NOT what this is about: the last row always
ends at the mat, and the mat is thinner than the caption band, so every
arrangement ever drawn loses the bottom sliver of its final row. That is a crop.
Losing more than half a photograph is not.
"""

from __future__ import annotations

import pytest

from postroll.media.generate_collage import (
    CANVAS_H,
    MOSTLY_HIDDEN,
    caption_band_top,
    chrome_safe_collage_splits,
    fitting_collage_splits,
    hidden_by_the_caption,
)
from postroll.media.design_tokens import SAFE_BOTTOM

LANDSCAPE = 3 / 2
SEVEN = [LANDSCAPE] * 7

#: The arrangement the reported renders were made from, and the one that hides
#: nearly all of its bottom row of three.
GOOD = ([1, 2], [3, 1])
BURIES_A_ROW = ([1, 1, 1], [1, 3])


def test_the_band_is_the_measured_one():
    """Read from the token rather than restated, so a re-measurement of what
    Instagram covers moves this with it (L41)."""
    assert caption_band_top() == CANVAS_H - SAFE_BOTTOM


def test_a_hero_last_row_loses_only_its_bottom_edge():
    hidden = hidden_by_the_caption(GOOD, SEVEN)

    assert 0 < hidden < MOSTLY_HIDDEN, (
        f"{hidden:.1%} of a row is under the caption. Some overlap is expected, "
        "because the last row ends at the mat and the mat is thinner than the "
        "band, but this arrangement should be comfortably inside the line")


def test_a_row_of_three_at_the_foot_is_mostly_gone():
    hidden = hidden_by_the_caption(BURIES_A_ROW, SEVEN)

    assert hidden > MOSTLY_HIDDEN, (
        f"only {hidden:.1%} of the bottom row reads as hidden, but rendering "
        "this arrangement and shading the band showed three photographs almost "
        "entirely behind Instagram's caption")


def test_the_offender_is_in_the_pool_the_crop_budget_offers():
    """The positive control for the filter below. If the crop budget already
    rejected this arrangement there would be nothing here to fix, and the check
    that it is gone afterwards would pass for the wrong reason (L159)."""
    assert BURIES_A_ROW in fitting_collage_splits(7, SEVEN)


def test_the_filtered_pool_drops_it_and_keeps_the_good_one():
    safe = chrome_safe_collage_splits(7, SEVEN)

    assert BURIES_A_ROW not in safe
    assert GOOD in safe


def test_the_filter_leaves_a_real_choice_rather_than_one_survivor():
    """A filter that narrowed the gallery to a single arrangement would take
    away the reroll button rather than improve it."""
    admitted = fitting_collage_splits(7, SEVEN)
    safe = chrome_safe_collage_splits(7, SEVEN)

    assert len(safe) >= 5, f"only {len(safe)} of {len(admitted)} arrangements left"
    assert len(safe) < len(admitted), "nothing was filtered, so nothing was fixed"


@pytest.mark.parametrize("n", [2, 3, 4, 5, 6, 7, 8, 9, 10])
def test_every_shipping_count_keeps_something(n):
    """Every count the presets can ask for must still have an arrangement.

    A filter that emptied the pool at some count would send that day down the
    forced fallback, which crops harder than the budget allows, so the fix
    would trade a hidden photograph for a mangled one (L93).
    """
    ratios = [LANDSCAPE] * n
    assert chrome_safe_collage_splits(n, ratios), (
        f"{n} photographs have no arrangement that keeps every photograph at "
        "least half visible")


def test_no_ratios_means_no_judgement():
    """A caller with no shapes cannot be told where the rows land, so it is not
    told anything: the same answer the crop budget gives."""
    assert chrome_safe_collage_splits(7, None) == fitting_collage_splits(7, None)
