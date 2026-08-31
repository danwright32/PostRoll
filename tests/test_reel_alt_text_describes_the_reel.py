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

The fourth cause, the voice and humanizer passes rewriting the alt text with no
idea what a reel is, is not addressed here.
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
