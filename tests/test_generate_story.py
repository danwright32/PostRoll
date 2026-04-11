"""Tests for the story template generator."""

from __future__ import annotations

from pathlib import Path
from PIL import Image

from postroll.media.generate_story import generate_story


def test_generates_correct_dimensions(sample_photo, tmp_output):
    output = tmp_output / "story.png"
    generate_story(
        photo_path=sample_photo,
        event_name="Test Event",
        org="Test Org",
        venue="Test Venue",
        output_path=str(output),
    )
    img = Image.open(output)
    assert img.size == (1080, 1920)


def test_generates_png(sample_photo, tmp_output):
    output = tmp_output / "story.png"
    generate_story(
        photo_path=sample_photo,
        event_name="Test Event",
        org="Test Org",
        venue="Test Venue",
        output_path=str(output),
    )
    assert output.exists()
    img = Image.open(output)
    assert img.format == "PNG"


def test_with_logo(sample_photo, sample_logo, tmp_output):
    output = tmp_output / "story.png"
    generate_story(
        photo_path=sample_photo,
        event_name="Test Event",
        org="Test Org",
        venue="Test Venue",
        output_path=str(output),
        logo_path=sample_logo,
    )
    assert output.exists()
    img = Image.open(output)
    assert img.size == (1080, 1920)


def test_without_logo(sample_photo, tmp_output):
    output = tmp_output / "story.png"
    generate_story(
        photo_path=sample_photo,
        event_name="Test Event",
        org="Test Org",
        venue="Test Venue",
        output_path=str(output),
        logo_path=None,
    )
    assert output.exists()


def test_creates_output_directory(sample_photo, tmp_output):
    output = tmp_output / "subdir" / "story.png"
    generate_story(
        photo_path=sample_photo,
        event_name="Test",
        org="Org",
        venue="Venue",
        output_path=str(output),
    )
    assert output.exists()


def test_long_event_name(sample_photo, tmp_output):
    output = tmp_output / "story.png"
    generate_story(
        photo_path=sample_photo,
        event_name="A Very Long Concert Event Name That Might Overflow",
        org="Organization With A Long Name",
        venue="Carnegie Hall Stern Auditorium",
        output_path=str(output),
    )
    assert output.exists()
    img = Image.open(output)
    assert img.size == (1080, 1920)
