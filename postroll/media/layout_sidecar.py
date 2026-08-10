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

from pathlib import Path


#: Appended to the preview's name, without its extension.
SUFFIX = "_layout.json"


def layout_sidecar_path(preview: Path | str) -> Path:
    """The sidecar that belongs to `preview`, in the same directory."""
    preview = Path(preview)
    return preview.parent / (preview.stem + SUFFIX)
