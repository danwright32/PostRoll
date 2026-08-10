"""#282: the blog draft's markdown is assembled in one place.

`# title\n\nbody` was written by hand in three: the Swift exporter writing
`0. Blog/draft.md`, the Python CLI writing the same file, and the clipboard
text on the review screen. That is the dual-CAPTIONS.txt parity hazard with an
extra copy, and two of the three are invisible to anyone editing the first.

The clipboard's version was the careful one (it trims, it refuses to add a
second heading to a body that already carries one), and the other two were not.
So the rules are its rules, `tests/fixtures/blog_draft.json` states them once,
and both languages assert against that file.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.blog_draft import blog_draft_text


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "blog_draft.json"


def _cases() -> list[dict]:
    cases = json.loads(FIXTURE.read_text())["cases"]
    assert len(cases) >= 6, "a gutted fixture would let both suites pass vacuously"
    return cases


@pytest.mark.parametrize("case", _cases(), ids=lambda c: c["_what"])
def test_python_satisfies_the_shared_draft_contract(case):
    assert blog_draft_text(case["title"], case["body"]) == case["expected"]


def test_the_fixture_covers_the_case_the_hand_written_copies_got_wrong():
    # The two hand-written copies concatenated unconditionally, so pasting a
    # post back in grew a second title every time.
    assert any("already opens with the heading" in c["_what"] for c in _cases())


def test_no_module_builds_the_heading_by_hand():
    """One renderer, not one per writer.

    Derived from the source rather than a list here, so a fourth copy added
    later is caught on the day it lands.
    """
    import re

    root = Path(__file__).resolve().parent.parent
    offenders = []
    for path in sorted((root / "postroll").rglob("*.py")):
        if path.name == "blog_draft.py":
            continue
        if re.search(r'f?"# \{[^}]*title[^}]*\}\\n\\n', path.read_text()):
            offenders.append(path.name)
    assert not offenders, (
        f"these modules assemble the draft heading themselves: {offenders}")
