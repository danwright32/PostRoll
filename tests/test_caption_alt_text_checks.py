"""#1068: social caption alt text gets the checks blog alt text already has.

`generate_captions` runs deterministic backstops on hashtags and on credits,
both added because a rule that lives only in a prompt is a hope (#199, #478).
Alt text got none of them, so every description reaching Instagram, Facebook,
Bluesky and Pinterest was whatever the model returned, unexamined. #1067 was one
instance found by hand, months after it started shipping.

WHICH of the blog's six rules transfer was the question the issue actually
asked, and it was answered by measurement rather than by reading. Run over the
319 alt texts in the live store on 2026-09-02, with each day's post type taken
from the app's own `posting_preset.post_type`:

    names a performer                92%   not transferred
    names the venue                  77%   not transferred (42% on reels alone)
    appearance instead of the name   30%   not transferred
    length outside the band          17%   TRANSFERRED
    inferred inner state              5%   TRANSFERRED
    empty                             0%   TRANSFERRED

The three that were left out are left out for a reason that is written down
rather than implied. The performer rule is infeasible on social: a carousel of
eight photos from a forty performer concert cannot name somebody in every one,
which is why it fires on nine in ten. The venue rule is a blog convention, and
loosening it to accept any part of a compound venue ("Lincoln Center, David
Geffen Hall" stored against an alt that says "David Geffen Hall") rescues only
5% of its hits. The appearance rule catches real things, but its implied
alternative IS the performer rule, so it asks for something that cannot be done
here. Any of the three would put a finding on most posts, which is how a panel
stops being read (L36).

Two corrections to the measurement itself, because each would have produced a
confidently wrong answer: the performer list is stored under `ocrResult` rather
than `program`, so the first pass measured zero performers and the rule appeared
never to fire (L98); and the length rule read 71% until it was measured against
each post type's OWN stated word band rather than the blog's.
"""

from __future__ import annotations

import pytest

from postroll.ai.caption_quality import check_caption_alt_texts


CAROUSEL = (15, 35)
REEL = (25, 50)

GOOD = ("A conductor leads roughly twenty singers in all black across the stage "
        "with a piano at the left and red lighting behind the risers")

GOOD_REEL = ("A photo scroll through the festival at the park, covering the six "
             "companies of the evening from the opening solo through the "
             "ensemble sections to the final bow under blue and pink light")


def codes(findings):
    return [f.code for f in findings]


# -- the three rules that transferred ----------------------------------------

def test_an_empty_alt_text_is_reported():
    found = check_caption_alt_texts([""], band=CAROUSEL)
    assert "alt_text_empty" in codes(found)


def test_a_missing_alt_text_is_reported_as_empty():
    """None and "" are the same absence to a screen reader user."""
    found = check_caption_alt_texts([None], band=CAROUSEL)
    assert "alt_text_empty" in codes(found)


def test_an_alt_text_under_the_band_is_reported():
    found = check_caption_alt_texts(["Four dancers on a stage."], band=CAROUSEL)
    assert "alt_text_length" in codes(found)


def test_an_alt_text_over_the_band_is_reported():
    found = check_caption_alt_texts([" ".join(["word"] * 60)], band=CAROUSEL)
    assert "alt_text_length" in codes(found)


def test_an_inferred_feeling_is_reported():
    found = check_caption_alt_texts(
        ["A cellist plays with intense concentration while the section behind "
         "her follows the line into the final phrase of the movement"],
        band=CAROUSEL)
    assert "alt_text_inferred_state" in codes(found)


def test_an_expression_aimed_at_someone_is_reported():
    """The expression is in the frame; who it was meant for is not."""
    found = check_caption_alt_texts(
        ["A singer stands at the microphone grinning toward the audience while "
         "the pianist behind her turns a page of the score on the stand"],
        band=CAROUSEL)
    assert "alt_text_inferred_state" in codes(found)


# -- and the positive control, which is the whole point ----------------------

def test_correct_alt_text_raises_nothing():
    """Without this every test above is satisfied by a check that fires on
    everything, which is a panel that gets skimmed (L36, L159)."""
    assert check_caption_alt_texts([GOOD], band=CAROUSEL) == []


def test_a_correct_reel_alt_raises_nothing():
    assert check_caption_alt_texts([GOOD_REEL], band=REEL) == []


# -- the band is the POST TYPE's own, not one number for everything ----------

def test_the_same_alt_text_can_pass_a_carousel_and_be_short_for_a_reel():
    """A carousel photo asks for 15 to 50 words and a scroll reel for 25 to 50,
    so the band has to come from the post type rather than be written once."""
    twenty = " ".join(["word"] * 20)
    assert codes(check_caption_alt_texts([twenty], band=CAROUSEL)) == []
    assert "alt_text_length" in codes(check_caption_alt_texts([twenty], band=REEL))


def test_no_band_means_no_length_check_rather_than_a_crash():
    """A post type whose instruction states no range switches this rule off
    rather than guessing a number. A test in the caption module keeps that
    unreachable by asserting every instruction states one (L113)."""
    assert codes(check_caption_alt_texts(["short"], band=None)) == []


# -- the three that were deliberately NOT transferred ------------------------

def test_it_does_not_ask_for_a_performer_a_venue_or_a_name():
    """Pinned rather than left to be rediscovered as an oversight (L129, L233).

    This alt text names no venue, names no performer, and describes a person by
    appearance. On the blog all three are findings; measured on the live store
    they fire on 92%, 77% and 30% of real caption alt texts, so all three are
    out. If anyone transfers one later, this test is what tells them it was a
    decision rather than a gap.
    """
    by_appearance = ("A woman in a black lace dress sings from a music folder "
                     "while a second singer waits behind her at the edge of "
                     "the riser")
    assert check_caption_alt_texts([by_appearance], band=CAROUSEL) == []


# -- every finding says which photo it is about ------------------------------

def test_each_finding_names_the_photo_it_is_about():
    """A finding about one of eight descriptions is unusable without saying
    which one (L80)."""
    found = check_caption_alt_texts(
        [GOOD, "Too short."], band=CAROUSEL,
        photo_names=["first.jpg", "second.jpg"])
    length = [f for f in found if f.code == "alt_text_length"]
    assert length and "second.jpg" in length[0].detail, found


def test_it_falls_back_to_the_position_when_there_are_no_photo_names():
    found = check_caption_alt_texts([GOOD, "Too short."], band=CAROUSEL)
    length = [f for f in found if f.code == "alt_text_length"]
    assert length and "2" in length[0].detail, found


def test_more_alt_texts_than_names_does_not_raise():
    """The two lists are kept in step elsewhere; a check must not be the thing
    that crashes when something upstream failed to (L215)."""
    found = check_caption_alt_texts(["Too short.", "Also short."],
                                    band=CAROUSEL, photo_names=["only.jpg"])
    assert len([f for f in found if f.code == "alt_text_length"]) == 2


def test_an_empty_list_of_alt_texts_reports_nothing():
    assert check_caption_alt_texts([], band=CAROUSEL) == []


# -- and they reach the review screen ----------------------------------------
#
# A check nobody sees is a check that does not exist. These ride the `findings`
# list already on each day, beside the credit findings that are there now.

from unittest.mock import patch  # noqa: E402

from postroll.ai import generate_captions as gc  # noqa: E402


def _generate(fake, **kwargs):
    with patch.object(gc, "run_json_prompt", return_value=dict(fake)):
        return gc.generate_caption(
            event="Show", org="Org", venue="Hall", date="2026-04-05",
            day="sunday", program={"performers": [], "pieces": []},
            skip_humanizer=True, skip_voice_pass=True, **kwargs)


def test_a_short_alt_text_reaches_the_findings_on_the_day(sample_photo):
    result = _generate(
        {"caption": "A night at the show.", "hashtags": ["#dwphotony"],
         "alt_texts": ["Four dancers."], "scene_labels": [None]},
        photo_paths=[sample_photo], post_type="feed_photo")
    assert "alt_text_length" in [f["code"] for f in result["findings"]], \
        result["findings"]


def test_a_good_alt_text_adds_no_finding(sample_photo):
    result = _generate(
        {"caption": "A night at the show.", "hashtags": ["#dwphotony"],
         "alt_texts": [GOOD], "scene_labels": [None]},
        photo_paths=[sample_photo], post_type="feed_photo")
    alt_codes = [f["code"] for f in result["findings"]
                 if f["code"].startswith("alt_text_")]
    assert alt_codes == [], result["findings"]


def test_the_reel_band_is_used_for_a_reel(sample_photo):
    """A 20 word alt is fine for a feed photo and short for a scroll reel, so
    the wiring has to pass the POST TYPE's band, not one number."""
    twenty = " ".join(["word"] * 20)
    reel = _generate(
        {"caption": "A scroll through the night.", "hashtags": ["#dwphotony"],
         "alt_texts": [twenty], "scene_labels": [None]},
        photo_paths=[sample_photo], post_type="scroll_reel", post_photo_count=90)
    assert "alt_text_length" in [f["code"] for f in reel["findings"]]

    photo = _generate(
        {"caption": "A night at the show.", "hashtags": ["#dwphotony"],
         "alt_texts": [twenty], "scene_labels": [None]},
        photo_paths=[sample_photo], post_type="feed_photo")
    assert "alt_text_length" not in [f["code"] for f in photo["findings"]]


def test_the_checks_read_what_actually_ships(sample_photo):
    """`strip_em_dashes` splits a dash joined token into two, so a count taken
    before it and a count taken after it are different numbers. The check has to
    read the text that ships, or it reports on something nobody receives."""
    # The dash is written as an escape, not as itself: the pre push style hook
    # scans added lines for one and cannot tell a line USING the character from
    # a line testing what happens to it, which is the hook working correctly.
    dashed = " ".join(["word"] * 14) + " one\u2014two"
    result = _generate(
        {"caption": "A night at the show.", "hashtags": ["#dwphotony"],
         "alt_texts": [dashed], "scene_labels": [None]},
        photo_paths=[sample_photo], post_type="feed_photo")
    shipped = len(result["alt_texts"][0].split())
    assert shipped == 16, result["alt_texts"][0]
    assert "alt_text_length" not in [f["code"] for f in result["findings"]], (
        "counted before the dash strip, this reads as 15 words and passes; "
        "counted after, as 16. Either way it is inside the band, but the check "
        "must be reading the shipped text")


def test_every_post_type_alt_instruction_states_a_band():
    """The band is read out of each post type's own instruction rather than
    written down beside it, so the two cannot drift (L41). That holds only
    while every instruction states one, and an instruction reworded without its
    numbers would switch the length rule off silently (L113, L100)."""
    from postroll.ai.generate_captions import ALT_TEXT_INSTRUCTION, _alt_word_band
    for post_type in ALT_TEXT_INSTRUCTION:
        band = _alt_word_band(post_type)
        assert band is not None, post_type
        assert band[0] < band[1], (post_type, band)
    assert _alt_word_band("scroll_reel") == (25, 50)
    assert _alt_word_band("feed_photo") == (15, 35)
