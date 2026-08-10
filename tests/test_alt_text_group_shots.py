"""#227: what alt text says when a group is too big to name everyone.

Two alt text rules were in genuine tension. One says name people by name rather
than by appearance; the other caps alt text at 15 to 25 words. A frame holding
eight performers cannot satisfy both, so Dan's own corrected BLUDLINE post wrote
"Four BLUDLINE performers at mic stands" and the check fired on a post he
considered finished.

Dan's decision (2026-08-09): a group too big to name gets a COUNT plus the
ensemble name. So that form is now correct output and the check has to accept
it, while everything it was written to catch still fails.

The count has to be a real one. "Several women in black" is the same defect the
rule exists to prevent, just at a larger scale, so a vague quantifier does not
buy an exemption from naming people.
"""

from __future__ import annotations

import pytest

from postroll.ai.blog_quality import check_blog


PROGRAM = {"performers": [{"name": "Safa"}, {"name": "Fermin Suero, Jr."}]}
VENUE = "Greenwich House Theater"


def _body(alt: str) -> str:
    return f"A paragraph of the post.\n\n[PHOTO: 001.jpg | {alt}]\n\nAnother paragraph.\n"


def codes(alt: str) -> list[str]:
    return [f.code for f in check_blog(_body(alt), program=PROGRAM, venue=VENUE)]


# ── the form Dan chose ────────────────────────────────────────────────────────

def test_a_count_plus_the_ensemble_name_is_accepted():
    assert "alt_text_missing_performer" not in codes(
        "Four BLUDLINE performers at mic stands at Greenwich House Theater")


@pytest.mark.parametrize("alt", [
    "Eight BLUDLINE singers on the risers at Greenwich House Theater",
    "Twelve Greenwich House dancers mid-phrase at Greenwich House Theater",
    "6 BLUDLINE musicians under blue light at Greenwich House Theater",
])
def test_the_form_is_recognised_however_the_count_is_written(alt):
    assert "alt_text_missing_performer" not in codes(alt)


def test_naming_one_person_still_passes_as_it_always_did():
    assert "alt_text_missing_performer" not in codes(
        "Safa at the mic stand under blue light at Greenwich House Theater")


# ── what must still fail ──────────────────────────────────────────────────────

def test_appearance_instead_of_a_name_still_fails():
    # The defect the rule exists for. Nothing about the group decision should
    # make this acceptable.
    assert "alt_text_missing_performer" in codes(
        "A male performer in a striped top at the mic at Greenwich House Theater")


@pytest.mark.parametrize("alt", [
    "Several women in black on the risers at Greenwich House Theater",
    "A group of performers at mic stands at Greenwich House Theater",
    "Many musicians under blue light at Greenwich House Theater",
])
def test_a_vague_quantifier_does_not_buy_an_exemption(alt):
    # "Count them, do not guess." A hedge like "several" is the same failure to
    # look at the photograph that "a male performer" is.
    assert "alt_text_missing_performer" in codes(alt)


def test_a_count_without_the_ensemble_named_still_fails():
    # "Four performers at mic stands" credits nobody at all. The ensemble name
    # is the part that does the crediting once individuals cannot fit.
    assert "alt_text_missing_performer" in codes(
        "Four performers at mic stands under blue light at Greenwich House Theater")


def test_the_group_form_does_not_exempt_the_other_alt_text_rules():
    # It is an exemption from naming individuals, nothing more. A 40-word group
    # credit is still too long, and an inferred inner state is still inferred.
    long_group = ("Four BLUDLINE performers at mic stands at Greenwich House Theater "
                  + "under a wash of blue light " * 4)
    assert "alt_text_length" in codes(long_group)
    assert "alt_text_inferred_state" in codes(
        "Four BLUDLINE performers at mic stands in intense concentration "
        "at Greenwich House Theater")
