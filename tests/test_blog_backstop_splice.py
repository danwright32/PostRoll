"""#109: the blog backstops must rewrite the paragraph they judged.

Both backstops find offending paragraphs, ask for a rewrite of each, then put
the rewrite back with `body.replace(original, reworded, 1)`. That searches the
WHOLE body from the start, including the `[PHOTO: file | alt text]` markers, and
takes the first match wherever it is.

Measured against the real functions, that is not merely a missed fix. When a
marker's alt text happens to contain the same sentence as the prose paragraph,
the rewrite lands in the ALT TEXT and the prose is left exactly as it was. So
the post ends up with alt text describing something the photo does not show,
and the second-person prose the check exists to remove still in it, and the only
signal is a warning on stderr that reads as if the model refused.

The fix is to splice by position rather than by text search. The paragraph list
is derived from the body the same way both times, so the index of an offender is
a reliable handle, and a marker can never be at a prose paragraph's index.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import generate_blog as gb


REWRITE = "The audience watched from the back of the hall."
WITH_CONTRACTION = "The hall wasn't full, and the band didn't mind."


def _fix_second_person(body: str, rewrite: str = REWRITE) -> str:
    with patch.object(gb, "run_prompt", side_effect=lambda p, **k: rewrite):
        return gb._fix_second_person(body)


def _fix_contractions(body: str, rewrite: str = WITH_CONTRACTION) -> str:
    with patch.object(gb, "run_prompt", side_effect=lambda p, **k: rewrite):
        return gb._fix_missing_contractions(body)


# ── the measured defect ───────────────────────────────────────────────────────

def test_a_rewrite_never_lands_in_a_photo_marker():
    # The marker's alt text is exactly the offending sentence, and it comes
    # first in the body, so a whole-body search finds it before the prose.
    body = ("[PHOTO: a.jpg | You were watching from the back.]\n\n"
            "You were watching from the back.\n\n"
            "Closing line that addresses nobody.")

    out = _fix_second_person(body)

    marker = out.split("\n\n")[0]
    assert marker == "[PHOTO: a.jpg | You were watching from the back.]", (
        f"the photo's alt text must not be rewritten: {marker}")


def test_the_offending_paragraph_is_actually_fixed_in_that_case():
    body = ("[PHOTO: a.jpg | You were watching from the back.]\n\n"
            "You were watching from the back.\n\n"
            "Closing line that addresses nobody.")

    out = _fix_second_person(body)

    assert gb._paragraphs_with_second_person(out) == [], (
        "the paragraph the check judged is the one that must change")


def test_the_same_holds_for_the_contraction_backstop():
    body = ("[PHOTO: a.jpg | A wide shot of the hall from the rear balcony]\n\n"
            "A wide shot of the hall from the rear balcony\n\n"
            "The closing line here is fine.")

    out = _fix_contractions(body)

    assert out.split("\n\n")[0] == (
        "[PHOTO: a.jpg | A wide shot of the hall from the rear balcony]")


# ── what already worked must keep working ─────────────────────────────────────

def test_an_ordinary_offending_paragraph_is_rewritten():
    body = ("Opening paragraph is fine here.\n\n"
            "You were watching from the back.\n\n"
            "Closing line that addresses nobody.")

    out = _fix_second_person(body)

    assert REWRITE in out
    assert gb._paragraphs_with_second_person(out) == []


def test_two_identical_offending_paragraphs_are_both_rewritten():
    body = ("Opening fine.\n\n"
            "You were watching from the back.\n\n"
            "You were watching from the back.\n\n"
            "Closing line.")

    out = _fix_second_person(body)

    assert gb._paragraphs_with_second_person(out) == []


def test_an_indented_paragraph_is_rewritten():
    body = ("Opening fine.\n\n"
            "   You were watching from the back.\n\n"
            "Closing line.")

    out = _fix_second_person(body)

    assert gb._paragraphs_with_second_person(out) == []


def test_a_clean_body_is_returned_untouched():
    body = ("Opening fine.\n\n"
            "[PHOTO: a.jpg | A wide shot]\n\n"
            "Closing line.")

    assert _fix_second_person(body) == body


def test_paragraph_order_and_count_survive():
    # Splicing by position must not drop, merge or reorder anything.
    body = ("One is fine.\n\n"
            "You were watching from the back.\n\n"
            "[PHOTO: a.jpg | A wide shot]\n\n"
            "Three is fine.\n\n"
            "Closing line.")

    out = _fix_second_person(body)

    assert len(out.split("\n\n")) == len(body.split("\n\n"))
    assert out.split("\n\n")[2] == "[PHOTO: a.jpg | A wide shot]"
    assert out.split("\n\n")[-1] == "Closing line."


def test_a_refused_rewrite_leaves_the_paragraph_alone():
    # A failed call must not blank the paragraph. Better second person than a
    # hole in the post.
    body = ("Opening fine.\n\n"
            "You were watching from the back.\n\n"
            "Closing line.")

    with patch.object(gb, "run_prompt", side_effect=gb.ClaudeError("rate limit")):
        out = gb._fix_second_person(body)

    assert "You were watching from the back." in out


def test_a_rewrite_that_still_offends_is_rejected():
    # The rewrite is checked before it is accepted, so a model that ignored the
    # instruction cannot make things worse.
    body = ("Opening fine.\n\n"
            "You were watching from the back.\n\n"
            "Closing line.")

    out = _fix_second_person(body, rewrite="You were still watching from the back.")

    assert "You were watching from the back." in out


def test_a_rewrite_carrying_a_photo_marker_is_rejected():
    # A rewrite that invents a marker would add a photo that does not exist.
    body = ("Opening fine.\n\n"
            "You were watching from the back.\n\n"
            "Closing line.")

    out = _fix_second_person(body, rewrite="[PHOTO: fake.jpg | invented] The hall was full.")

    assert "fake.jpg" not in out
