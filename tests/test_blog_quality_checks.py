"""Deterministic backstops for the blog correction rules (#201).

Dan hand-corrected a generated post (The One-Man Odyssey at Greenwich House
Theater) and the edit was close to a rewrite. Prompt text alone will not hold
these rules, per this repo's standing deterministic-enforcement rule, so the
objectively checkable ones are asserted in code after generation.

These REPORT rather than rewrite. Most of them cannot be auto-fixed without
inventing something: nobody can supply the true number that replaces an
invented one, or rewrite alt text without seeing the photograph. Reporting the
exact offending text is what lets Dan fix it in seconds; silently rewriting it
would be a second guess on top of the first.

Every check below is seeded with the draft's own failing text from the real
correction, not an invented example.
"""

from __future__ import annotations

import pytest

from postroll.ai.blog_quality import check_blog, Finding

VENUE = "Greenwich House Theater"
PROGRAM = {
    "performers": [{"name": "Joseph Medeiros", "role": "actor"}],
    "pieces": [{"title": "The One-Man Odyssey", "composer": "Homer"}],
}


def codes(findings: list[Finding]) -> set[str]:
    return {f.code for f in findings}


def _clean_body() -> str:
    """A body that violates nothing, so a passing draft stays silent."""
    return (
        "The room at Greenwich House Theater is small, and the only workable "
        "position was the back of the house.\n\n"
        "[PHOTO: a.jpg | Joseph Medeiros mid-gesture on the Greenwich House "
        "Theater stage, one arm raised, warm light from the side]\n\n"
        "Staying put changed what the night looked like from where I stood, "
        "and the wide frame did most of the carrying.\n\n"
        "[PHOTO: b.jpg | Suitcase and scattered props at the front of the "
        "Greenwich House Theater stage, Joseph Medeiros crouched behind them]\n\n"
        "By the second half the blocking had settled into a shape I could read.\n"
    )


def test_a_clean_draft_reports_nothing():
    assert check_blog(_clean_body(), program=PROGRAM, venue=VENUE) == []


# ── 18. alt text length ───────────────────────────────────────────────────────

def test_alt_text_longer_than_25_words_is_reported():
    long_alt = " ".join(["word"] * 30)
    body = f"Some prose.\n\n[PHOTO: a.jpg | {long_alt}]\n\nMore prose.\n"

    found = check_blog(body, program=PROGRAM, venue=VENUE)

    assert "alt_text_length" in codes(found)
    assert any("a.jpg" in f.detail for f in found if f.code == "alt_text_length")


def test_alt_text_shorter_than_15_words_is_reported():
    body = "Some prose.\n\n[PHOTO: a.jpg | A performer on stage]\n\nMore prose.\n"

    assert "alt_text_length" in codes(check_blog(body, program=PROGRAM, venue=VENUE))


# ── 17. alt text must name the performer and the venue ────────────────────────

def test_alt_text_missing_the_venue_is_reported():
    alt = ("Joseph Medeiros stands centre stage with one arm raised while warm "
           "light falls across the boards behind him tonight")
    body = f"Some prose.\n\n[PHOTO: a.jpg | {alt}]\n\nMore prose.\n"

    assert "alt_text_missing_venue" in codes(check_blog(body, program=PROGRAM, venue=VENUE))


def test_alt_text_missing_any_performer_name_is_reported():
    alt = ("A male performer stands centre stage at Greenwich House Theater with "
           "one arm raised while warm light falls behind him")
    body = f"Some prose.\n\n[PHOTO: a.jpg | {alt}]\n\nMore prose.\n"

    found = check_blog(body, program=PROGRAM, venue=VENUE)
    assert "alt_text_missing_performer" in codes(found)


# ── 20. vary the opening ──────────────────────────────────────────────────────

def test_three_markers_sharing_an_opening_is_reported():
    alt = ("A male performer at Greenwich House Theater with Joseph Medeiros "
           "raising one arm while warm light falls behind him on stage")
    body = "P.\n\n" + "\n\n".join(
        f"[PHOTO: {n}.jpg | {alt}]\n\nProse between them." for n in "abc")

    found = check_blog(body, program=PROGRAM, venue=VENUE)

    assert "alt_text_repeated_opening" in codes(found)


def test_two_markers_sharing_an_opening_is_allowed():
    alt = ("A male performer at Greenwich House Theater with Joseph Medeiros "
           "raising one arm while warm light falls behind him on stage")
    body = "P.\n\n" + "\n\n".join(
        f"[PHOTO: {n}.jpg | {alt}]\n\nProse between them." for n in "ab")

    assert "alt_text_repeated_opening" not in codes(
        check_blog(body, program=PROGRAM, venue=VENUE))


# ── 19. no inferred inner states ──────────────────────────────────────────────

@pytest.mark.parametrize("phrase", [
    "in intense concentration", "with focused expression", "grinning toward the audience",
])
def test_inferred_inner_state_in_alt_text_is_reported(phrase):
    alt = (f"Joseph Medeiros at Greenwich House Theater {phrase} while one arm "
           "stays raised above the boards")
    body = f"P.\n\n[PHOTO: a.jpg | {alt}]\n\nMore prose.\n"

    assert "alt_text_inferred_state" in codes(check_blog(body, program=PROGRAM, venue=VENUE))


# ── 8. never invent numbers ───────────────────────────────────────────────────

def test_a_number_not_present_in_the_program_data_is_reported():
    body = ("He had about thirty seconds to reposition between scenes at "
            "Greenwich House Theater.\n\n[PHOTO: a.jpg | Joseph Medeiros at "
            "Greenwich House Theater mid-gesture with one arm raised and warm "
            "light behind him]\n\nMore prose here.\n")

    found = check_blog(body, program=PROGRAM, venue=VENUE)

    assert "invented_number" in codes(found)
    assert any("thirty" in f.detail for f in found if f.code == "invented_number")


def test_a_number_that_appears_in_the_program_data_is_allowed():
    program = dict(PROGRAM, pieces=[{"title": "Suite for 3 Voices", "composer": "Homer"}])
    body = ("The suite for 3 voices closed the night at Greenwich House Theater.\n\n"
            "[PHOTO: a.jpg | Joseph Medeiros at Greenwich House Theater mid-gesture "
            "with one arm raised and warm light behind him]\n\nMore prose.\n")

    assert "invented_number" not in codes(check_blog(body, program=program, venue=VENUE))


# ── 16. use a construction once ───────────────────────────────────────────────

def test_a_repeated_something_between_construction_is_reported():
    body = ("He was something between a game show host and a Greek chorus.\n\n"
            "The room felt like something between a stadium and a temple.\n\n"
            "[PHOTO: a.jpg | Joseph Medeiros at Greenwich House Theater mid-gesture "
            "with one arm raised and warm light behind him]\n\nMore prose.\n")

    found = check_blog(body, program=PROGRAM, venue=VENUE)

    assert "repeated_construction" in codes(found)


def test_a_single_something_between_construction_is_allowed():
    body = ("He was something between a game show host and a Greek chorus.\n\n"
            "[PHOTO: a.jpg | Joseph Medeiros at Greenwich House Theater mid-gesture "
            "with one arm raised and warm light behind him]\n\nMore prose.\n")

    assert "repeated_construction" not in codes(check_blog(body, program=PROGRAM, venue=VENUE))


# ── 4. photo placement ────────────────────────────────────────────────────────

def test_two_markers_with_no_prose_between_them_is_reported():
    alt_a = ("Joseph Medeiros at Greenwich House Theater mid-gesture with one arm "
             "raised and warm light behind him")
    alt_b = ("Suitcase and props at Greenwich House Theater with Joseph Medeiros "
             "crouched behind them in low light")
    body = f"Some prose.\n\n[PHOTO: a.jpg | {alt_a}]\n\n[PHOTO: b.jpg | {alt_b}]\n\nMore.\n"

    assert "stacked_photos" in codes(check_blog(body, program=PROGRAM, venue=VENUE))


def test_a_first_marker_after_more_than_two_paragraphs_is_reported():
    alt = ("Joseph Medeiros at Greenwich House Theater mid-gesture with one arm "
           "raised and warm light behind him")
    body = "One.\n\nTwo.\n\nThree.\n\nFour.\n\n" + f"[PHOTO: a.jpg | {alt}]\n\nMore.\n"

    assert "late_first_photo" in codes(check_blog(body, program=PROGRAM, venue=VENUE))


# ── the findings have to be usable ────────────────────────────────────────────

# ── 24. no demographic grouping of performers ─────────────────────────────────


@pytest.mark.parametrize("phrase", [
    "The female performers in the cast, Ladibree and Safa, held the chorus.",
    "The male singers carried the low end.",
    "The women in the cast traded the verse between them.",
    "Ladibree, Safa, and the others took the second verse.",
])
def test_grouping_performers_by_demographic_is_reported(phrase):
    """Rule 24: name everyone or name no one. Real failures from the
    BLUDLINE draft, which wrote 'The female performers in the cast,
    Ladibree, Safa, and the others'."""
    body = (f"{phrase}\n\n"
            "[PHOTO: a.jpg | Joseph Medeiros at Greenwich House Theater "
            "mid-gesture with one arm raised and warm light from the side]\n")
    assert "demographic_grouping" in codes(check_blog(body, program=PROGRAM, venue=VENUE))


def test_naming_every_performer_is_allowed():
    body = ("Ladibree and Safa traded the second verse between them.\n\n"
            "[PHOTO: a.jpg | Joseph Medeiros at Greenwich House Theater "
            "mid-gesture with one arm raised and warm light from the side]\n")
    assert "demographic_grouping" not in codes(check_blog(body, program=PROGRAM, venue=VENUE))


# ── 29. alt text names people, never appearance or gender ─────────────────────


@pytest.mark.parametrize("opening", [
    "A woman in a striped top",
    "A bearded performer in a white shirt",
    "A male performer",
    "A young man",
])
def test_alt_text_identifying_someone_by_appearance_is_reported(opening):
    """Rule 29: 'A woman in a striped top' becomes 'Safa'. Reported even when
    a performer is also named, so the descriptor itself is caught."""
    body = ("The set was already in place when I got there.\n\n"
            f"[PHOTO: a.jpg | {opening} beside Joseph Medeiros at Greenwich "
            "House Theater, one arm raised toward the back wall]\n")
    assert "alt_text_appearance_descriptor" in codes(
        check_blog(body, program=PROGRAM, venue=VENUE))


def test_alt_text_naming_the_person_is_allowed():
    assert "alt_text_appearance_descriptor" not in codes(
        check_blog(_clean_body(), program=PROGRAM, venue=VENUE))


def test_every_finding_names_the_rule_and_quotes_the_offending_text():
    long_alt = " ".join(["word"] * 30)
    body = (f"He had thirty seconds.\n\n[PHOTO: a.jpg | {long_alt}]\n\n"
            f"[PHOTO: b.jpg | {long_alt}]\n\nEnd.\n")

    for f in check_blog(body, program=PROGRAM, venue=VENUE):
        assert f.code and f.message, "a finding with no rule name is not actionable"
        assert f.detail, f"{f.code} quotes nothing, so Dan cannot find what to fix"
