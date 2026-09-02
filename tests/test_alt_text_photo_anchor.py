"""Alt texts carry the photo each one describes (#1008).

`alt_texts` is a positional list, aligned to the photo list the caption run was
given. Nothing downstream maintains that alignment: `PostingDay.removingPhotos`
(PostRollApp/Sources/Models/Event.swift:379) re-keys the crop offsets, the
collage crops, the reel crops, the photo tags and the collage cells when a photo
is deleted, and cannot touch `alt_texts` at all, because those live on
`Event.weekResult`, a different object. Dragging photos to reorder a day
(PhotoAssignmentView.swift:924) moves them with nothing permuting the alt texts
either.

So after any reorder or middle removal every alt text describes a different
photograph, and `EventExporter` labels each one with a filename that is not its
subject. Position measures whatever currently occupies that position (L237).

`generate_captions` already computes the list the alt texts are aligned to, as
`original_paths`, precisely so `_reinsert_skipped` can put holes back for
photos it could not read. Emitting it is what lets every later reader resolve an
alt text to its own photo instead of to an index.
"""

from pathlib import Path
from unittest.mock import patch

from postroll.ai import generate_captions


def _photo(tmp_path, name, tone):
    from PIL import Image

    img = Image.new("RGB", (2000, 1332), tone)
    path = tmp_path / name
    img.save(str(path), "JPEG")
    return str(path)


def test_caption_reports_which_photo_each_alt_text_describes(tmp_path):
    photos = [
        _photo(tmp_path, "one.jpg", (120, 80, 60)),
        _photo(tmp_path, "two.jpg", (60, 90, 120)),
        _photo(tmp_path, "three.jpg", (90, 120, 60)),
    ]
    fake = {
        "caption": "Three frames from the second half.",
        "hashtags": ["#dwphotony"],
        "alt_texts": ["alt for one", "alt for two", "alt for three"],
        "scene_labels": [None, None, None],
    }
    with patch(
        "postroll.ai.generate_captions.run_json_prompt", return_value=fake
    ):
        result = generate_captions.generate_caption(
            event="Show",
            org="Org",
            venue="Hall",
            date="2026-04-05",
            day="sunday",
            photo_paths=photos,
            program={"performers": [], "pieces": []},
            post_type="carousel",
        )

    anchors = result["alt_text_photo_paths"]
    assert anchors == [str(p) for p in photos], (
        "the alt text anchors must be the photo list the alt texts were written "
        f"against, in that order, got {anchors}"
    )
    assert len(anchors) == len(result["alt_texts"]), (
        "an anchor list a different length from the alt texts it anchors cannot "
        "resolve anything, and its own length is the only thing that reports it"
    )


def test_the_anchor_covers_photos_that_were_skipped(tmp_path):
    """A photo the run could not read still gets its slot.

    `_reinsert_skipped` puts an empty string back at the skipped photo's index
    so the ones after it are not shifted onto their neighbours. The anchor list
    has to describe the SAME full list, or the two disagree exactly where the
    alignment was hardest to get right.
    """
    good = _photo(tmp_path, "good.jpg", (120, 80, 60))
    unreadable = tmp_path / "broken.jpg"
    unreadable.write_bytes(b"not an image")
    photos = [good, str(unreadable)]

    fake = {
        "caption": "One frame.",
        "hashtags": [],
        "alt_texts": ["alt for good"],
        "scene_labels": [None],
    }
    with patch(
        "postroll.ai.generate_captions.run_json_prompt", return_value=fake
    ):
        result = generate_captions.generate_caption(
            event="Show",
            org="Org",
            venue="Hall",
            date="2026-04-05",
            day="sunday",
            photo_paths=photos,
            program={"performers": [], "pieces": []},
            post_type="carousel",
        )

    anchors = result["alt_text_photo_paths"]
    assert len(anchors) == len(result["alt_texts"]), (
        "the anchor list and the alt text list must stay the same length once "
        f"the holes are put back, got {len(anchors)} anchors for "
        f"{len(result['alt_texts'])} alt texts"
    )
    assert anchors == [str(Path(p)) for p in photos], (
        f"every photo the day started with needs a slot, got {anchors}"
    )


def test_a_single_alt_post_anchors_only_the_photo_it_describes(tmp_path):
    """A feed photo collapses to ONE alt text, so it gets ONE anchor.

    `SINGLE_ALT_POST_TYPES` truncates `alt_texts` to its first entry
    defensively, in case the model wrote one per photo anyway. An anchor list
    left at full length would then claim three photos for one alt text, and any
    reader resolving by index would hand photo one's description to photo two.
    A list whose length disagrees with the list it anchors reports nothing about
    the disagreement (L16).
    """
    photos = [
        _photo(tmp_path, "a.jpg", (120, 80, 60)),
        _photo(tmp_path, "b.jpg", (60, 90, 120)),
    ]
    fake = {
        "caption": "One frame.",
        "hashtags": [],
        "alt_texts": ["alt for a", "alt the model should not have written"],
        "scene_labels": [None, None],
    }
    with patch(
        "postroll.ai.generate_captions.run_json_prompt", return_value=fake
    ):
        result = generate_captions.generate_caption(
            event="Show",
            org="Org",
            venue="Hall",
            date="2026-04-05",
            day="sunday",
            photo_paths=photos,
            program={"performers": [], "pieces": []},
            post_type="feed_photo",
        )

    assert len(result["alt_texts"]) == 1, "fixture assumption: a feed photo keeps one"
    assert result["alt_text_photo_paths"] == [str(photos[0])], (
        "a single alt post describes its first photo and only that one, got "
        f"{result['alt_text_photo_paths']}"
    )


def test_a_revision_keeps_the_anchors_it_was_given():
    """Revising a caption must not drop which photo each alt text describes.

    `revise_caption` rewrites the body and passes the alt texts through
    untouched. If it does not pass the anchors through with them, every
    revision returns a payload with none, `DayCaption` decodes the absence as
    an empty list, and the alt texts silently fall back to matching photos by
    position. That is the exact defect the anchors exist to remove, restored by
    the one action most likely to be taken on a caption Dan is unhappy with.

    A field carried by one path and dropped by its sibling is invisible at both
    ends: neither reader can tell a revision that lost them from a caption that
    never had them.
    """
    from postroll.ai import revise_caption

    existing = {
        "caption": "Before.",
        "hashtags": ["#dwphotony"],
        "alt_texts": ["alt for one", "alt for two"],
        "alt_text_photo_paths": ["/photos/one.jpg", "/photos/two.jpg"],
        "scene_labels": [None, None],
    }
    with patch(
        "postroll.ai.revise_caption.run_json_prompt",
        return_value={"caption": "After.", "hashtags": ["#dwphotony"]},
    ):
        result = revise_caption.revise_caption(
            existing=existing,
            feedback="make it warmer",
            event="Show",
            org="Org",
            venue="Hall",
            date="2026-04-05",
            day="sunday",
            program={"performers": [], "pieces": []},
        )

    assert result["alt_text_photo_paths"] == existing["alt_text_photo_paths"], (
        "a revision passed the alt texts through but not the photos they "
        f"describe, got {result.get('alt_text_photo_paths')}"
    )
    assert len(result["alt_text_photo_paths"]) == len(result["alt_texts"]), (
        "the anchors and the alt texts have to survive a revision together"
    )


# -- a review pass must not permute the alt texts either (#1214) --------------
#
# The anchors above make an alt text resolvable to its own photograph, and every
# reader downstream still indexes positionally into the list. Passes 2 and 3
# hand the whole draft JSON back to the model to rewrite, carry no post type,
# and had no validator, so a pass that reorders the entries, drops one, or
# merges two shifts every alt text after that point onto the wrong photograph.
# That is #1008's failure arriving by a different route, and invisible for the
# same reason: each sentence is well written and true of SOME photograph in the
# post, so a sighted read of the caption screen does not catch it.
#
# #1067 held the alt text out of the rewrite for the post types that take ONE
# alt. This is the rest of that: the per-photo post types, where the damage is
# worse because position is meaning.


def _through_review_passes(replies, photos, **kwargs):
    """Drive a generation where the draft and the voice pass each answer.

    `run_review_pass` is left REAL and calls the module's own
    `run_json_prompt`, so the merge the passes actually perform is exercised
    rather than a stand-in for it.
    """
    answers = list(replies)

    def stub(prompt, **_):
        return dict(answers.pop(0)) if answers else dict(replies[-1])

    with patch.object(generate_captions, "run_json_prompt", side_effect=stub):
        return generate_captions.generate_caption(
            event="Show", org="Org", venue="Hall", date="2026-04-05",
            day="sunday", photo_paths=photos,
            program={"performers": [], "pieces": []},
            skip_humanizer=True, skip_voice_pass=False, **kwargs)


def _carousel_draft():
    return {
        "caption": "Three frames from the second half.",
        "hashtags": ["#dwphotony"],
        "alt_texts": ["alt for one", "alt for two", "alt for three"],
        "scene_labels": [None, None, None],
    }


def _three_photos(tmp_path):
    return [_photo(tmp_path, "one.jpg", (120, 80, 60)),
            _photo(tmp_path, "two.jpg", (60, 90, 120)),
            _photo(tmp_path, "three.jpg", (90, 120, 60))]


def test_a_review_pass_cannot_reorder_a_carousels_alt_texts(tmp_path):
    draft = _carousel_draft()
    swapped = dict(draft, alt_texts=["alt for two", "alt for one", "alt for three"])
    result = _through_review_passes([draft, swapped], _three_photos(tmp_path),
                                    post_type="carousel")
    assert result["alt_texts"] == draft["alt_texts"], (
        "a review pass swapped the first two alt texts, so both photographs "
        "now carry each other's description while every sentence still reads "
        "as correct")


def test_a_review_pass_cannot_drop_one_and_shift_the_rest(tmp_path):
    """The worse shape: everything after the hole moves up one photograph."""
    draft = _carousel_draft()
    short = dict(draft, alt_texts=["alt for two", "alt for three"])
    result = _through_review_passes([draft, short], _three_photos(tmp_path),
                                    post_type="carousel")
    assert result["alt_texts"] == draft["alt_texts"]
    assert len(result["alt_texts"]) == len(result["alt_text_photo_paths"]), (
        "an alt text list a different length from its anchors cannot resolve "
        "anything")


def test_the_carousel_rewrite_is_reported_rather_than_only_undone(tmp_path):
    # Putting them back destroys the only evidence the pass ignored the draft
    # (L340), which is the same reason the single-alt case reports it.
    draft = _carousel_draft()
    swapped = dict(draft, alt_texts=["alt for two", "alt for one", "alt for three"])
    result = _through_review_passes([draft, swapped], _three_photos(tmp_path),
                                    post_type="carousel")
    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_rewritten_by_review" in codes, result["findings"]


def test_the_carousel_report_says_how_many_entries_moved(tmp_path):
    # One entry rewritten and all of them rewritten want different responses,
    # and quoting entry 0 alone cannot tell them apart on a per-photo post.
    draft = _carousel_draft()
    swapped = dict(draft, alt_texts=["alt for two", "alt for one", "alt for three"])
    result = _through_review_passes([draft, swapped], _three_photos(tmp_path),
                                    post_type="carousel")
    finding = next(f for f in result["findings"]
                   if f["code"] == "alt_text_rewritten_by_review")
    assert "2" in finding["detail"], finding["detail"]


def test_a_pass_that_left_the_carousels_alt_texts_alone_is_not_reported(tmp_path):
    # The positive control. Without it the tests above are satisfied by a report
    # raised on every carousel, which is a panel that cries wolf (L36, L159).
    draft = _carousel_draft()
    result = _through_review_passes(
        [draft, dict(draft, caption="A tighter caption.")],
        _three_photos(tmp_path), post_type="carousel")
    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_rewritten_by_review" not in codes


def test_the_passes_can_still_improve_a_carousels_caption(tmp_path):
    # The other positive control: holding alt text out of the rewrite must not
    # turn the review passes into no passes at all (L143).
    draft = _carousel_draft()
    result = _through_review_passes(
        [draft, dict(draft, caption="A tighter caption.")],
        _three_photos(tmp_path), post_type="carousel")
    assert result["caption"] == "A tighter caption."


def test_a_carousel_entry_cleaned_in_place_is_kept(tmp_path):
    """The humanizer is asked to clean each alt text in place, and on a per
    photo post that is safe: the count and the order are what carry the
    alignment, and both are checked. Refusing this too would have made the
    humanizer pass a no-op on alt text for every post type (Dan, 2026-09-02).
    """
    draft = _carousel_draft()
    cleaned = dict(draft, alt_texts=["alt for one, tidied", "alt for two",
                                     "alt for three"])
    result = _through_review_passes([draft, cleaned], _three_photos(tmp_path),
                                    post_type="carousel")
    assert result["alt_texts"] == cleaned["alt_texts"]
    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_rewritten_by_review" not in codes, (
        "an accepted clean is not a fault, and reporting one on every tidied "
        "post is how a findings panel stops being read")


# -- a reorder HIDING inside a reword (found by testing the shipped check) ----
#
# The reorder rule compares the two lists as multisets, so it only fires when
# the entries come back byte identical in a different order. A pass that
# reorders AND rewords defeats it: the entries stop looking like the same
# sentences, the count is unchanged, and every entry is still over its word
# floor, so all three rules pass and the post ships with every description
# beside the wrong photograph. That is the failure #1214 was filed for, walking
# back in through the check written to stop it.
#
# The alignment is what closes it. A genuine clean in place changes a few words,
# so a returned description still resembles its own draft far more than it
# resembles a neighbour's; a swap does the opposite.

ONE = ("A dancer in blue light stands alone at the front of the stage with both "
       "arms raised above her head while the company waits behind her in shadow")
TWO = ("The full choir stands in four rows on the risers wearing black concert "
       "dress with the accompanist visible at the piano on the left of the frame")
THREE = ("The conductor raises both hands above the orchestra as the brass "
         "section lifts their instruments and the first violins lean forward")


def _long_draft():
    return {"caption": "Three frames from the second half.",
            "hashtags": ["#dwphotony"],
            "alt_texts": [ONE, TWO, THREE],
            "scene_labels": [None, None, None]}


def test_a_reorder_hidden_inside_a_reword_is_still_refused(tmp_path):
    draft = _long_draft()
    sneaky = dict(draft, alt_texts=[
        TWO.replace("The full choir", "The whole choir"),
        ONE.replace("in blue light", "under blue light"),
        THREE.replace("raises both hands", "lifts both hands"),
    ])
    for entry in sneaky["alt_texts"]:
        assert len(entry.split()) >= 15, "the fixture must clear the word floor"
    result = _through_review_passes([draft, sneaky], _three_photos(tmp_path),
                                    post_type="carousel")
    assert result["alt_texts"] == draft["alt_texts"], (
        "the pass swapped the first two descriptions while rewording them, so "
        "the multiset comparison could not see the swap and every description "
        "shipped beside the wrong photograph")


def test_a_plain_reword_in_the_same_slots_is_still_accepted(tmp_path):
    """The positive control. An alignment strict enough to refuse every reword
    would turn the humanizer back into a no-op on alt text, which is the thing
    letting the tidy run was for (L143, L159)."""
    draft = _long_draft()
    cleaned = dict(draft, alt_texts=[
        ONE.replace("in blue light", "under blue light"),
        TWO.replace("The full choir", "The whole choir"),
        THREE.replace("raises both hands", "lifts both hands"),
    ])
    result = _through_review_passes([draft, cleaned], _three_photos(tmp_path),
                                    post_type="carousel")
    assert result["alt_texts"] == cleaned["alt_texts"]


def test_a_heavily_rewritten_entry_in_its_own_slot_is_not_called_a_reorder(tmp_path):
    """A rewrite that shares almost nothing with the draft is not a swap, and
    must not be reported as one: it has no better home than its own slot."""
    draft = _long_draft()
    rewritten = dict(draft, alt_texts=[
        "Under a wash of blue the soloist holds both arms overhead at the lip "
        "of the stage as her company waits in darkness behind",
        TWO, THREE])
    result = _through_review_passes([draft, rewritten], _three_photos(tmp_path),
                                    post_type="carousel")
    finding = [f for f in result["findings"]
               if f["code"] == "alt_text_rewritten_by_review"]
    assert not any("reorder" in f["detail"] for f in finding), finding


# -- 1.2: one bad entry must not discard the tidy on all the others -----------


def test_only_the_entry_that_failed_falls_back_to_the_draft(tmp_path):
    draft = _long_draft()
    mixed = dict(draft, alt_texts=[
        ONE.replace("in blue light", "under blue light"),   # a fine clean
        "The choir sings.",                                 # cut under the floor
        THREE.replace("raises both hands", "lifts both hands"),
    ])
    result = _through_review_passes([draft, mixed], _three_photos(tmp_path),
                                    post_type="carousel")
    assert result["alt_texts"][0] == mixed["alt_texts"][0], (
        "a good clean on photo one was thrown away because photo two's was bad")
    assert result["alt_texts"][1] == TWO, "the bad entry must fall back"
    assert result["alt_texts"][2] == mixed["alt_texts"][2]


def test_the_report_names_the_entry_that_fell_back(tmp_path):
    draft = _long_draft()
    mixed = dict(draft, alt_texts=[ONE, "The choir sings.", THREE])
    result = _through_review_passes([draft, mixed], _three_photos(tmp_path),
                                    post_type="carousel")
    finding = next(f for f in result["findings"]
                   if f["code"] == "alt_text_rewritten_by_review")
    assert "2" in finding["detail"], finding["detail"]


def test_a_shape_fault_still_refuses_the_whole_list(tmp_path):
    """A changed count or a reorder is not a per entry fault: the whole list's
    alignment is what is wrong, so there is no good entry to keep."""
    draft = _long_draft()
    short = dict(draft, alt_texts=[TWO, THREE])
    result = _through_review_passes([draft, short], _three_photos(tmp_path),
                                    post_type="carousel")
    assert result["alt_texts"] == draft["alt_texts"]


def test_a_review_pass_that_adds_an_alt_text_is_refused(tmp_path):
    """The one shape fault the alignment rule cannot see.

    An entry APPENDED leaves the first three aligned perfectly, so nothing
    about resemblance is wrong; what is wrong is that the post now carries
    more descriptions than it has photographs, and everything downstream
    indexes one list into the other.
    """
    draft = _long_draft()
    padded = dict(draft, alt_texts=[ONE, TWO, THREE, "An invented fourth photo."])
    result = _through_review_passes([draft, padded], _three_photos(tmp_path),
                                    post_type="carousel")
    assert result["alt_texts"] == draft["alt_texts"]
    assert len(result["alt_texts"]) == len(result["alt_text_photo_paths"])


def test_the_reorder_report_says_it_was_a_reorder(tmp_path):
    """Four faults sharing one sentence tell the reader nothing about what the
    pass actually did, and they want different responses (L11)."""
    draft = _long_draft()
    swapped = dict(draft, alt_texts=[TWO, ONE, THREE])
    result = _through_review_passes([draft, swapped], _three_photos(tmp_path),
                                    post_type="carousel")
    finding = next(f for f in result["findings"]
                   if f["code"] == "alt_text_rewritten_by_review")
    assert "slot" in finding["detail"] or "moved" in finding["detail"], (
        finding["detail"])
