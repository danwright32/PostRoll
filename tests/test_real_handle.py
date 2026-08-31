"""What counts as an account that can actually be tagged (#926).

Two functions were named for this one question and asked different things.
`PythonBridge.isRealHandle` requires the value to be SHAPED like a username and
not be a SENTINEL. `generate_captions._is_real_handle` checked the sentinel half
only, so 'DPR Dance' passed it, and nothing anywhere asserted the two agreed.

Checking that pair is not what this file ended up being about. The caption
prompt function had had no caller since 2026-05-24, when handles were dropped
from the performers block, so it was dead rather than divergent and is gone. The
pair that actually spans the bridge is the one below: Python's `week_tags` calls
`is_real_handle`, Swift's `weekTags` reaches `PythonBridge.isRealHandle` through
`TypedCredit.read`, and between them they decide the TAG LIST that gets pasted
into Instagram's Tag people field.

Those two DID disagree. Python read the sentinel off `bare_username(raw)` and
Swift read it off the raw value with one leading '@' removed, so
`https://instagram.com/unknown/` and `@@unknown` were refused by Python and
accepted by Swift, which then stripped them down and put 'unknown' in the tag
list as an account. That is the defect #917 was filed to stop, arriving by the
one route it did not cover.

Mirrors `PostRollApp/Tests/RealHandleTests.swift`. Both read
`tests/fixtures/real_handle.json`, which states the sentinel list and every case
once, because a rule applied on one side of the bridge only is how all of this
happened.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from postroll.caption_blocks import HANDLE_SENTINELS, is_real_handle

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "real_handle.json"
SHARED = json.loads(FIXTURE.read_text())
CASES = SHARED["cases"]
SENTINELS = SHARED["sentinels"]


def test_the_shared_cases_carry_both_answers():
    """Otherwise a run of the shared file says nothing about half the rule, and
    a predicate returning a constant would satisfy it (L159)."""
    answers = {case["real"] for case in CASES}
    assert answers == {True, False}, (
        f"the shared cases only ever answer {answers}, so this file cannot "
        "tell a predicate that reads the value from one that returns a constant")


def test_pythons_sentinel_list_is_the_shared_one():
    """The two sides keep their own copies by hand (L41). Held to one list
    here, so a word added to either alone is reported by both suites rather
    than found later in a caption."""
    assert set(HANDLE_SENTINELS) == set(SENTINELS), (
        "postroll.caption_blocks.HANDLE_SENTINELS and "
        "tests/fixtures/real_handle.json disagree about which words mean 'I "
        "looked and there is no Instagram'. Swift holds a third copy in "
        "PythonBridge.handleSentinels, which RealHandleTests holds to the same "
        "file, so all three move together or none of them do.")


def test_every_shared_sentinel_is_refused_by_the_predicate():
    """The list and the predicate are checked separately above and here,
    because a list nothing reads is not a rule: an entry could be added to the
    fixture and to both sides and still let the word through (L46)."""
    for word in SENTINELS:
        assert is_real_handle(word) is False, (
            f"{word!r} is listed as a sentinel and is_real_handle admits it")


@pytest.mark.parametrize("case", CASES, ids=lambda c: c["value"] or "<empty>")
def test_real_handle(case):
    assert is_real_handle(case["value"]) is case["real"], case["why"]


# ── one answer, one list, on the Python side (#926) ───────────────────────────
#
# The fixture above holds each side's list to one contract, which is what stops
# the two sides drifting. It cannot stop a THIRD copy appearing inside Python,
# and that is what actually happened here: `generate_captions._is_real_handle`
# sat beside the real one for months, named for the same question, answering it
# differently, and reading as a live second answer for anyone who found it. A
# shared name is read as evidence of shared behaviour (L263), so nobody compared
# them.
#
# These fail the class rather than the instance (L30): not "that one function is
# gone" but "Python answers this once".

A_REAL_HANDLE_DEFINITION = re.compile(r"^\s*def\s+_?is_real_handle\b", re.MULTILINE)
A_SENTINEL_LIST_ASSIGNMENT = re.compile(r"^\s*HANDLE_SENTINELS\s*=", re.MULTILINE)

PACKAGE = Path(__file__).resolve().parent.parent / "postroll"


def python_sources() -> list[Path]:
    """Every module in the package.

    Refuses an empty walk rather than returning nothing, because a sweep with
    nothing in it objects to nothing and would report a clean tree (L98).
    """
    found = sorted(PACKAGE.rglob("*.py"))
    assert found, f"no Python sources under {PACKAGE}, so these guards swept nothing"
    return found


def files_matching(pattern: re.Pattern[str]) -> list[str]:
    return [str(path.relative_to(PACKAGE.parent))
            for path in python_sources()
            if pattern.search(path.read_text(encoding="utf-8"))]


def test_python_defines_the_real_account_predicate_once():
    """`caption_blocks.is_real_handle` is the answer, and it is the only one."""
    assert files_matching(A_REAL_HANDLE_DEFINITION) == ["postroll/caption_blocks.py"], (
        "more than one Python module defines a real-account predicate. Two "
        "functions named for one question is what #926 was filed about: "
        "generate_captions._is_real_handle checked the sentinel half only, so "
        "'DPR Dance' passed it, while caption_blocks.is_real_handle refused it. "
        "Call the one in caption_blocks rather than writing a second answer.")


def test_python_spells_the_sentinel_list_once():
    """A third spelling is the defect #917 half fixed, so it is guarded rather
    than left to the comment that asks for it."""
    assert files_matching(A_SENTINEL_LIST_ASSIGNMENT) == ["postroll/caption_blocks.py"], (
        "more than one Python module assigns HANDLE_SENTINELS. Import it from "
        "caption_blocks: Swift already keeps a second copy it cannot read, and "
        "tests/fixtures/real_handle.json holds those two together, so a third "
        "is held to nothing.")
