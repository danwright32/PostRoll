"""#475: the two hardest handle rules are checked in code, not just asked for.

The caption prompt carries both rules and neither had a boundary check:

  1. every handle in `tag_handles` and every name in `name_mentions` MUST
     appear in the finished caption, or a credit Dan promised somebody is
     silently missing;
  2. no @ handle may appear that was not offered, because a guessed handle
     tags a stranger's account.

Both are exactly checkable against the lists the caller already holds, so a
regex settles them rather than the model being asked whether it obeyed (the
standing deterministic-enforcement rule, and L27).

The two paths need different answers, which is why they are tested separately
below. On the GENERATE and REVISE paths there is nothing to fall back to, so
the checks REPORT, the same shape blog_quality settled on: nobody can supply
the handle that should have been there, and inventing one is the exact failure
the rule exists to stop. On the ban-REWRITE path there IS a known-good
original, so a rewrite that drops a required credit or invents a handle is
REFUSED and the original kept, the way an empty rewrite already is (L5).
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai.caption_credits import (
    credit_findings,
    foreign_handles,
    missing_credits,
)


# ── handles that were never offered ───────────────────────────────────────────

def test_a_handle_that_was_never_offered_is_caught():
    # The dangerous one: @strangerhandle is somebody's real account.
    found = foreign_handles(
        "Vocal Colors at @lincolncenter with @strangerhandle.",
        tag_handles=["@dciny", "@lincolncenter"],
    )

    assert found == ["@strangerhandle"]


def test_offered_handles_are_not_reported():
    assert foreign_handles(
        "@dciny at @lincolncenter.", tag_handles=["@dciny", "@lincolncenter"]
    ) == []


def test_an_offered_handle_still_matches_written_mid_sentence():
    # A dot is legal inside a handle but never ends one, so "@safa.wav." in
    # prose has to match "@safa.wav" standing alone in the list.
    assert foreign_handles("Set by @safa.wav.", tag_handles=["@safa.wav"]) == []


def test_handle_matching_ignores_case_and_a_missing_at_sign():
    # The handle book stores some entries without the @, and Instagram handles
    # are case insensitive. Neither difference is a fabricated handle.
    assert foreign_handles("@DCINY at @lincolncenter.",
                           tag_handles=["dciny", "@LincolnCenter"]) == []


def test_a_foreign_handle_is_reported_once_however_often_it_appears():
    found = foreign_handles("@ghost and again @ghost.", tag_handles=[])

    assert found == ["@ghost"]


def test_no_offered_handles_means_every_handle_is_foreign():
    # tag_handles "(none)" is exactly when the prompt forbids inventing one.
    assert foreign_handles("With @anyone.", tag_handles=None) == ["@anyone"]


# ── credits that were required and did not survive ────────────────────────────

def test_a_required_handle_missing_from_the_caption_is_caught():
    assert missing_credits("Vocal Colors at Lincoln Center.",
                           tag_handles=["@dciny"]) == ["@dciny"]


def test_a_required_plain_name_missing_from_the_caption_is_caught():
    assert missing_credits("Sorenson Requiem at @lincolncenter.",
                           tag_handles=["@lincolncenter"],
                           name_mentions=["Jordan Langworthy"]) == ["Jordan Langworthy"]


def test_credits_that_are_all_present_report_nothing():
    assert missing_credits(
        "@dciny's Vocal Colors at @lincolncenter, conducted by Jordan Langworthy.",
        tag_handles=["@dciny", "@lincolncenter"],
        name_mentions=["Jordan Langworthy"],
    ) == []


def test_a_present_credit_is_matched_regardless_of_case():
    assert missing_credits("vocal colors, conducted by jordan langworthy.",
                           name_mentions=["Jordan Langworthy"]) == []


# ── findings, in the shape the app already decodes ────────────────────────────

def test_findings_name_the_handle_that_was_invented():
    findings = credit_findings(
        "At @lincolncenter with @strangerhandle.",
        tag_handles=["@lincolncenter"],
    )

    assert [f.code for f in findings] == ["caption_foreign_handle"]
    assert "@strangerhandle" in findings[0].detail


def test_findings_name_the_credit_that_went_missing():
    findings = credit_findings("A quiet night.", tag_handles=["@dciny"])

    assert [f.code for f in findings] == ["caption_missing_credit"]
    assert "@dciny" in findings[0].detail


def test_a_clean_caption_produces_no_findings():
    assert credit_findings("@dciny at @lincolncenter.",
                           tag_handles=["@dciny", "@lincolncenter"]) == []


# ── a tag list entry that cannot be a handle (#899) ───────────────────────────
#
# Reproduced exactly against the stored data, read only: a performer row
# carrying its company's display name in the handle field put "@DPR Dance" into
# the caption, and this file read that as two separate defects, neither of them
# the real one.
#
#     Finding(caption_foreign_handle, '@dpr')
#     Finding(caption_missing_credit, '@dpr dance')
#
# The first accuses the model of tagging a stranger it never chose, because
# HANDLE_RE cannot match a value containing a space and takes the fragment
# before it. The second can never clear, because "@dpr dance" cannot appear in
# a caption in a form this file recognises, so it is reported forever.
#
# The value is fixed at the writers now, but this is the backstop for one that
# is already stored: it is a finding ABOUT the tag list, said once, and it must
# not become an accusation about the caption.


def test_a_tag_list_entry_that_cannot_be_a_handle_is_a_finding_about_the_list():
    findings = credit_findings("A night with @dpr dance.",
                               tag_handles=["@DPR Dance"])

    assert [f.code for f in findings] == ["caption_tag_list_not_a_handle"]
    assert "DPR Dance" in findings[0].detail


def test_it_is_not_reported_as_a_credit_that_went_missing():
    """It can never be found, so it would be reported on every future run."""
    codes = [f.code for f in credit_findings("A quiet night.",
                                             tag_handles=["@DPR Dance"])]

    assert "caption_missing_credit" not in codes, (
        "a tag list entry that cannot appear in a caption at all is reported "
        "as absent from every caption ever written")


def test_the_fragment_before_the_space_is_not_called_a_stranger():
    """The accusation the pipeline earned itself.

    `@DPR Dance` in the caption reads to HANDLE_RE as `@dpr`, which was never
    offered, so the caption is accused of tagging an account the model did not
    choose and the pipeline supplied.
    """
    codes = [f.code for f in credit_findings("A night with @DPR Dance.",
                                             tag_handles=["@DPR Dance"])]

    assert "caption_foreign_handle" not in codes, (
        "the caption is accused of inventing a handle that the tag list "
        "handed it")


def test_a_real_stranger_is_still_reported_beside_a_malformed_entry():
    """The positive control. Suppressing the fragment must not suppress the
    check: a file that stopped reporting strangers altogether would satisfy
    the three above (L159)."""
    codes = [f.code for f in credit_findings(
        "A night with @DPR Dance and @strangerhandle.",
        tag_handles=["@DPR Dance"])]

    assert "caption_foreign_handle" in codes
    assert "caption_tag_list_not_a_handle" in codes


def test_a_well_formed_entry_beside_a_malformed_one_is_still_required():
    codes = [f.code for f in credit_findings("A quiet night.",
                                             tag_handles=["@DPR Dance", "@dciny"])]

    assert "caption_missing_credit" in codes
    assert "caption_tag_list_not_a_handle" in codes


def test_a_sentinel_is_not_mistaken_for_a_malformed_entry():
    """`unknown` is shaped like a handle. That it is a sentinel is a separate
    question, answered before a tag list is built, and this file must not
    start answering it too (L118)."""
    codes = [f.code for f in credit_findings("@unknown was there.",
                                             tag_handles=["@unknown"])]

    assert "caption_tag_list_not_a_handle" not in codes


# ── the generate path reports what it found ───────────────────────────────────

@pytest.fixture
def photo(tmp_path):
    from PIL import Image
    p = tmp_path / "a.jpg"
    Image.new("RGB", (120, 90), (40, 60, 80)).save(p)
    return p


def _generate(fake_caption, photo, *, tag_handles=None, name_mentions=None,
              rewrite=None):
    from postroll.ai import generate_captions

    #: A realistic alt text, not a placeholder. This file is about CREDIT
    #: findings, and its stub used to return "a", which was invisible until
    #: #1068 gave alt text its own rules and a one word description became a
    #: real finding. A fixture standing in for something no rule read is fine
    #: until a rule reads it, and then it makes an unrelated test fail for a
    #: reason that has nothing to do with what it checks.
    ALT = ("A conductor leads roughly twenty singers in all black across the "
           "stage with a piano at the left and red lighting behind them")

    def fake_run_json(prompt, **kw):
        return {"caption": fake_caption, "hashtags": [],
                "alt_texts": [ALT], "scene_labels": [None]}

    with patch("postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.generate_captions.run_prompt",
               side_effect=lambda p, **k: rewrite):
        return generate_captions.generate_caption(
            event="E", org="O", venue="V", date="2026-04-05", day="sunday",
            photo_paths=[photo], program={"performers": [], "pieces": []},
            tag_handles=tag_handles, name_mentions=name_mentions,
            skip_humanizer=True, skip_voice_pass=True)


def test_generation_reports_an_invented_handle(photo):
    result = _generate("At @lincolncenter with @strangerhandle.", photo,
                       tag_handles=["@lincolncenter"])

    codes = [f["code"] for f in result["findings"]]
    assert "caption_foreign_handle" in codes


def test_generation_reports_a_dropped_credit(photo):
    result = _generate("A quiet night at the hall.", photo,
                       tag_handles=["@dciny"])

    codes = [f["code"] for f in result["findings"]]
    assert "caption_missing_credit" in codes


def test_a_clean_generated_caption_carries_no_findings(photo):
    result = _generate("@dciny at @lincolncenter.", photo,
                       tag_handles=["@dciny", "@lincolncenter"])

    assert result["findings"] == []


def test_the_findings_pin_the_caption_they_describe(photo):
    # Same reason BlogOutput pins findings_body: an edited caption must not
    # keep showing findings measured against the text before the edit.
    result = _generate("A quiet night at the hall.", photo, tag_handles=["@dciny"])

    assert result["findings_caption"] == result["caption"]


# ── the ban rewrite refuses to lose a credit ──────────────────────────────────

def test_a_rewrite_that_drops_a_required_handle_is_refused(photo, capsys):
    # The rewrite exists to remove engagement bait. Removing a credit while it
    # is in there is a silent deletion of somebody Dan promised to tag, and the
    # original caption is right there to keep (L5).
    original = "Full set from Saturday with @dciny. Link in bio."

    result = _generate(original, photo, tag_handles=["@dciny"],
                       rewrite="Full set from Saturday.")

    assert result["caption"] == original
    assert "credit" in capsys.readouterr().err.lower()


def test_a_rewrite_that_invents_a_handle_is_refused(photo):
    original = "Full set from Saturday with @dciny. Link in bio."

    result = _generate(original, photo, tag_handles=["@dciny"],
                       rewrite="Full set from Saturday with @dciny @strangerhandle.")

    assert result["caption"] == original


def test_a_rewrite_that_keeps_every_credit_is_accepted(photo):
    result = _generate("Full set from Saturday with @dciny. Link in bio.", photo,
                       tag_handles=["@dciny"],
                       rewrite="Full set from Saturday with @dciny.")

    assert result["caption"] == "Full set from Saturday with @dciny."
