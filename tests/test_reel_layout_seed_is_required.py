"""#1062: the reel's masonry layout may not be seeded from system entropy.

`build_collage_strip` took `seed: int | None = None` and passed it straight to
`random.Random(seed)`, which seeds from the system when it is handed None. So a
Thursday day with no stored seed was laid out differently on every render:
adjusting the crop on one photograph re-shuffled all 234 of them.

It also made the app's speculative pre-render unsound. `SpeculativeReelRenderer`
calls the reel a pure function of five inputs, and one of them was absent, so a
pre-render and the render it was adopted for could be two different collages.

It was found while proving a render refactor was a no-op: old and new mp4s
differed in 23% of pixels, which reads exactly like a broken renderer, and the
renderer was fine (L339).

Measured in the live store on 2026-08-31: 19 of 21 Thursday days carry no seed.
The app now mints and stores one when a day's photos are assigned and again on
its first render, so reaching here without one is a defect upstream rather than
a caller asking for variety, and it is refused rather than defaulted.
"""

from __future__ import annotations

import pytest

from postroll.media.generate_reel_scroll import build_collage_strip


@pytest.fixture(scope="module")
def photos(tmp_path_factory):
    """Enough photographs for more than one masonry row.

    Module scoped: every case here reads the same pictures and none of them
    writes, so they are drawn once rather than once per case.
    """
    from reel_render_fixtures import structured_photo

    tmp = tmp_path_factory.mktemp("reel_seed")
    return [structured_photo(tmp / f"p{n}.jpg", n) for n in range(9)]


def test_a_strip_with_no_seed_is_refused(photos):
    with pytest.raises(ValueError) as raised:
        build_collage_strip(photos, seed=None)
    assert "seed" in str(raised.value).lower()


def test_the_same_seed_lays_the_photographs_out_the_same_way(photos):
    """The property the seed exists for, asserted rather than assumed.

    A refusal alone would be satisfied by a generator that took the seed and
    ignored it, which is the same reshuffle with an argument in front of it
    (L63).
    """
    first = build_collage_strip(photos, seed=163, return_layout=True)[1]
    again = build_collage_strip(photos, seed=163, return_layout=True)[1]
    assert first == again


def test_two_seeds_lay_them_out_differently(photos):
    """The other half. Without it the case above is satisfied by a generator
    that ignores the seed entirely and always produces one layout (L159)."""
    one = build_collage_strip(photos, seed=163, return_layout=True)[1]
    two = build_collage_strip(photos, seed=884, return_layout=True)[1]
    assert one != two
