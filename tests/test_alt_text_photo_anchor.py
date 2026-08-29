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
