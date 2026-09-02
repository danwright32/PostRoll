"""#1067: a reel's alt text must be about the reel, not about one frame of it.

The Thursday scroll reel is a video built from every photo of the event, often
50 to 200 of them, and it ships one alt text. Measured across all 21 events in
the live store, 12 of 21 Thursday alt texts describe a single moment rather than
the reel, and 7 are under the 25 word floor the reel instruction itself sets.
Battery Dance Festival shipped "Four dancers performing on an outdoor stage at
night, lit in blue and pink, with New York Harbor visible behind them", which is
one frame, so a screen reader user is told a 234 photo reel is a picture of four
dancers.

Alt text is the entire content of the post for a screen reader user, and this is
the one defect class nobody sighted catches in review: the sentence is well
written and true of one photograph, so it reads as correct.

Three of the four causes are here.

**The prompt was told the reel is 4 photos.** `generate_week` swaps Thursday's
full photo list for Wednesday's four caption context photos, which is the right
call for cost and request size, and the header then said "a post containing 4
photo(s)". Nothing told the model the reel actually holds 60, or that the four
it can see are a sample.

**The template's own header contradicted the reel rule.** It said, for every
post type, "The alt text is per-photo", and the scroll reel instruction three
paragraphs later says the opposite. A rule stated once is outweighed by
surrounding prose that breaks it, and here the contradicting prose was in the
same prompt (L270).

**The collapse to one entry was silent.** `alt_texts[:1]` for every single alt
post type. If the model wrote one alt per photo anyway, the shipped alt is photo
one's: a single photo description, correctly formed, indistinguishable from a
compliant reel level alt. That is the detection of a prompt violation being
thrown away at the moment it is made (L340).

**The voice and humanizer passes rewrote it with no idea what a reel is.**
Passes 2 and 3 hand the whole draft back to the model, carrying the humanizer
rules, the brand voice and a one line output shape, and neither carries the post
type. So a compliant reel level alt could be condensed back into a single frame
description by a later stage, while the stage that enforced the rule had already
run (L280). The draft's alt text is now put back afterwards, and the rewrite is
reported rather than only undone.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import generate_captions as gc


def _capture(fake, **kwargs):
    """Run one caption generation with the model stubbed, returning
    (the prompt it was given, the result)."""
    seen = {}

    def stub(prompt, **_):
        seen["prompt"] = prompt
        return dict(fake)

    with patch.object(gc, "run_json_prompt", side_effect=stub), \
         patch.object(gc, "run_review_pass",
                      side_effect=lambda *a, **k: (_ for _ in ()).throw(
                          AssertionError("a review pass ran; stub it"))):
        result = gc.generate_caption(
            event="Battery Dance Festival", org="Battery Dance", venue="Rockefeller Park",
            date="2026-08-15", day="thursday",
            program={"performers": [], "pieces": []},
            skip_humanizer=True, skip_voice_pass=True, **kwargs)
    return seen["prompt"], result


COMPLIANT = {
    "caption": "A photo scroll through the festival.",
    "hashtags": ["#dwphotony"],
    "alt_texts": ["A photo scroll through Battery Dance Festival at Rockefeller Park, "
                  "covering the evening's companies from the opening solo to the finale."],
    "scene_labels": [None],
}

PER_FRAME = dict(COMPLIANT, alt_texts=[
    "Four dancers on an outdoor stage at night, lit in blue and pink.",
    "A soloist mid leap against the harbour.",
    "The company bowing in a line.",
])


# -- the prompt is told what the post actually holds --------------------------

def test_the_prompt_says_how_many_photos_the_REEL_holds(sample_photo):
    prompt, _ = _capture(COMPLIANT, photo_paths=[sample_photo],
                         post_type="scroll_reel", post_photo_count=234)
    assert "234" in prompt, "the prompt never mentions the size of the reel"


#: The word that only the sampled wording uses.
#:
#: Deliberately not "sample": the shared photo fixture is called `sample.jpg`
#: and its filename is printed in the photo list, so every one of these
#: assertions passed on the filename rather than on the wording (L156). Caught
#: by the two negative cases, which is what negative cases are for.
SAMPLED = "representative"


def test_the_attached_photos_are_labelled_as_a_sample(sample_photo):
    # Not merely the count. The photo list block named the four files under
    # "Photos in this post", which reads as the whole post.
    prompt, _ = _capture(COMPLIANT, photo_paths=[sample_photo],
                         post_type="scroll_reel", post_photo_count=234)
    assert SAMPLED in prompt.lower(), prompt[:400]


def test_an_ordinary_post_is_not_told_it_is_a_sample(sample_photo):
    # The positive control. Without it every assertion above is satisfied by a
    # prompt that calls every post a sample of something (L159).
    prompt, _ = _capture(COMPLIANT, photo_paths=[sample_photo], post_type="feed_photo")
    assert SAMPLED not in prompt.lower()
    assert "1 photo(s)" in prompt


def test_a_post_whose_whole_set_is_attached_is_not_called_a_sample(sample_photo):
    # post_photo_count equal to what was sent is not a sample either, and this
    # is the shape a single day retry takes.
    prompt, _ = _capture(COMPLIANT, photo_paths=[sample_photo],
                         post_type="scroll_reel", post_photo_count=1)
    assert SAMPLED not in prompt.lower()


# -- and stops contradicting the reel rule ------------------------------------

def test_a_reel_is_not_told_its_alt_text_is_per_photo(sample_photo):
    prompt, _ = _capture(COMPLIANT, photo_paths=[sample_photo],
                         post_type="scroll_reel", post_photo_count=234)
    assert "The alt text is per-photo" not in prompt, (
        "the header still tells a reel its alt text is per photo, which is what "
        "the reel instruction three paragraphs later forbids")


def test_a_carousel_is_still_told_its_alt_text_is_per_photo(sample_photo):
    # The other half. Carousels genuinely do take one alt per photograph, and
    # removing the sentence for everybody would break them (L178).
    prompt, _ = _capture(COMPLIANT, photo_paths=[sample_photo],
                         post_type="collage_carousel")
    assert "The alt text is per-photo" in prompt


# -- and a violation is reported rather than trimmed away ---------------------

def test_per_frame_alt_text_on_a_reel_is_reported(sample_photo):
    _, result = _capture(PER_FRAME, photo_paths=[sample_photo],
                         post_type="scroll_reel", post_photo_count=234)
    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_per_frame" in codes, (
        "the model wrote one alt per frame and the trim swallowed it, so what "
        "ships is one photograph's description wearing a reel's clothes")


def test_the_report_says_what_shipped(sample_photo):
    _, result = _capture(PER_FRAME, photo_paths=[sample_photo],
                         post_type="scroll_reel", post_photo_count=234)
    finding = next(f for f in result["findings"] if f["code"] == "alt_text_per_frame")
    assert "3" in finding["detail"], finding["detail"]
    assert "Four dancers" in finding["detail"], (
        "the report does not quote the alt text that actually shipped, so it "
        "cannot be told from a compliant one by reading it")


def test_the_trim_still_happens(sample_photo):
    # Reporting it is not a reason to ship a list: everything downstream takes
    # entry 0, so a list would mean whichever came first ships anyway, with the
    # rest stored and invisible.
    _, result = _capture(PER_FRAME, photo_paths=[sample_photo],
                         post_type="scroll_reel", post_photo_count=234)
    assert len(result["alt_texts"]) == 1


def test_a_compliant_reel_is_not_reported(sample_photo):
    # The positive control for the two above: one alt text for the reel raises
    # nothing, or the panel cries wolf on every correct post (L36).
    _, result = _capture(COMPLIANT, photo_paths=[sample_photo],
                         post_type="scroll_reel", post_photo_count=234)
    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_per_frame" not in codes


def test_a_carousel_with_one_alt_per_photo_is_not_reported(sample_photo):
    # A carousel is SUPPOSED to carry one per photo, so the rule must be about
    # the post type rather than about the number of entries.
    _, result = _capture(PER_FRAME, photo_paths=[sample_photo],
                         post_type="collage_carousel")
    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_per_frame" not in codes


# -- the fourth cause: the review passes rewrite what they were never told ----
#
# Passes 2 and 3 hand the whole draft JSON back to the model to rewrite,
# carrying the humanizer rules, the brand voice and a one line output shape.
# Neither carries the post type or the reel alt rule, and neither had a
# validator, so a compliant reel level alt could be condensed back into a
# single frame description by a later stage while the stage that enforced the
# rule had already run (L280).
#
# The rule is made structural rather than better worded: for a post type that
# takes ONE post level alt, the alt text the draft pass produced is put back
# verbatim afterwards. A rule that lives only in a prompt is a hope (L27), and
# these passes are not asked to touch alt text at all.

ONE_FRAME = "Four dancers on an outdoor stage at night, lit in blue and pink."


def _capture_through_passes(replies, **kwargs):
    """Run one generation where the draft and the review passes each answer.

    `run_review_pass` is left REAL and calls the module's own
    `run_json_prompt`, so this exercises the merge the passes actually do
    rather than a stand-in for it.
    """
    answers = list(replies)

    def stub(prompt, **_):
        return dict(answers.pop(0)) if answers else dict(replies[-1])

    with patch.object(gc, "run_json_prompt", side_effect=stub):
        return gc.generate_caption(
            event="Battery Dance Festival", org="Battery Dance",
            venue="Rockefeller Park", date="2026-08-15", day="thursday",
            program={"performers": [], "pieces": []},
            skip_humanizer=True, skip_voice_pass=False, **kwargs)


def test_the_voice_pass_cannot_condense_a_reel_alt_to_one_frame(sample_photo):
    result = _capture_through_passes(
        [COMPLIANT, dict(COMPLIANT, alt_texts=[ONE_FRAME])],
        photo_paths=[sample_photo], post_type="scroll_reel", post_photo_count=234)
    assert result["alt_texts"] == COMPLIANT["alt_texts"], (
        "a later pass rewrote the reel's alt text into one frame's description "
        "and shipped it")


def test_a_clip_reel_is_covered_too(sample_photo):
    # clip_reel is aliased to scroll_reel's instruction and is in
    # SINGLE_ALT_POST_TYPES, so it has the same failure and needs the same
    # cover. A fix that named only scroll_reel would leave Friday broken.
    result = _capture_through_passes(
        [COMPLIANT, dict(COMPLIANT, alt_texts=[ONE_FRAME])],
        photo_paths=[sample_photo], post_type="clip_reel", post_photo_count=90)
    assert result["alt_texts"] == COMPLIANT["alt_texts"]


def test_the_rewrite_is_reported_rather_than_only_undone(sample_photo):
    # Putting it back destroys the only evidence the pass ignored the draft: a
    # pass that rewrote every alt and one that reproduced them all produce an
    # identical result afterwards (L340). This repo has already shipped that
    # exact shape once, which is cause three of this same issue.
    result = _capture_through_passes(
        [COMPLIANT, dict(COMPLIANT, alt_texts=[ONE_FRAME])],
        photo_paths=[sample_photo], post_type="scroll_reel", post_photo_count=234)
    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_rewritten_by_review" in codes, result["findings"]


def test_a_pass_that_left_the_alt_alone_is_not_reported(sample_photo):
    # The positive control. Without it the test above is satisfied by a report
    # raised on every run, which is a panel that cries wolf (L36, L159).
    result = _capture_through_passes(
        [COMPLIANT, dict(COMPLIANT, caption="A tighter caption.")],
        photo_paths=[sample_photo], post_type="scroll_reel", post_photo_count=234)
    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_rewritten_by_review" not in codes


def test_the_passes_can_still_improve_the_caption(sample_photo):
    # The other positive control: holding alt text out of the rewrite must not
    # turn the review passes into no passes at all (L143).
    result = _capture_through_passes(
        [COMPLIANT, dict(COMPLIANT, caption="A tighter caption.")],
        photo_paths=[sample_photo], post_type="scroll_reel", post_photo_count=234)
    assert result["caption"] == "A tighter caption."


def test_a_per_frame_draft_is_still_collapsed_and_reported(sample_photo):
    # Restoring the draft's alt text must not resurrect a list the draft pass
    # should never have written: cause three still applies to what pass 1 said.
    result = _capture_through_passes(
        [PER_FRAME, dict(COMPLIANT, alt_texts=[ONE_FRAME])],
        photo_paths=[sample_photo], post_type="scroll_reel", post_photo_count=234)
    assert len(result["alt_texts"]) == 1
    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_per_frame" in codes


# -- the tidy is allowed back, and its RESULT is checked ----------------------
#
# Holding alt text out of the review passes entirely stopped the condensation,
# and it also stopped the humanizer cleaning an AI tell out of an alt text,
# which it is explicitly asked to do ("preserve count and order, clean each item
# in place"). Dan's call, 2026-09-02: it should work everywhere.
#
# So the action is allowed and the RESULT is judged, which needs a check that
# tells a clean from a condensation. There is one, and it comes from the
# instruction itself: the scroll reel rule asks for 25 to 50 words. Measured
# against the live store the same day, 7 of 21 shipped Thursday alt texts fall
# under that floor and every one of them is in the single moment group, while
# none of the 9 reel level ones do.
#
# The floor sits in the dense middle of the real distribution (24, 24, 24, 25,
# 25, 25), so it will fire on near boundary cases (L172). That is affordable
# ONLY because refusing a tidy keeps the draft's own alt text, so the cost of
# being wrong is a lost tidy rather than a wrong description.

REEL_LEVEL_ALT = (
    "A photo scroll through the Battery Dance Festival at Rockefeller Park, "
    "covering the evening's six companies from the opening solo through the "
    "ensemble sections to the final bow, lit in blue and pink against the "
    "harbour behind the stage.")


def test_a_reel_alt_the_tidy_left_long_enough_is_kept(sample_photo):
    """The whole point of letting the tidy run: its work must survive."""
    draft = dict(COMPLIANT, alt_texts=[REEL_LEVEL_ALT])
    tidied = REEL_LEVEL_ALT.replace("covering", "moving through")
    assert len(tidied.split()) >= 25
    result = _capture_through_passes(
        [draft, dict(draft, alt_texts=[tidied])],
        photo_paths=[sample_photo], post_type="scroll_reel", post_photo_count=234)
    assert result["alt_texts"] == [tidied], (
        "the humanizer is asked to clean each alt text in place, so a clean "
        "that kept the reel level description must reach the post")


def test_a_tidy_that_lengthens_a_short_reel_alt_is_kept(sample_photo):
    # A tidy moving a too-short alt TOWARDS the floor is the opposite of the
    # fault, so the floor must not refuse it.
    draft = dict(COMPLIANT, alt_texts=[ONE_FRAME])
    result = _capture_through_passes(
        [draft, dict(draft, alt_texts=[REEL_LEVEL_ALT])],
        photo_paths=[sample_photo], post_type="scroll_reel", post_photo_count=234)
    assert result["alt_texts"] == [REEL_LEVEL_ALT]


def test_a_reel_alt_condensed_under_its_own_floor_is_still_refused(sample_photo):
    draft = dict(COMPLIANT, alt_texts=[REEL_LEVEL_ALT])
    result = _capture_through_passes(
        [draft, dict(draft, alt_texts=[ONE_FRAME])],
        photo_paths=[sample_photo], post_type="scroll_reel", post_photo_count=234)
    assert result["alt_texts"] == [REEL_LEVEL_ALT]


def test_the_refusal_says_it_was_the_word_floor(sample_photo):
    # Distinct reasons want distinct sentences: a condensation, a reorder and a
    # dropped entry are three different things a pass did (L11).
    draft = dict(COMPLIANT, alt_texts=[REEL_LEVEL_ALT])
    result = _capture_through_passes(
        [draft, dict(draft, alt_texts=[ONE_FRAME])],
        photo_paths=[sample_photo], post_type="scroll_reel", post_photo_count=234)
    finding = next(f for f in result["findings"]
                   if f["code"] == "alt_text_rewritten_by_review")
    assert "25" in finding["detail"], finding["detail"]


def test_every_post_type_alt_instruction_states_a_word_floor():
    """The floor is READ from each post type's own instruction rather than
    written down beside it, so the two cannot drift (L41). That only holds
    while every instruction actually states one, and an instruction reworded
    without its numbers would silently switch the check off (L113, L100)."""
    from postroll.ai.generate_captions import (
        ALT_TEXT_INSTRUCTION, DEFAULT_ALT_TEXT_INSTRUCTION, _alt_word_floor,
        _word_floor_in)
    assert _word_floor_in(DEFAULT_ALT_TEXT_INSTRUCTION) is not None
    for post_type in ALT_TEXT_INSTRUCTION:
        assert _alt_word_floor(post_type) is not None, post_type
    assert _alt_word_floor("scroll_reel") == 25
    assert _alt_word_floor("carousel") == 15


def test_a_post_type_with_no_instruction_still_gets_the_default_floor():
    from postroll.ai.generate_captions import _alt_word_floor
    assert _alt_word_floor("feed_photo") == 15
