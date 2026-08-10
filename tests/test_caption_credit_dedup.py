"""#188 and #191: a credit appears exactly once in a caption.

Two problems with one answer.

#191: the organisation and venue handles go on every caption automatically, and
they are now also offered as per-photo tag suggestions. Tagging @greenwich_house
on one photo credited it twice by two routes, and nothing decided which governed.

#188: on a 10-photo carousel with a different person tagged on each photo, the
caption call receives ten credits at once, so the likely failure is a caption
that reads as a credit dump.

Dan's rule (2026-08-09): "all tags should only happen once. if it's mentioned in
the caption already it doesn't need to be mentioned again later in the photo
tags in the caption."

So the model is asked to weave a few credits into the body where they fit and
leave the rest for the trailing stack, and the STACK is then deduplicated in
code. Which credits read naturally in prose is a judgement; whether a handle
appears twice is exactly checkable, so it is settled by a regex rather than by
asking the model whether it obeyed (the pattern already used for banned tokens).
"""

from __future__ import annotations

from postroll.ai.generate_captions import dedupe_credit_stack


def test_a_handle_woven_into_the_body_is_dropped_from_the_stack():
    caption = ("Safa at the mic during the second set with @safa.wav leading.\n\n"
               "@safa.wav @greenwich_house")
    assert dedupe_credit_stack(caption) == (
        "Safa at the mic during the second set with @safa.wav leading.\n\n"
        "@greenwich_house")


def test_a_handle_only_in_the_stack_is_kept():
    caption = "A quiet moment before the second set.\n\n@safa.wav @greenwich_house"
    assert dedupe_credit_stack(caption) == caption


def test_the_event_account_is_not_credited_twice_by_two_routes():
    # #191 exactly: the blanket credit put @greenwich_house in the body, and the
    # per-photo tag put it in the stack as well.
    caption = ("Presented by @greenwich_house in the downstairs theater.\n\n"
               "@greenwich_house @safa.wav")
    assert dedupe_credit_stack(caption).endswith("@safa.wav")
    assert dedupe_credit_stack(caption).count("@greenwich_house") == 1


def test_a_plain_name_credit_is_deduplicated_too():
    # name_mentions are credits for people with no handle, and they repeat the
    # same way.
    caption = ("Marguerite Dubois takes the second movement alone.\n\n"
               "Marguerite Dubois @greenwich_house")
    assert dedupe_credit_stack(caption) == (
        "Marguerite Dubois takes the second movement alone.\n\n"
        "@greenwich_house")


def test_matching_ignores_case_but_not_the_handle_itself():
    caption = "A note on @Safa.WAV in the body.\n\n@safa.wav @greenwich_house"
    result = dedupe_credit_stack(caption)
    assert result == "A note on @Safa.WAV in the body.\n\n@greenwich_house"


def test_a_handle_that_merely_starts_another_is_not_treated_as_the_same():
    # @safa is a different account from @safa.wav. Dropping one because the
    # other is present would silently remove a real person's credit.
    caption = "Thanks to @safa in the body.\n\n@safa.wav @greenwich_house"
    assert "@safa.wav" in dedupe_credit_stack(caption)


def test_a_stack_that_empties_completely_leaves_a_clean_caption():
    # No trailing blank line and no orphaned separator, or the caption ships
    # with whitespace Dan has to delete by hand.
    caption = "Safa and @greenwich_house in one line.\n\n@greenwich_house"
    assert dedupe_credit_stack(caption) == "Safa and @greenwich_house in one line."


def test_a_caption_with_no_stack_is_returned_untouched():
    caption = "Just a body sentence with no credits at all."
    assert dedupe_credit_stack(caption) == caption


def test_a_multi_paragraph_body_only_has_its_last_block_treated_as_the_stack():
    # The stack is the trailing credit line. An earlier paragraph that happens
    # to mention a handle is body prose, not a stack to be pruned.
    caption = ("First paragraph mentioning @safa.wav.\n\n"
               "Second paragraph of the body.\n\n"
               "@safa.wav @greenwich_house")
    result = dedupe_credit_stack(caption)
    assert result.count("@safa.wav") == 1
    assert "Second paragraph of the body." in result


def test_a_body_that_is_only_credits_is_not_mistaken_for_a_stack():
    # A single block with no trailing stack must not eat itself.
    caption = "@greenwich_house"
    assert dedupe_credit_stack(caption) == "@greenwich_house"


def test_hashtags_are_left_alone():
    # The hashtag block is not a credit stack and has its own rules.
    caption = ("Safa at the mic with @safa.wav.\n\n"
               "@safa.wav @greenwich_house\n\n#livemusic #nyc")
    result = dedupe_credit_stack(caption)
    assert "#livemusic #nyc" in result
    assert result.count("@safa.wav") == 1
