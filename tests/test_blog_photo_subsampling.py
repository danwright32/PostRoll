"""#434: the branch every real blog run takes had never been exercised.

`generate_blog` subsamples to 7 photos whenever more are supplied, and blog
photos are auto-derived from a whole week's Sunday, Monday and Wednesday
assignments, so a real week is well over 7 and this branch is the one that
ships. Every test fed 0, 1 or 4 photos, all below the threshold, so the mode
that actually runs was the one never covered and the suite stayed green
throughout (L101).

What the subsample has to hold, and none of it was asserted:

  * exactly 7 photos, whatever the input size;
  * 7 DISTINCT photos, because a repeated index means the post shows one
    photograph twice and drops another entirely;
  * the original ORDER, because the prose is written against the sequence of
    attached images;
  * the labels the model is shown line up with the photos actually attached,
    since a marker is matched back to a file by the name in that label.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import generate_blog


@pytest.fixture
def photos(tmp_path):
    """A numbered set, so an out-of-order or repeated pick is visible."""
    def _make(count: int) -> list[str]:
        made = []
        for i in range(count):
            p = tmp_path / f"DSC{i:04d}.jpg"
            Image.new("RGB", (60, 40), (i * 3 % 255, 60, 80)).save(p)
            made.append(str(p))
        return made
    return _make


def _run(photo_paths):
    """Generate a blog with the model stubbed, returning what it was sent."""
    captured = {}

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None,
                      image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        captured["image_paths"] = list(image_paths or [])
        captured["image_labels"] = list(image_labels or [])
        # Carries a contraction on purpose: a paragraph without one sends the
        # deterministic contraction backstop out to the model for a focused
        # rewrite, which is a paid call this test has no business making.
        return {"body": "It's a paragraph about the evening.",
                "photo_count": len(image_paths or [])}

    def refuse(*args, **kwargs):
        raise AssertionError(
            "this test made a live prompt call; stub it rather than paying for it")

    with patch("postroll.ai.generate_blog.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.generate_blog.run_prompt", side_effect=refuse):
        captured["result"] = generate_blog.generate_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            photo_paths=photo_paths,
            skip_humanizer=True, skip_voice_pass=True,
        )
    return captured


@pytest.mark.parametrize("count", [8, 9, 14, 21, 50])
def test_more_than_seven_photos_are_subsampled_to_seven(photos, count):
    sent = _run(photos(count))

    assert len(sent["image_paths"]) == 7
    assert sent["result"]["photo_count"] == 7


@pytest.mark.parametrize("count", [8, 9, 14, 21, 50])
def test_the_seven_are_distinct(photos, count):
    # A repeated index shows one photograph twice and silently drops another.
    labels = _run(photos(count))["image_labels"]

    assert len(set(labels)) == 7, labels


@pytest.mark.parametrize("count", [8, 9, 14, 21, 50])
def test_the_subsample_keeps_the_original_order(photos, count):
    # The prose is written against the sequence of attached images, so a
    # reordered subsample describes the evening out of order.
    labels = _run(photos(count))["image_labels"]

    assert labels == sorted(labels), labels


@pytest.mark.parametrize("count", [8, 14, 50])
def test_the_subsample_spans_the_whole_set(photos, count):
    # Seven photos taken from the front would make the post a report on the
    # first few minutes of the evening.
    #
    # It samples the START of each of seven equal bins, so the very last photo
    # is not guaranteed: at 14 the picks are 0, 2, 4, 6, 8, 10, 12. What IS
    # guaranteed, and what the post depends on, is that the last pick lands in
    # the final seventh.
    labels = _run(photos(count))["image_labels"]
    indices = [int(label[3:7]) for label in labels]

    assert indices[0] == 0
    assert indices[-1] >= count - count / 7 - 1, indices


@pytest.mark.parametrize("count", [8, 14, 50])
def test_the_labels_name_the_photos_actually_attached(photos, count):
    # The label is how a [PHOTO:] marker is matched back to a file, so a label
    # naming a photo that was not attached puts the wrong image in the post.
    sent = _run(photos(count))
    from pathlib import Path

    # Staged copies carry a NNN_ prefix; the label is the name without it.
    staged = [Path(p).name.split("_", 1)[1] for p in sent["image_paths"]]
    assert staged == sent["image_labels"]


@pytest.mark.parametrize("count", [8, 14, 50])
def test_the_prompt_lists_the_seven_it_sent(photos, count):
    sent = _run(photos(count))

    assert "(7 total)" in sent["prompt"]
    for label in sent["image_labels"]:
        assert f"- {label}" in sent["prompt"]


def test_exactly_seven_photos_are_all_kept(photos):
    # The boundary: 7 is not more than 7, so nothing is dropped.
    labels = _run(photos(7))["image_labels"]

    assert len(labels) == 7
    assert labels[0] == "DSC0000.jpg" and labels[-1] == "DSC0006.jpg"
