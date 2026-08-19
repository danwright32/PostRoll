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

from postroll.ai.generate_media import _slug, event_folder_name


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "event_slug.json"


def _vectors() -> list[dict]:
    data = json.loads(FIXTURE.read_text())
    assert len(data["vectors"]) >= 10, (
        "a gutted fixture would let both suites pass while proving nothing"
    )
    return data["vectors"]


@pytest.mark.parametrize("vector", _vectors(), ids=lambda v: v["_what"])
def test_python_builds_the_slug_the_contract_records(vector):
    built = event_folder_name(org=vector["org"], venue=vector["venue"],
                              event=vector["name"], date=vector["date"])
    assert built == vector["slug"]


def test_an_organisation_that_is_there_is_never_replaced_by_the_venue():
    """The half that protects the folders already on disk (#689).

    An organisation written in a non latin script slugs away to nothing and
    produces a name with a leading underscore. Those folders exist. Falling
    back to the venue for them would have Swift derive a different name for a
    folder Python created months ago, miss it, and leak it forever.
    """
    built = event_folder_name(org="!!!", venue="Roulette", event="Hamlet",
                              date="2026-08-20")
    assert built == "_hamlet_2026-08-20"
    assert "roulette" not in built


def test_no_organisation_never_leaves_an_empty_leading_segment():
    """The other direction: nothing is owed a segment it does not have."""
    for venue in ["", "   ", "!!!"]:
        built = event_folder_name(org="", venue=venue, event="Hamlet",
                                  date="2026-08-20")
        assert not built.startswith("_"), f"venue {venue!r} produced {built!r}"
        assert built == "hamlet_2026-08-20"


def test_two_different_events_do_not_share_a_slug():
    # The dangerous direction: a collision means one event's sweep deletes
    # another's still-referenced preview folder.
    slugs = [v["slug"] for v in _vectors()]
    assert len(slugs) == len(set(slugs))
