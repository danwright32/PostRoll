"""#160: a cached collage says which design made it.

Rendered collages are cached per day. When the collage design changed, as it
did in c65a0d6 (gallery mat, caption plate, shape-aware layout), every existing
collage kept rendering the old design indefinitely until somebody happened to
regenerate that day by hand, and nothing surfaced them as out of date.

The stamp rides in the layout sidecar that already sits beside the PNG. The
sidecar used to be a bare array of cells, so it grew an envelope; the reader on
the Swift side accepts both, because every collage rendered before this change
has a sidecar in the old shape and treating those as unreadable would blank a
day's crop editing rather than badge it.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.media import design_tokens as tokens
from postroll.media.layout_sidecar import layout_sidecar_path, read_layout_sidecar
from tests.source_text import swift_without_comments


REPO_ROOT = Path(__file__).resolve().parent.parent
SWIFT_TOKENS = REPO_ROOT / "PostRollApp" / "Sources" / "DesignTokens.swift"


def test_there_is_a_declared_collage_design_version():
    assert isinstance(tokens.COLLAGE_DESIGN_VERSION, int)
    assert tokens.COLLAGE_DESIGN_VERSION >= 1


def test_swift_mirrors_the_same_version():
    # Two numbers in two languages with nothing forcing them to agree would
    # make every collage read stale, or none of them.
    # Comments stripped, or a commented-out old version carrying the marker
    # decides what this reads (#436).
    text = swift_without_comments(SWIFT_TOKENS.read_text())
    marker = "static let collageDesignVersion = "
    assert marker in text, (
        "DesignTokens.swift does not declare collageDesignVersion, so the app "
        "cannot tell a stale collage from a current one")
    value = int(text.split(marker, 1)[1].split("\n", 1)[0].strip())
    assert value == tokens.COLLAGE_DESIGN_VERSION


# ── the sidecar carries it ────────────────────────────────────────────────────

def test_the_sidecar_records_the_version_that_rendered_it(tmp_path, sample_photo):
    from postroll.media.generate_collage import generate_collage

    out = tmp_path / "collage.png"
    generate_collage(photo_paths=[str(sample_photo)] * 4, output_path=str(out),
                     event_name="E", org="O", venue="V", seed=1)

    doc = json.loads(layout_sidecar_path(out).read_text())
    assert doc["version"] == tokens.COLLAGE_DESIGN_VERSION


def test_the_cells_still_come_back_out(tmp_path, sample_photo):
    from postroll.media.generate_collage import generate_collage

    out = tmp_path / "collage.png"
    generate_collage(photo_paths=[str(sample_photo)] * 4, output_path=str(out),
                     event_name="E", org="O", venue="V", seed=1)

    version, cells = read_layout_sidecar(layout_sidecar_path(out))
    assert version == tokens.COLLAGE_DESIGN_VERSION
    assert len(cells) == 4
    assert {"photo_path", "x", "y", "w", "h"} <= set(cells[0])


# ── the reader tolerates what is already on disk ──────────────────────────────

def test_an_old_bare_array_sidecar_still_reads(tmp_path):
    # Every collage rendered before this change has one. Treating it as
    # unreadable would blank a day's crop editing rather than badge it.
    path = tmp_path / "collage_layout.json"
    path.write_text(json.dumps([{"photo_path": "/p/a.jpg", "x": 0, "y": 0, "w": 10, "h": 10}]))

    version, cells = read_layout_sidecar(path)

    assert version is None, "an unstamped sidecar has no version, which is not version 0"
    assert len(cells) == 1


def test_a_missing_sidecar_is_not_an_error(tmp_path):
    version, cells = read_layout_sidecar(tmp_path / "never-written.json")
    assert version is None
    assert cells == []


def test_a_corrupt_sidecar_is_not_an_error(tmp_path):
    path = tmp_path / "collage_layout.json"
    path.write_text("{not json")
    assert read_layout_sidecar(path) == (None, [])
