"""`scene_labels` is restored with `alt_texts`, not left where a pass put it
(#1220).

The two are parallel lists. The caption prompt asks for the labels "IN THE SAME
ORDER and at the SAME LENGTH as alt_texts", and the normalisation keeps them in
step: both are trimmed to one entry for single alt post types, and both have
holes reinserted for skipped photographs.

#1214 restores `alt_texts` from the draft after the review passes and leaves
`scene_labels` as the passes left them. So a pass that reorders or drops a
label now leaves the two lists disagreeing about which photograph is which,
where before they were at least wrong together. The argument for holding one
out of the rewrite applies unchanged to the other.

## No visible symptom today, which is why it is worth doing now

Nothing in the app reads `scene_labels`. `GeneratedOutput` decodes them and a
contract test round trips them; no view, service or exporter touches them.
Their real reader is the model itself, in stage 3 of the same prompt, which has
already run by the time the review passes happen.

So this is a latent inconsistency waiting for its first reader, and the moment
to remove one is before anything depends on it rather than after (L46, L204).

## One finding, not two

Drift in the labels folds into the existing `alt_text_rewritten_by_review`
detail rather than getting a code of its own. Two codes for one pass ignoring
one instruction is two headings for one fault (L11 is about telling DIFFERENT
causes apart, and this is the same cause).
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import generate_captions as gc

DRAFT = {
    "caption": "A photo scroll through the festival.",
    "hashtags": ["#dwphotony"],
    "alt_texts": [
        "A photo scroll through Battery Dance Festival at Rockefeller Park, "
        "covering the evening's companies from the opening solo to the finale.",
        "A second description of the same evening at Rockefeller Park, running "
        "from the interval through to the final company on the programme.",
    ],
    "scene_labels": ["opening solo", "finale"],
}


def run(replies, **kwargs):
    """One generation where the draft and each review pass answer in turn.

    `run_review_pass` is left REAL, so this exercises the merge the passes
    actually do rather than a stand-in for it.
    """
    answers = list(replies)

    def stub(prompt, **_):
        return dict(answers.pop(0)) if answers else dict(replies[-1])

    with patch.object(gc, "run_json_prompt", side_effect=stub):
        return gc.generate_caption(
            event="Battery Dance Festival", org="Battery Dance",
            venue="Rockefeller Park", date="2026-08-15", day="wednesday",
            program={"performers": [], "pieces": []},
            skip_humanizer=True, skip_voice_pass=False, **kwargs)


@pytest.fixture
def two_photos(sample_photo, sample_photo_dark):
    return [sample_photo, sample_photo_dark]


def test_a_pass_that_reorders_the_labels_does_not_ship_them(two_photos):
    """The fault this is about: the alt texts are restored, so a reordered
    label list now points at photographs the alt texts do not."""
    swapped = dict(DRAFT, scene_labels=["finale", "opening solo"])

    result = run([DRAFT, swapped], photo_paths=two_photos,
                 post_type="carousel_photo")

    assert result["scene_labels"] == DRAFT["scene_labels"], (
        f"a review pass reordered the scene labels and they shipped, so the "
        f"two parallel lists disagree about which photograph is which: "
        f"{result['scene_labels']}")


def test_a_pass_that_drops_a_label_does_not_ship_the_short_list(two_photos):
    result = run([DRAFT, dict(DRAFT, scene_labels=["opening solo"])],
                 photo_paths=two_photos, post_type="carousel_photo")

    assert result["scene_labels"] == DRAFT["scene_labels"], (
        f"a review pass dropped a scene label and the short list shipped, so "
        f"every later label sits against the wrong photograph: "
        f"{result['scene_labels']}")


def test_restoring_the_alt_texts_restores_the_labels_with_them(two_photos):
    """The two are parallel, so putting one back and not the other is how they
    come to disagree. A pass that broke the alt texts' shape says nothing
    about whether it also moved the labels, and the draft is known good."""
    broken = dict(DRAFT, alt_texts=list(reversed(DRAFT["alt_texts"])),
                  scene_labels=["finale", "opening solo"])

    result = run([DRAFT, broken], photo_paths=two_photos,
                 post_type="carousel_photo")

    assert result["alt_texts"] == DRAFT["alt_texts"]
    assert result["scene_labels"] == DRAFT["scene_labels"], (
        "the alt texts were restored and the labels were not, which is the "
        "state that leaves the two lists disagreeing")


def test_the_drift_is_reported_under_the_existing_code(two_photos):
    """Putting the labels back destroys the evidence a pass ignored the
    instruction (L340), and it folds into the code that already exists rather
    than getting one of its own."""
    result = run([DRAFT, dict(DRAFT, scene_labels=["finale", "opening solo"])],
                 photo_paths=two_photos, post_type="carousel_photo")

    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_rewritten_by_review" in codes, (
        f"a pass reordered the scene labels with nothing saying so, so a pass "
        f"that ignores the instruction looks identical to one that obeys it: "
        f"{result['findings']}")
    assert codes.count("alt_text_rewritten_by_review") == 1, (
        "one pass ignoring one instruction produced more than one finding")


def test_labels_a_pass_left_alone_are_not_reported(two_photos):
    """The control. A check that fired on every post would pass every test
    above, and a finding on every tidied post is a panel that gets skimmed
    (L36, L104)."""
    result = run([DRAFT, DRAFT], photo_paths=two_photos,
                 post_type="carousel_photo")

    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_rewritten_by_review" not in codes, (
        f"a pass that changed nothing was reported as having rewritten the "
        f"alt text: {result['findings']}")
    assert result["scene_labels"] == DRAFT["scene_labels"]
