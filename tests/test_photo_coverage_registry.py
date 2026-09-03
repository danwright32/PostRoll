"""#924: every full-frame template answers for its PHOTOGRAPHS, not just its text.

`tests/test_phone_safe_area.py` refuses to let a new full-frame template exist
without being accounted for in the check about TEXT under the phone chrome.
Photographs had no equivalent. The rule that a photograph may not sit mostly
behind Instagram's caption lived entirely inside
`tests/test_collage_survives_the_phone_chrome.py` and `generate_collage.py`, and
nothing outside those files knew it existed.

That is the gap that produced #921. The collage was exposed precisely because it
was the one template nobody had positioned by hand against the chrome, and a
future template generating its own layout would inherit nothing from that fix
while every existing check stayed green (L30, L96, L129).

So each template declares an ANSWER here, and every answer is re-checked rather
than trusted:

  fixed       somebody positioned the photographs against the chrome once and
              for all. Only legitimate for a template that cannot vary its
              layout, which is checked by looking for a seed rather than taken
              on trust.
  filtered    the layout is drawn from a pool and the pool is filtered on where
              the photographs land. Checked by requiring the filter to reject
              something real.
  measured    the layout varies, and the overlap with the caption band has been
              measured and is under the line.
  not posted  it never reaches Instagram, so the caption band does not apply.
              Read off TEMPLATE_SURFACES rather than asserted here.

There is deliberately no answer meaning only that somebody looked once, which
would be the exemption problem one layer up.
"""

from __future__ import annotations

import inspect

import pytest
from PIL import Image

from postroll.media import design_fingerprint as fingerprint
from postroll.media import generate_reel_scroll as scroll
from postroll.media.design_tokens import (
    MEDIA_DESIGN_VERSIONS,
    SAFE_BOTTOM,
    TEMPLATE_SURFACES,
)
from postroll.media.generate_collage import (
    MOSTLY_HIDDEN,
    chrome_safe_collage_splits,
    fitting_collage_splits,
    hidden_by_the_caption,
)


FIXED = "fixed"
FILTERED = "filtered"
MEASURED = "measured"
NOT_POSTED = "not posted"

#: Every template in MEDIA_DESIGN_VERSIONS, and how it answers.
ANSWERS: dict[str, str] = {
    "collage": FILTERED,
    "story": FIXED,
    "cover": FIXED,
    "before_after": FIXED,
    "reel_screen": FIXED,
    "reel_morph": FIXED,
    "reel_slider": FIXED,
    "reel_clip": FIXED,
    "reel_scroll": MEASURED,
    "reel_preview": NOT_POSTED,
}


def _generates_its_layout(template: str) -> bool:
    """Whether anything that draws this template takes a layout seed.

    Derived rather than listed, so a template that GAINS a seed stops being able
    to answer `fixed` on the day it does, which is the moment the answer becomes
    wrong rather than the day somebody notices (L96).
    """
    for module_name in fingerprint.TEMPLATE_MODULES[template]:
        module = __import__(module_name, fromlist=["_"])
        for name, value in vars(module).items():
            if name.startswith("_") or not callable(value):
                continue
            if not name.startswith(("generate", "build", "render")):
                continue
            try:
                signature = inspect.signature(value)
            except (ValueError, TypeError):
                continue
            if "seed" in signature.parameters:
                return True
    return False


def _landscape_photos(folder, count: int = 24) -> list[str]:
    """Deliberately 3:2, which is what Dan shoots. An upright set would lay out
    differently and the cell heights measured below would be about a shape the
    strip never receives."""
    paths = []
    for index in range(count):
        path = folder / f"p{index}.jpg"
        Image.new("RGB", (3000, 2000), (index * 7 % 255, 90, 140)).save(path)
        paths.append(str(path))
    return paths


def test_every_full_frame_template_answers():
    """Both directions: no template without an answer, no answer without a
    template. A registry nobody holds to the code exempts whatever is missing
    from it from the very check it implements."""
    missing = sorted(set(MEDIA_DESIGN_VERSIONS) - set(ANSWERS))
    assert not missing, (
        f"these templates draw photographs and nothing here says whether one "
        f"can end up behind Instagram's caption: {missing}. Answer for each, "
        f"and be ready for the answer to be checked.")

    stale = sorted(set(ANSWERS) - set(MEDIA_DESIGN_VERSIONS))
    assert not stale, (
        f"these have an answer and are no longer templates: {stale}")


def test_every_answer_is_one_of_the_four():
    unknown = {name: answer for name, answer in ANSWERS.items()
               if answer not in {FIXED, FILTERED, MEASURED, NOT_POSTED}}
    assert not unknown, (
        f"these answers are not held to anything by the checks below: {unknown}")


@pytest.mark.parametrize(
    "template", sorted(name for name, answer in ANSWERS.items() if answer == FIXED))
def test_a_template_that_says_fixed_cannot_vary_its_layout(template):
    """`fixed` means somebody placed the photographs once and for all.

    A template that draws its arrangement from a seed cannot claim that,
    whatever anybody remembers about it, and this is what stops the answer
    outliving the design it was true of.
    """
    assert not _generates_its_layout(template), (
        f"{template} answers '{FIXED}' and takes a layout seed, so its "
        f"photographs are no longer where somebody put them. It needs a real "
        f"answer: filter the pool the way the collage does, or measure where "
        f"they land.")


@pytest.mark.parametrize(
    "template", sorted(name for name, answer in ANSWERS.items()
                       if answer in {FILTERED, MEASURED}))
def test_a_template_that_claims_more_than_fixed_actually_varies(template):
    """The other direction (L159).

    Every check in this file is satisfied by answers that are all too cautious,
    so a template claiming a filter or a measurement has to be one that needs
    them. Otherwise `fixed` has quietly stopped being checkable: nothing would
    notice a template moved out of it for no reason.
    """
    assert _generates_its_layout(template), (
        f"{template} answers '{ANSWERS[template]}', which is for templates "
        f"whose layout varies, and nothing that draws it takes a seed. If it is "
        f"hand placed it should answer '{FIXED}', which is the stricter claim.")


def test_a_template_that_says_not_posted_is_not_posted():
    """Read off TEMPLATE_SURFACES rather than asserted here, so a template that
    starts being posted loses the answer automatically."""
    answered = [name for name, answer in ANSWERS.items() if answer == NOT_POSTED]
    assert answered, "nothing answers 'not posted', so this check measures nothing"

    for template in sorted(answered):
        surfaces = TEMPLATE_SURFACES[template]
        assert surfaces == frozenset({"app"}), (
            f"{template} answers '{NOT_POSTED}' and is shown on "
            f"{sorted(surfaces)}. Instagram's caption applies wherever it is "
            f"posted, so this needs a real answer now.")


def test_the_collages_filter_rejects_something_real():
    """`filtered` is worth nothing if the filter admits everything (L159).

    The same seven landscape photographs #921 was measured on. The pool the crop
    budget offers has to contain an arrangement that buries a row, and the
    filtered pool has to drop it and keep something.
    """
    ratios = [1.5] * 7
    offered = fitting_collage_splits(7, ratios)
    kept = chrome_safe_collage_splits(7, ratios)

    assert offered, "the crop budget offers nothing, so there is no pool to filter"
    worst = max(hidden_by_the_caption(split, ratios) for split in offered)
    assert worst > MOSTLY_HIDDEN, (
        f"the worst arrangement the pool offers hides {worst:.1%} of a row, "
        f"which is inside the {MOSTLY_HIDDEN:.0%} line, so the filter has "
        f"nothing to reject and this answer is not being tested")

    assert kept, "the filter rejected every arrangement, which is not a filter"
    assert len(kept) < len(offered), "the filter kept everything it was offered"
    assert all(hidden_by_the_caption(split, ratios) <= MOSTLY_HIDDEN
               for split in kept)


def test_the_scroll_reels_gallery_is_measured_against_the_caption_band(tmp_path):
    """The scroll reel's answer, taken rather than asserted.

    Its photography viewport ends BELOW the caption band: the footer it reserves
    is 100px and Instagram covers 160, so the bottom 60px of the gallery sits
    behind the caption. That is a real overlap and the reason this template
    cannot answer `fixed`.

    It is under the line because the shortest cell a strip lays out is far
    taller than the overlap, and because the strip is moving: a photograph is
    only in that band while it passes through. Both halves are measured here, so
    a layout change that starts producing much shorter cells turns this red
    rather than going unnoticed.
    """
    overlap = SAFE_BOTTOM - scroll.FOOTER_H
    assert overlap > 0, (
        "the gallery no longer reaches the caption band at all, so this "
        "template can answer 'fixed' and this measurement is dead code")

    paths = _landscape_photos(tmp_path)
    shortest = None
    for seed in range(4):
        _, layout = scroll.build_collage_strip(paths, seed=seed, return_layout=True)
        heights = [cell["h"] for cell in layout]
        assert heights, "the strip produced no cells to measure"
        shortest = min(heights) if shortest is None else min(shortest, min(heights))

    buried = overlap / shortest
    assert buried <= MOSTLY_HIDDEN, (
        f"the gallery's bottom {overlap}px sits behind Instagram's caption, "
        f"which is {buried:.1%} of the shortest cell the strip lays out "
        f"({shortest}px), past the {MOSTLY_HIDDEN:.0%} line. Either the footer "
        f"has to reserve more or the layout has to stop making cells this short.")


def test_the_measurement_is_taken_on_a_strip_that_actually_scrolls(tmp_path):
    """The check above is satisfied by a strip so short it never moves, whose
    cells are whatever one screenful happens to hold (L159, L101)."""
    strip, _ = scroll.build_collage_strip(
        _landscape_photos(tmp_path), seed=0, return_layout=True)

    assert scroll.max_scroll_for(strip.height) > 0, (
        "the strip fits in one viewport, so it does not scroll and says nothing "
        "about a gallery moving past the caption band")
