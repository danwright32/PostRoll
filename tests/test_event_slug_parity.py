"""#108: the event folder slug is one rule, satisfied by both languages.

Python creates the per-event preview folder named by this slug. Swift
re-derives the same name months later in order to DELETE that folder, from a
completely separate implementation, and nothing forced the two to agree.

Drift is bad in both directions. A slug Swift builds differently misses the
folder and leaks it forever; a slug that happens to collide with another
event's deletes files that event is still using.

`tests/fixtures/event_slug.json` is the contract, and every expected value in
it was measured by running the function below rather than written by hand, so
it cannot record a shape the real code does not produce (L48). This file
asserts the Python side satisfies it; `PostRollApp/Tests/EventSlugParityTests
.swift` asserts the Swift side satisfies the same file.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.ai.generate_media import _slug


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "event_slug.json"


def _vectors() -> list[dict]:
    data = json.loads(FIXTURE.read_text())
    assert len(data["vectors"]) >= 10, (
        "a gutted fixture would let both suites pass while proving nothing"
    )
    return data["vectors"]


@pytest.mark.parametrize("vector", _vectors(), ids=lambda v: v["_what"])
def test_python_builds_the_slug_the_contract_records(vector):
    built = f"{_slug(vector['org'])}_{_slug(vector['name'])}_{vector['date']}"
    assert built == vector["slug"]


def test_two_different_events_do_not_share_a_slug():
    # The dangerous direction: a collision means one event's sweep deletes
    # another's still-referenced preview folder.
    slugs = [v["slug"] for v in _vectors()]
    assert len(slugs) == len(set(slugs))
