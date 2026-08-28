"""A collage the crop budget admits nothing for is reported, not rendered quietly (#900).

`distinct_collage_splits` drops every arrangement that would breach the crop
budget for the photos it is given, and when NONE fit it falls back to the first
arrangement in the pool and crops harder than allowed. It prints a line to
stderr about it, which is honest and reaches nobody: stderr is not a surface Dan
reads, and the same silence is what #894 was about one level up.

7 photos is where this stops being theoretical. Measured by calling
`distinct_collage_splits(7, ratios)` directly:

    all 3:2 landscape        14 arrangements fit
    5 landscape, 2 portrait   5 fit
    all portrait              0 fit, so the forced fallback renders

So a 7 photo day is comfortable for a mostly landscape set, workable for a
mixed one, and genuinely bad for a portrait heavy one. The `opening` preset
makes 7 a count Dan can ask for, which is what makes that last row reachable.

The reading is taken through the generator's own predicate rather than a rule
restated here, so it cannot disagree with what actually renders (L107).
"""

from __future__ import annotations

from postroll.media.generate_collage import (
    crop_budget_admits,
    distinct_collage_splits,
    fitting_collage_splits,
)

LANDSCAPE = 3 / 2
PORTRAIT = 2 / 3


def test_a_landscape_seven_is_admitted():
    assert crop_budget_admits(7, [LANDSCAPE] * 7)


def test_a_mixed_seven_is_admitted():
    assert crop_budget_admits(7, [LANDSCAPE] * 5 + [PORTRAIT] * 2)


def test_a_portrait_heavy_seven_is_not():
    assert not crop_budget_admits(7, [PORTRAIT] * 7), (
        "nothing in the pool fits, so the render falls back to an arrangement "
        "that crops harder than the budget allows and says so only on stderr")


def test_the_default_four_is_still_admitted():
    """The positive control at the count that actually ships. A predicate that
    started answering False for everything would satisfy the check above (L159)."""
    assert crop_budget_admits(4, [LANDSCAPE] * 4)


def test_the_predicate_is_the_generator_own_filter():
    """Not a rule restated beside it: the count it reports has to be the count
    the render draws from, or the warning describes a different picture (L107)."""
    ratios = [LANDSCAPE] * 5 + [PORTRAIT] * 2

    assert fitting_collage_splits(7, ratios) == distinct_collage_splits(7, ratios)
    assert crop_budget_admits(7, ratios) is bool(fitting_collage_splits(7, ratios))


def test_the_forced_fallback_is_what_a_refusal_would_replace():
    """When nothing fits, `distinct_collage_splits` still returns one
    arrangement and `fitting_collage_splits` returns none. That difference is
    the whole signal, and it is asserted rather than assumed."""
    ratios = [PORTRAIT] * 7

    assert fitting_collage_splits(7, ratios) == []
    assert len(distinct_collage_splits(7, ratios)) == 1


def test_no_ratios_admits_everything():
    """A caller with no shapes to judge by is not a caller reporting a problem."""
    assert crop_budget_admits(7, None)
