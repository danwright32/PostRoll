"""What may be stored in a handle field, and what may not (#899).

On Battery Dance Festival, Thursday, a company's row carried its own display
name in the handle field:

    'DPR Dance' -> handle: 'DPR Dance'

Nothing anywhere checked that a handle was SHAPED like a handle, so the value
travelled the whole way: `isRealHandle` is a blacklist of seven sentinel words
and passed it, `CaptionCreditInputs` emitted `@DPR Dance` into `tag_handles` as
a handle to mention, the model obeyed and wrote it into a caption bound for
Instagram, and `HANDLE_RE` here then read that as the handle `@dpr`, which was
never offered and belongs to whoever owns that account.

The check firing was the harmless half. The damaging half is that the pipeline
handed the model a broken mention, so the check accused the model of an
invention the pipeline supplied.

Mirrors `PostRollApp/Tests/HandleShapeTests.swift`. Both read
`tests/fixtures/handle_shape.json`, which states every case once, because a
rule applied on one side of the bridge only is exactly how this happened.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.caption_blocks import is_handle_shaped

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "handle_shape.json"
CASES = json.loads(FIXTURE.read_text())["cases"]


def test_the_fixture_carries_both_answers():
    """Otherwise a run of it says nothing about half the rule (L159)."""
    answers = {case["shaped"] for case in CASES}
    assert answers == {True, False}, (
        f"the shared cases only ever answer {answers}, so this file cannot "
        "tell a predicate that reads the value from one that returns a constant")


@pytest.mark.parametrize("case", CASES, ids=lambda c: c["value"] or "<empty>")
def test_handle_shape(case):
    assert is_handle_shaped(case["value"]) is case["shaped"], case["why"]
