"""#476: the revision path runs the same backstops generation does.

`generate_caption` finishes a caption with three deterministic passes: em dash
stripping, the engagement-bait and second-person ban enforcement (#110), and
the credit-stack dedupe (#188, #191). `revise_caption` ran only the first, so a
friendly-feedback revision was a live route back into the caption with two of
the three gates missing. "Add a call to action" is exactly the kind of request
that reintroduces what those gates exist to remove.

Two related losses on the same path, both L27 in shape:

  * the fame exemption was structurally dead. `strip_performer_hashtags` keeps
    a genuinely famous performer's hashtag when the model lists them in
    `famous_people`, and the revise prompt's output shape asked for `caption`
    and `hashtags` only, so the field was ALWAYS absent and every revision
    stripped that hashtag. Same field-loss shape as #202;
  * the gate also lost the `name_mentions`, `photo_tags` and `tag_handles`
    inputs it has at generation time, because the revision manifest never
    carried them, so it was judging against the program alone.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import revise_caption as rc


PROGRAM = {
    "performers": [
        {"id": "1", "name": "Jane Smith", "role": "soloist"},
        {"id": "2", "name": "Yo-Yo Ma", "role": "soloist"},
    ],
    "pieces": [],
}


def _revise(returned, *, feedback="make it shorter", tag_handles=None,
            name_mentions=None, photo_tags=None, rewrite=None):
    """Run a revision with the model's answer stubbed out."""
    with patch("postroll.ai.revise_caption.run_json_prompt",
               side_effect=lambda p, **k: returned), \
         patch("postroll.ai.generate_captions.run_prompt",
               side_effect=lambda p, **k: rewrite):
        return rc.revise_caption(
            event="E", org="O", venue="V", date="2026-04-05", day="sunday",
            program=PROGRAM,
            existing={"caption": "old caption", "hashtags": ["#dwphotony"],
                      "alt_texts": ["a"], "scene_labels": [None]},
            feedback=feedback,
            tag_handles=tag_handles, name_mentions=name_mentions,
            photo_tags=photo_tags,
            skip_humanizer=True)


# ── the two backstops that were missing ───────────────────────────────────────

def test_a_revision_that_reintroduces_engagement_bait_is_rewritten():
    result = _revise({"caption": "Full set from Saturday. Link in bio.",
                      "hashtags": ["#dwphotony"]},
                     feedback="add a call to action",
                     rewrite="Full set from Saturday.")

    assert "link in bio" not in result["caption"].lower()


def test_a_revision_that_doubles_a_credit_is_deduped():
    # The body already credits @dciny, so the trailing stack must not credit
    # it again (#188).
    revised = "@dciny at the hall.\n\nwith @dciny @lincolncenter"

    result = _revise({"caption": revised, "hashtags": []},
                     tag_handles=["@dciny", "@lincolncenter"])

    assert result["caption"].count("@dciny") == 1
    assert "@lincolncenter" in result["caption"]


def test_a_clean_revision_is_left_alone():
    result = _revise({"caption": "A quiet night at @lincolncenter.",
                      "hashtags": ["#dwphotony"]},
                     tag_handles=["@lincolncenter"])

    assert result["caption"] == "A quiet night at @lincolncenter."


# ── the fame exemption is reachable again ─────────────────────────────────────

def test_the_revise_prompt_asks_for_famous_people():
    # Without the field in the requested output shape the model never returns
    # it, so the exemption below can never fire. A prompt that does not ask is
    # the whole defect.
    assert "famous_people" in rc.REVISE_PROMPT


def test_a_famous_performers_hashtag_survives_a_revision():
    result = _revise({"caption": "Bach at the hall.",
                      "hashtags": ["#dwphotony", "#yoyoma"],
                      "famous_people": ["Yo-Yo Ma"]})

    assert "#yoyoma" in result["hashtags"]


def test_an_ordinary_performers_hashtag_is_still_stripped():
    result = _revise({"caption": "Bach at the hall.",
                      "hashtags": ["#dwphotony", "#janesmith"],
                      "famous_people": []})

    assert "#janesmith" not in result["hashtags"]


# ── the gate gets the inputs it has at generation time ────────────────────────

def test_a_name_mention_is_gated_out_of_the_hashtags():
    # Someone credited by plain name in the caption is a person on the stage,
    # so their name is not a hashtag. The gate could not know that while the
    # manifest withheld name_mentions.
    result = _revise({"caption": "With Jordan Langworthy.",
                      "hashtags": ["#dwphotony", "#jordanlangworthy"]},
                     name_mentions=["Jordan Langworthy"])

    assert "#jordanlangworthy" not in result["hashtags"]


def test_a_photo_tagged_person_is_gated_out_of_the_hashtags():
    result = _revise({"caption": "A quiet night.",
                      "hashtags": ["#dwphotony", "#marylopez"]},
                     photo_tags={"/tmp/a.jpg": ["Mary Lopez"]})

    assert "#marylopez" not in result["hashtags"]


# ── the credit checks run here too (#475) ─────────────────────────────────────

def test_a_revision_that_invents_a_handle_is_reported():
    result = _revise({"caption": "At @lincolncenter with @strangerhandle.",
                      "hashtags": []},
                     tag_handles=["@lincolncenter"])

    assert [f["code"] for f in result["findings"]] == ["caption_foreign_handle"]
    assert result["findings_caption"] == result["caption"]


def test_a_revision_that_drops_a_required_credit_is_reported():
    result = _revise({"caption": "A quiet night.", "hashtags": []},
                     tag_handles=["@dciny"])

    assert [f["code"] for f in result["findings"]] == ["caption_missing_credit"]


def test_a_clean_revision_carries_no_findings():
    result = _revise({"caption": "At @lincolncenter.", "hashtags": []},
                     tag_handles=["@lincolncenter"])

    assert result["findings"] == []


# ── the locked fields stay locked ─────────────────────────────────────────────

@pytest.mark.parametrize("key,expected", [("alt_texts", ["a"]),
                                          ("scene_labels", [None])])
def test_photo_derived_fields_are_unchanged(key, expected):
    result = _revise({"caption": "New.", "hashtags": []})

    assert result[key] == expected
