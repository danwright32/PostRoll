"""#1134: every check code resolves to a repairer or to a WRITTEN reason.

There is no third state and no default branch. A default renders the next
finding code somebody adds as a deliberate decision nobody made, and a table
driven by a hand-written list checks only what the list names, so anything
missing from it is exempt from the very check meant to catch it (L96, L113,
L233).

The vocabulary is DERIVED from the `Finding(` literals in `blog_quality.py`,
following `tests/bridge_payload_keys.py`, which already does exactly this for
payload keys and REFUSES rather than guesses.

Every `NoRepairReason` carries a filed issue number as well as prose (L65,
L346). A component shipped deliberately inactive needs the issue that activates
it filed in the same change; without one the reason is read forever after as a
settled decision, and the next reader argues with the reason instead of
reopening the work. That is what happened to `_is_real_handle` here (#926,
#1105).
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

import pytest

from postroll.ai.blog_repair import REPAIRERS, NoRepairReason

QUALITY = Path(__file__).resolve().parent.parent / "postroll" / "ai" / "blog_quality.py"


def _declared_codes() -> set[str]:
    """Every code a `Finding(` literal in the checker can carry.

    Read through the AST, never a regex over the source, so a code surviving
    only in a comment or a docstring cannot keep an entry alive. Refuses on a
    computed code rather than guessing, for the reason `bridge_payload_keys`
    refuses: a code this could not read would be exempt from the completeness
    check without anything saying so.
    """
    tree = ast.parse(QUALITY.read_text(encoding="utf-8"), filename=str(QUALITY))
    codes: set[str] = set()
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call)
                and getattr(node.func, "id", None) == "Finding" and node.args):
            continue
        first = node.args[0]
        assert isinstance(first, ast.Constant) and isinstance(first.value, str), (
            f"a Finding() at line {node.lineno} is built with a computed code, "
            f"which this cannot read, so that code would be exempt from the "
            f"completeness check with nothing saying so")
        codes.add(first.value)
    return codes


def test_the_vocabulary_is_read_and_is_not_empty():
    codes = _declared_codes()
    assert len(codes) >= 14, sorted(codes)


def test_every_code_the_checker_can_produce_has_an_entry():
    missing = sorted(_declared_codes() - set(REPAIRERS))
    assert not missing, (
        f"these check codes resolve to nothing: {missing}. Every code gets a "
        f"repairer or a written reason it has none; there is no third state, "
        f"and no default branch, because a default renders a code nobody "
        f"decided about as a decision that was made.")


def test_the_table_names_no_code_the_checker_cannot_produce():
    """The other direction. An entry for a code nothing emits is dead, and it
    reads as coverage (L29)."""
    extra = sorted(set(REPAIRERS) - _declared_codes())
    assert not extra, (
        f"the table has entries for codes no Finding() literal produces: "
        f"{extra}")


@pytest.mark.parametrize("code", sorted(REPAIRERS))
def test_a_deferred_code_carries_a_reason_and_a_filed_issue(code):
    entry = REPAIRERS[code]
    if not isinstance(entry, NoRepairReason):
        return
    assert len(entry.reason.split()) >= 12, (
        f"{code}: \"{entry.reason}\" does not explain why this has no repairer. "
        f"The next person has to be able to tell a considered decision from an "
        f"oversight without doing the work again.")
    assert re.fullmatch(r"#\d+", entry.issue), (
        f"{code}: issue is {entry.issue!r}, which is not a filed issue number. "
        f"A component shipped deliberately inactive needs the issue that "
        f"activates it filed in the same change, or the reason is read forever "
        f"after as settled (L65, L346).")


def test_the_two_claim_deleting_codes_state_their_deferral_gate():
    """The gate has to be something that can be WRITTEN (L90).

    Conditioning a silent deleter on a false positive rate measured through the
    journal fails: a DECLINED record says the check FIRED, never that it fired
    WRONGLY, and rule 1 removed the surface where Dan might have said so. The
    rate would read as zero indistinguishably from a real reading.
    """
    for code in ("invented_number", "demographic_grouping"):
        entry = REPAIRERS[code]
        assert isinstance(entry, NoRepairReason), code
        assert entry.gate, f"{code} has no stated deferral gate"
        assert "hand review" in entry.gate or "mark" in entry.gate, entry.gate


def test_a_repaired_code_actually_names_a_repairer():
    """The control: if every entry were a NoRepairReason, the tests above would
    pass while nothing was repaired at all (L159)."""
    repaired = [c for c, e in REPAIRERS.items()
                if not isinstance(e, NoRepairReason)]
    assert len(repaired) >= 6, sorted(repaired)
    assert "alt_text_length" in repaired
    assert "alt_text_empty" in repaired


def test_a_second_literal_of_an_EXISTING_code_is_not_a_new_code():
    """The completeness check derives DISTINCT codes, not call sites.

    `invented_number` is already built from two `Finding(` literals, so a table
    keyed on call sites would have been wrong from the day it shipped. This is
    the second half of the guard mutation: adding a sixteenth literal of a code
    the table already names must NOT go red.
    """
    tree = ast.parse(QUALITY.read_text(encoding="utf-8"))
    literals = [n.args[0].value for n in ast.walk(tree)
                if isinstance(n, ast.Call)
                and getattr(n.func, "id", None) == "Finding" and n.args
                and isinstance(n.args[0], ast.Constant)]

    assert len(literals) > len(set(literals)), (
        "every code is built from exactly one literal, so this test cannot "
        "tell a distinct-code check from a call-site one; if that is a "
        "deliberate change, the guard mutation for this needs re-checking")
    assert set(literals) <= set(REPAIRERS)
