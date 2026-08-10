"""#267: the layout sidecar's name is one rule, satisfied by both languages.

Python writes the file; Swift reads it from the crop editor, the collage
thumbnail and the export compositor. Swift rebuilt the name in five separate
places, one of them a hardcoded `reel_preview_layout.json` literal, and nothing
forced them to agree. The first one changed would break the editor or the
export on one screen only while the others kept working.

`tests/fixtures/layout_sidecar.json` is the contract. This file asserts the
Python side satisfies it; `PostRollApp/Tests/LayoutSidecarTests.swift` asserts
the Swift side satisfies the same file.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from postroll.media.layout_sidecar import layout_sidecar_path


REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "layout_sidecar.json"


def _vectors() -> list[dict]:
    data = json.loads(FIXTURE.read_text())
    assert data["vectors"], "the fixture is empty, so both suites would pass vacuously"
    return data["vectors"]


@pytest.mark.parametrize("vector", _vectors(), ids=lambda v: v["preview"])
def test_python_names_the_sidecar_the_way_the_contract_says(vector, tmp_path):
    assert layout_sidecar_path(tmp_path / vector["preview"]) == tmp_path / vector["sidecar"]


def test_the_sidecar_lands_beside_its_preview(tmp_path):
    nested = tmp_path / "wednesday"
    assert layout_sidecar_path(nested / "collage.png").parent == nested


def test_no_generator_builds_the_name_by_hand():
    """The point of the helper: one derivation, not one per writer.

    Derived from the source rather than a list written here, so a generator
    added later is covered on the day it lands.
    """
    media = REPO_ROOT / "postroll" / "media"
    offenders = [
        p.name for p in sorted(media.glob("*.py"))
        if p.name != "layout_sidecar.py"
        and re.search(r'"_layout\.json"', p.read_text())
    ]
    assert not offenders, (
        f"these modules spell the sidecar name out themselves: {offenders}"
    )
