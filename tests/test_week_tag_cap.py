"""#281: the week tag list stops at what Instagram accepts, and says what fell off.

`week_tag_list` gathered every handle taggable anywhere in the week with no
ceiling. Instagram tags at most 20 accounts on one post, so past 20 the extra
handles are simply not tagged when the list is pasted in, and nothing in the app
or in CAPTIONS.txt said which ones. The export reads as complete either way,
which is the same silent partial failure as #221 and #222, and a week at a
multi-ensemble venue clears 20 taggable accounts in normal use.

`tests/fixtures/caption_blocks.json` is the contract, because CAPTIONS.txt is
built on the Swift side and these rules live on both. A cap applied on one side
only produces exactly the file this issue is about.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.caption_blocks import MAX_TAGS_PER_POST, TAGS_DROPPED, week_tags


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "caption_blocks.json"


def _fixture() -> dict:
    return json.loads(FIXTURE.read_text())


def _days(case: dict):
    return [
        ({"tag_handles": d["tag_handles"]}, d["photo_tags"], d["photos"])
        for d in case["days"]
    ]


def test_the_cap_is_the_number_the_contract_states():
    assert MAX_TAGS_PER_POST == _fixture()["max_tags_per_post"]


def test_the_dropped_header_is_the_one_the_contract_states():
    assert TAGS_DROPPED == _fixture()["dropped_header"]


@pytest.mark.parametrize("case", _fixture()["cases"], ids=lambda c: c["_what"])
def test_python_satisfies_the_shared_tag_contract(case):
    kept, dropped = week_tags(_days(case))
    assert kept == case["kept"]
    assert dropped == case["dropped"]


def test_the_fixture_actually_exercises_the_cap():
    # A fixture whose every case sits under the limit would pass while the cap
    # itself was never applied.
    cases = _fixture()["cases"]
    assert any(c["dropped"] for c in cases), (
        "no case drops anything, so the cap is not under test at all")
    assert any(len(c["kept"]) == _fixture()["max_tags_per_post"] for c in cases), (
        "no case reaches the limit exactly, so the boundary is untested")


def test_nothing_is_kept_past_the_cap_whatever_the_input():
    many = [({"tag_handles": [f"h{i:03d}" for i in range(60)]}, {}, [])]
    kept, dropped = week_tags(many)

    assert len(kept) == MAX_TAGS_PER_POST
    assert len(dropped) == 60 - MAX_TAGS_PER_POST
    assert set(kept).isdisjoint(dropped), "a handle cannot be both kept and dropped"


def test_every_handle_is_accounted_for_somewhere():
    # The whole point: what falls off has to be nameable. A handle that is
    # neither kept nor reported is exactly the silent loss this closes.
    many = [({"tag_handles": [f"h{i:03d}" for i in range(35)]}, {}, [])]
    kept, dropped = week_tags(many)
    assert len(kept) + len(dropped) == 35
