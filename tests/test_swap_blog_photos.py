"""Tests for the blog photo marker swapper (mocked Claude)."""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai.swap_blog_photos import swap_blog_photos


@pytest.fixture
def photo(tmp_path):
    p = tmp_path / "DSC4821.jpg"
    p.write_bytes(b"fake jpeg bytes")
    return p


def test_requires_photos():
    with pytest.raises(ValueError, match="No photo paths"):
        swap_blog_photos(body="some text", photo_paths=[])


def test_requires_body(photo):
    with pytest.raises(ValueError, match="No blog body"):
        swap_blog_photos(body="   ", photo_paths=[photo])


def test_passes_image_labels_matching_prompt_filenames(photo):
    """Each attached image must be anchored to its filename via image_labels;
    correlating by attachment order invents alt text for the wrong photo."""
    captured = {}

    def fake_run(prompt, timeout=300, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        captured["image_paths"] = image_paths
        captured["image_labels"] = image_labels
        return {"body": "[PHOTO: DSC4821.jpg | new alt]\nProse.", "photo_count": 1}

    with patch(
        "postroll.ai.swap_blog_photos.run_json_prompt", side_effect=fake_run
    ):
        result = swap_blog_photos(
            body="[PHOTO: old.jpg | old alt]\nProse.", photo_paths=[photo]
        )

    # Labels are the clean filenames, parallel to image_paths
    assert captured["image_labels"] == ["DSC4821.jpg"]
    assert len(captured["image_paths"]) == 1
    # The same clean name appears in the prompt photo list
    assert "- DSC4821.jpg" in captured["prompt"]
    assert result["photo_count"] == 1
    assert "DSC4821.jpg" in result["body"]


def test_swapped_body_has_em_dashes_stripped(monkeypatch, tmp_path):
    """The photo swap sends the whole body back to the model and returns its
    text. Its two sibling paths (generate_blog, revise_blog) both strip dashes
    on the way out; this one did not, so a post whose photos were swapped could
    ship an em dash into published copy, breaking the one writing rule Dan's own
    pre-push hook enforces (#203)."""
    import postroll.ai.swap_blog_photos as swap

    photo = tmp_path / "a.jpg"
    photo.write_bytes(b"\xff\xd8\xff\xdb" + b"0" * 64)

    monkeypatch.setattr(swap, "run_json_prompt", lambda *a, **k: {
        # Escapes, not literals: this file must NAME the banned characters,
        # and the pre-push hook cannot tell a line banning one from a line
        # using one. Written as escapes so the file holds neither.
        "body": "The room was full \u2014 the light was not \u2013 and it held.",
    })

    result = swap.swap_blog_photos(body="original body", photo_paths=[str(photo)])

    assert "\u2014" not in result["body"], "em dash reached the published body"
    assert "\u2013" not in result["body"], "en dash reached the published body"
