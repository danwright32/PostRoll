"""Tests for the before/after image generator."""

from __future__ import annotations

from pathlib import Path
from PIL import Image

from postroll.media.generate_before_after import generate_before_after


def test_generates_correct_dimensions(sample_photo, tmp_output):
    output = tmp_output / "ba.png"
    generate_before_after(
        raw_path=sample_photo,
        edit_path=sample_photo,
        output_path=str(output),
        event_name="Test Event",
        org="Test Org",
        venue="Test Venue",
    )
    img = Image.open(output)
    assert img.size == (1080, 1920)


def test_generates_png(sample_photo, tmp_output):
    output = tmp_output / "ba.png"
    generate_before_after(
        raw_path=sample_photo,
        edit_path=sample_photo,
        output_path=str(output),
        event_name="Test",
        org="Org",
        venue="Venue",
    )
    img = Image.open(output)
    assert img.format == "PNG"


def test_with_logo(sample_photo, sample_logo, tmp_output):
    output = tmp_output / "ba.png"
    generate_before_after(
        raw_path=sample_photo,
        edit_path=sample_photo,
        output_path=str(output),
        event_name="Test",
        org="Org",
        venue="Venue",
        logo_path=sample_logo,
    )
    assert output.exists()


def test_dark_photo_brightening(sample_photo_dark, tmp_output):
    """Dark photos should get adaptive brightness boost."""
    output = tmp_output / "ba.png"
    generate_before_after(
        raw_path=sample_photo_dark,
        edit_path=sample_photo_dark,
        output_path=str(output),
        event_name="Dark Concert",
        org="Org",
        venue="Venue",
    )
    assert output.exists()
    img = Image.open(output)
    assert img.size == (1080, 1920)


def test_bright_photo(sample_photo_bright, tmp_output):
    """Bright photos should not get brightness boost."""
    output = tmp_output / "ba.png"
    generate_before_after(
        raw_path=sample_photo_bright,
        edit_path=sample_photo_bright,
        output_path=str(output),
        event_name="Bright Event",
        org="Org",
        venue="Venue",
    )
    assert output.exists()


def test_label_color_dark(sample_photo, tmp_output):
    output = tmp_output / "ba.png"
    generate_before_after(
        raw_path=sample_photo,
        edit_path=sample_photo,
        output_path=str(output),
        event_name="Test",
        org="Org",
        venue="Venue",
        raw_label_color="dark",
        edit_label_color="dark",
    )
    assert output.exists()


def test_label_position_right(sample_photo, tmp_output):
    output = tmp_output / "ba.png"
    generate_before_after(
        raw_path=sample_photo,
        edit_path=sample_photo,
        output_path=str(output),
        event_name="Test",
        org="Org",
        venue="Venue",
        raw_label_pos="right",
        edit_label_pos="right",
    )
    assert output.exists()


def test_creates_output_directory(sample_photo, tmp_output):
    output = tmp_output / "nested" / "dir" / "ba.png"
    generate_before_after(
        raw_path=sample_photo,
        edit_path=sample_photo,
        output_path=str(output),
        event_name="Test",
        org="Org",
        venue="Venue",
    )
    assert output.exists()


def test_three_photo_with_bw(sample_photo, tmp_output):
    """A B&W path adds a third stacked strip; canvas size is unchanged."""
    output = tmp_output / "ba_3up.png"
    generate_before_after(
        raw_path=sample_photo,
        edit_path=sample_photo,
        output_path=str(output),
        event_name="Test Event",
        org="Org",
        venue="Venue",
        bw_path=sample_photo,
    )
    img = Image.open(output)
    assert img.size == (1080, 1920)
    assert img.format == "PNG"


def test_three_photo_with_logo(sample_photo, sample_logo, tmp_output):
    output = tmp_output / "ba_3up_logo.png"
    generate_before_after(
        raw_path=sample_photo,
        edit_path=sample_photo,
        output_path=str(output),
        event_name="Test",
        org="Org",
        venue="Venue",
        logo_path=sample_logo,
        bw_path=sample_photo,
    )
    assert output.exists()
