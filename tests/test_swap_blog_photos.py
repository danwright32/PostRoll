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

    def fake_run(prompt, timeout=300, image_paths=None, image_labels=None):
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
