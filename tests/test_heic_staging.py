"""Tests for HEIC staging names. The staged name must carry the caller's
prefix so downstream prefix stripping recovers the original filename
(IMG_1234.heic must yield IMG_1234.jpg in markers, not 1234.jpg) and
same-stem files from different folders cannot overwrite each other."""

from __future__ import annotations

import shutil
import subprocess

import pytest

from postroll.ai.ocr_program import _convert_heic_to_jpeg

needs_sips = pytest.mark.skipif(
    shutil.which("sips") is None, reason="sips (macOS) required"
)


def _make_heic(tmp_path, name: str):
    from PIL import Image

    jpg = tmp_path / "src.jpg"
    Image.new("RGB", (32, 32), (200, 100, 50)).save(jpg)
    heic = tmp_path / name
    subprocess.run(
        ["sips", "-s", "format", "heic", str(jpg), "--out", str(heic)],
        capture_output=True, check=True,
    )
    return heic


@needs_sips
def test_converted_heic_carries_staging_prefix(tmp_path):
    src = _make_heic(tmp_path, "IMG_1234.heic")
    dest_dir = tmp_path / "staged"
    dest_dir.mkdir()

    dest = _convert_heic_to_jpeg(src, dest_dir, prefix="000_")

    assert dest.name == "000_IMG_1234.jpg"
    # The strip used in blog staging recovers the original-style name
    stripped = dest.name.split("_", 1)[1]
    assert stripped == "IMG_1234.jpg"


@needs_sips
def test_same_stem_heics_do_not_collide(tmp_path):
    a_dir = tmp_path / "a"
    b_dir = tmp_path / "b"
    a_dir.mkdir()
    b_dir.mkdir()
    src_a = _make_heic(a_dir, "IMG_0001.heic")
    src_b = _make_heic(b_dir, "IMG_0001.heic")
    dest_dir = tmp_path / "staged"
    dest_dir.mkdir()

    dest_a = _convert_heic_to_jpeg(src_a, dest_dir, prefix="000_")
    dest_b = _convert_heic_to_jpeg(src_b, dest_dir, prefix="001_")

    assert dest_a != dest_b
    assert dest_a.exists() and dest_b.exists()
