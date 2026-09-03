"""Where a rendered preview's layout sidecar lives.

The collage and the Thursday reel strip each write a JSON file beside their
PNG recording the cell rectangles, so the app can draw crop controls over the
right parts of the image. The name is derived from the PNG's own name, and that
derivation is here rather than in each writer, because Swift reads the same
file and rebuilt the name in five separate places (#267).

`PostRollApp/Sources/Services/LayoutSidecar.swift` is the reading half.
`tests/fixtures/layout_sidecar.json` is the contract both satisfy.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .design_tokens import COLLAGE_DESIGN_VERSION


#: Appended to the preview's name, without its extension.
SUFFIX = "_layout.json"


def layout_sidecar_path(preview: Path | str) -> Path:
    """The sidecar that belongs to `preview`, in the same directory."""
    preview = Path(preview)
    return preview.parent / (preview.stem + SUFFIX)


def write_layout_sidecar(path: Path | str, cells: list[dict[str, Any]],
                         version: int = COLLAGE_DESIGN_VERSION,
                         strip: tuple[int, int] | None = None) -> None:
    """Write the cells plus the design version that produced them (#160).

    The file used to be a bare array. The envelope is what lets the app tell a
    collage rendered by the current design from one rendered by an older one,
    which it previously could not, so a redesign left every existing collage
    showing the old look until somebody happened to regenerate that day.

    `strip` is where the branded centre strip SAT in this layout, as (y, height)
    (#970). It is recorded rather than left to be inferred because the editor
    otherwise reads it back out of the cells it is about to judge, and a row
    dragged down over the strip carries the inferred band down with it, so the
    check agrees with itself while the branding is being covered (L70). A layout
    with no strip, which is the reel's, records none.
    """
    document: dict[str, Any] = {"version": version, "cells": cells}
    if strip is not None:
        document["strip"] = {"y": strip[0], "h": strip[1]}
    Path(path).write_text(json.dumps(document), encoding="utf-8")


def read_layout_sidecar(path: Path | str) -> tuple[int | None, list[dict[str, Any]]]:
    """The (version, cells) in a sidecar, tolerating every shape on disk.

    A bare array is a sidecar written before the version existed, and its
    version is None rather than 0: not knowing which design made something is
    a different fact from knowing it was the first one.

    Never raises. A missing or corrupt sidecar means the crop editor falls back
    to the automatic layout, which is what it did before any of this.
    """
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None, []
    if isinstance(doc, list):
        return None, [c for c in doc if isinstance(c, dict)]
    if isinstance(doc, dict):
        cells = doc.get("cells")
        version = doc.get("version")
        return (
            version if isinstance(version, int) else None,
            [c for c in cells if isinstance(c, dict)] if isinstance(cells, list) else [],
        )
    return None, []
