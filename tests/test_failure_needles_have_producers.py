"""Every failure-classifier needle has to match something Python actually writes
(#493).

`RunFailureKind` is a hand-kept mirror of the text the pipeline records, with no
parity guard, and three of its families matched nothing at all: the collage one
looked for "collage skipped" and "collage_min" while the pipeline records
"collage failed", so that kind was unreachable and the hint hanging off it could
never be shown. A needle with no producer is a rule that reads as careful and
does nothing (L41, with the L46 consequence).

This checks the direction that was missing: for each needle, is there a line in
the Python pipeline that could produce text containing it? It deliberately does
NOT check the other direction. A message Python writes that nothing classifies
falls to the honest unrecognised-failure text, which names it, so that gap is
visible rather than silent.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SWIFT = REPO_ROOT / "PostRollApp" / "Sources" / "Services" / "RunFailureKind.swift"

# The files whose text reaches the classifier. generate_week stores the bare
# str(e) of an exception and generate_media records its own formatted messages,
# and between them they are everything the app reads as a run failure.
PRODUCERS = [
    REPO_ROOT / "postroll" / "ai" / "generate_media.py",
    REPO_ROOT / "postroll" / "ai" / "generate_week.py",
]

# The measured text that actually reached the app when a run failed (#403).
# A needle matching one of these has a producer even though the words are not in
# our source: the API and the OS wrote them. Read from the fixture rather than
# hand-listed, because a hand-kept exemption list would exempt exactly the
# needles somebody remembered and quietly cover the ones they did not (L96).
FIXTURE = REPO_ROOT / "tests" / "fixtures" / "real_failure_text.json"


# Where the per-day input-shortfall branches start. Everything above this line
# classifies API and transport failures, whose text the SDK and the OS write and
# whose shapes are only partly covered by the measured fixture; that half is
# #522. Everything below it classifies text OUR pipeline writes, which is what
# #493 is about and what this file checks.
SHORTFALL_MARKER = "// Then the per-day input shortfalls"


def needles() -> list[str]:
    """Every `s.contains("…")` literal in the pipeline-text half of the file."""
    source = SWIFT.read_text(encoding="utf-8")
    assert SHORTFALL_MARKER in source, (
        "the marker splitting API-text classification from pipeline-text "
        "classification is gone, so this check no longer knows what it covers")
    section = source.split(SHORTFALL_MARKER, 1)[1]
    # Comments explaining a needle are not the needle (L103).
    lines = [ln for ln in section.splitlines() if not ln.strip().startswith("//")]
    return sorted(set(re.findall(r's\.contains\("([^"]+)"\)', "\n".join(lines))))


def haystack() -> str:
    """Everything a needle is allowed to have come from."""
    parts = [p.read_text(encoding="utf-8") for p in PRODUCERS]
    cases = json.loads(FIXTURE.read_text(encoding="utf-8"))["cases"]
    parts += [c["text"] for c in cases]
    return "\n".join(parts).lower()


def test_the_classifier_has_needles_to_check():
    """An empty list would pass every assertion below while checking nothing."""
    assert len(needles()) >= 3, needles()


def test_the_fixture_still_holds_measured_text():
    """The exemption is only worth anything while the fixture is real."""
    cases = json.loads(FIXTURE.read_text(encoding="utf-8"))["cases"]
    assert len(cases) >= 5, cases
    for case in cases:
        assert case.get("provenance"), f"{case['name']} has no provenance (L48)"


@pytest.mark.parametrize("needle", needles())
def test_every_needle_has_something_that_could_produce_it(needle: str):
    text = haystack()
    assert needle.lower() in text, (
        f"the classifier looks for {needle!r}, and nothing in "
        f"{[p.name for p in PRODUCERS]} or the measured failure fixture contains "
        f"it. Either the pipeline stopped writing it or it never did, and the "
        f"kind behind it can never be reached."
    )
