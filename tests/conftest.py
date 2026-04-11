"""Shared test fixtures for PostRoll media generators."""

from __future__ import annotations

import pytest
from pathlib import Path
from PIL import Image


@pytest.fixture
def tmp_output(tmp_path):
    """Temporary output directory."""
    return tmp_path


@pytest.fixture
def sample_photo(tmp_path):
    """Create a sample landscape photo (2000x1332) simulating a concert shot."""
    img = Image.new("RGB", (2000, 1332), (120, 80, 60))  # warm brown tone
    path = tmp_path / "sample.jpg"
    img.save(str(path), "JPEG")
    return str(path)


@pytest.fixture
def sample_photo_dark(tmp_path):
    """Create a dark sample photo simulating a dark concert hall."""
    img = Image.new("RGB", (2000, 1332), (25, 20, 18))
    path = tmp_path / "sample_dark.jpg"
    img.save(str(path), "JPEG")
    return str(path)


@pytest.fixture
def sample_photo_bright(tmp_path):
    """Create a bright sample photo simulating a well-lit venue."""
    img = Image.new("RGB", (2000, 1332), (220, 200, 180))
    path = tmp_path / "sample_bright.jpg"
    img.save(str(path), "JPEG")
    return str(path)


@pytest.fixture
def sample_logo(tmp_path):
    """Create a sample logo PNG with transparency."""
    img = Image.new("RGBA", (1935, 480), (0, 0, 0, 255))
    path = tmp_path / "logo.png"
    img.save(str(path), "PNG")
    return str(path)
