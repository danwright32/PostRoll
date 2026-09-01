"""#1129: deleting an alt text entirely satisfied every alt text rule.

`check_blog`'s length rule was `if words and not (MIN <= words <= MAX)`. The
leading `words and` exempts a zero-word alt text from the band, and every other
alt rule searches the text for something, so an empty one matches nothing and
fires nothing. A marker with its description deleted produced no finding at all.

Harmless while nothing rewrote alt text. The repair pass rewrites it with the
photograph attached, and the acceptance check is "re-run the rules and refuse if
any finding remains", so the shortest path to an accepted repair was deleting
the words. The hole is closed here, in the phase before the first repairer
exists, so the acceptance check is never satisfiable by deletion.

Its own code rather than folding into `alt_text_length`: an alt text that is
GONE and one that is eleven words long invite different actions, and rule 4
licenses writing the words for the first (L11, L260).

Word count arithmetic is pinned in the same change. `strip_em_dashes`
substitutes ", " for any dash not between digits, so a dash joined token becomes
two tokens. All three paths strip before checking, so the count has to be taken
AFTER stripping or a rewrite measuring 25 words pre strip measures 26 post
strip: the repairer declares success, `check_blog` reports `alt_text_length` on
the same body, and the round cap turns the oscillation into a silent give up.

Measured before it shipped, over the 21 stored events' two bodies plus both
correction fixtures (303 markers): 0 have an empty or under-15-word alt, and 0
have a word count that moves under `strip_em_dashes`. So this adds no finding to
any post that exists and changes nothing in `expectations.json`.
"""

from __future__ import annotations

import pytest

from postroll.ai.blog_quality import ALT_MAX_WORDS, ALT_MIN_WORDS, check_blog


PROSE = "It's a paragraph about the evening in the room."
GOOD = ("Kate DiGangi sings at The Green Room 42 with one hand on the "
        "microphone stand and the band behind her on the small stage")


def _codes(body: str, **kw) -> list[str]:
    return [f.code for f in check_blog(body, venue="", **kw)]


def _body(alt: str) -> str:
    return f"{PROSE}\n\n[PHOTO: a.jpg | {alt}]\n\n{PROSE}"


def test_a_deleted_alt_text_is_reported():
    assert "alt_text_empty" in _codes(_body(""))


def test_whitespace_is_not_an_alt_text():
    assert "alt_text_empty" in _codes(_body("   "))


def test_an_empty_alt_text_is_not_also_reported_as_the_wrong_length():
    # Two findings for one marker with nothing in it is the check crying wolf,
    # and the empty case has its own code precisely so it can say what to do.
    codes = _codes(_body(""))
    assert codes.count("alt_text_empty") == 1
    assert "alt_text_length" not in codes


def test_a_short_alt_text_is_still_a_length_finding_not_an_empty_one():
    # The boundary between the two codes, asserted in both directions.
    codes = _codes(_body("A short description of the picture"))
    assert "alt_text_length" in codes
    assert "alt_text_empty" not in codes


def test_a_good_alt_text_fires_neither():
    codes = _codes(_body(GOOD))
    assert "alt_text_empty" not in codes
    assert "alt_text_length" not in codes


def test_the_word_count_is_taken_after_the_dashes_are_stripped():
    """The arithmetic every acceptance check downstream depends on.

    A dash joined token counts as one word before `strip_em_dashes` and two
    after it. All three blog paths strip before they check, so counting before
    the strip means the repairer and the checker disagree about the same body,
    which is what turns the round cap into a silent give up.
    """
    # ALT_MAX_WORDS tokens as written, one of them dash joined, so it is
    # ALT_MAX_WORDS + 1 once the dash is gone: over the band either way you
    # count it, EXCEPT if the count is taken before the strip.
    # The dash written as an escape: the pre push style gate cannot tell a line
    # asserting ABOUT one from a line using one, so the file holds none.
    joined = " ".join(["word"] * (ALT_MAX_WORDS - 1)) + " long\u2014joined"
    assert len(joined.split()) == ALT_MAX_WORDS

    assert "alt_text_length" in _codes(_body(joined)), (
        "the count was taken before strip_em_dashes, so the checker measures a "
        "different number from the repairer that just rewrote this marker")


def test_the_band_edges_still_hold():
    assert "alt_text_length" not in _codes(_body(" ".join(["word"] * ALT_MIN_WORDS)))
    assert "alt_text_length" not in _codes(_body(" ".join(["word"] * ALT_MAX_WORDS)))
    assert "alt_text_length" in _codes(_body(" ".join(["word"] * (ALT_MIN_WORDS - 1))))
    assert "alt_text_length" in _codes(_body(" ".join(["word"] * (ALT_MAX_WORDS + 1))))


@pytest.mark.parametrize("fixture", ["bludline.json", "one_man_odyssey.json"])
def test_no_correction_fixture_gains_a_finding_from_this(fixture):
    """Measured, not assumed: this adds nothing to any post that exists."""
    import json
    from pathlib import Path

    data = json.loads((Path(__file__).parent / "fixtures" / "blog_corrections"
                       / fixture).read_text(encoding="utf-8"))
    for key in ("draft", "corrected"):
        codes = [f.code for f in check_blog(data[key], program=data["program"],
                                            venue=data["venue"])]
        assert "alt_text_empty" not in codes, (
            f"{fixture} {key} gained an alt_text_empty finding, so this change "
            "is not the no-op on real posts it was measured to be")
