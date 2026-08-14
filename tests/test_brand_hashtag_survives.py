"""#478: the brand tag is stated twice in the prompt and checked nowhere.

`#dwphotony` is Dan's own tag: it is how his work is found under his name, and
it is the one hashtag that must be on every post whatever the programme is. The
prompt says ALWAYS include it, twice, and `strip_performer_hashtags` only ever
REMOVES tags, so a list that came back without it shipped as it was.

A rule that lives only in a prompt is a hope (L27). This is the deterministic
half, the same shape as the performer gate next door: the model's list is
checked at assembly and the tag is put back rather than the caption going out
without it.
"""

from __future__ import annotations

from postroll.ai.performer_hashtags import BRAND_HASHTAG, ensure_brand_hashtag


def test_a_list_that_lost_the_brand_tag_gets_it_back():
    got = ensure_brand_hashtag(["#carnegiehall", "#mahler"])

    assert BRAND_HASHTAG in got


def test_it_goes_first_where_dan_expects_to_read_it():
    assert ensure_brand_hashtag(["#carnegiehall"])[0] == BRAND_HASHTAG


def test_a_list_that_already_has_it_is_left_exactly_as_it_was():
    original = [BRAND_HASHTAG, "#carnegiehall", "#mahler"]

    assert ensure_brand_hashtag(original) == original


def test_it_is_recognised_whatever_case_the_model_used():
    got = ensure_brand_hashtag(["#DWPhotoNY", "#carnegiehall"])

    assert len(got) == 2, f"the tag was added a second time in another case: {got}"


def test_it_is_recognised_without_the_hash():
    got = ensure_brand_hashtag(["dwphotony", "#carnegiehall"])

    assert len(got) == 2, f"the tag was added a second time: {got}"


def test_an_empty_list_still_carries_the_brand_tag():
    # The failure that matters most: a caption pass that returned no hashtags
    # at all must not ship a post with none of Dan's own.
    assert ensure_brand_hashtag([]) == [BRAND_HASHTAG]


def test_the_generator_puts_it_back_before_the_caption_is_returned():
    # The check has to be ON the assembly path, not merely available (L3).
    from pathlib import Path

    source = Path(__file__).resolve().parent.parent / "postroll" / "ai" / "generate_captions.py"
    text = "\n".join(
        line for line in source.read_text().split("\n")
        if not line.strip().startswith("#")
    )
    assert "ensure_brand_hashtag" in text, (
        "generate_captions never calls ensure_brand_hashtag, so the brand tag "
        "is still enforced only by asking the model nicely"
    )
