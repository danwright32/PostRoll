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


def test_the_two_claim_deleting_codes_record_how_their_gate_was_answered():
    """The gate had to be something that could be WRITTEN (L90), and it was.

    Conditioning a silent deleter on a false positive rate measured through the
    journal fails: a DECLINED record says the check FIRED, never that it fired
    WRONGLY, and rule 1 removed the surface where Dan might have said so. The
    rate would read as zero indistinguishably from a real reading.

    So the gate offered two writable answers, and the first was taken: a hand
    review of a stated number of real posts, with the count and the date. This
    asserts the ANSWER is recorded, not that the question is still open. A test
    still demanding an open gate would be the guard defending a decision that
    has since been made (L252).
    """
    for code in ("invented_number", "demographic_grouping"):
        entry = REPAIRERS[code]
        assert isinstance(entry, NoRepairReason), code
        assert entry.settled, (
            f"{code}: the deferral gate was answered by hand review, so this "
            f"entry has to say so; a reason still reading as pending sends the "
            f"next reader to redo a review that was already done (L346).")
        assert "hand review" in entry.settled, entry.settled


def _settled() -> list[str]:
    return [c for c, e in REPAIRERS.items()
            if isinstance(e, NoRepairReason) and e.settled]


def test_at_least_one_reason_is_settled():
    """The control, before the two tests below can mean anything (L159).

    Both are parametrized over `_settled()`, and pytest SKIPS a parametrized
    test with an empty parameter set rather than failing it, so with nothing
    settled they report as skipped and judge nothing at all.

    Only this direction is asserted. The mirror ("some reason is still
    pending") is deliberately absent rather than overlooked (L233): every
    reason being settled is a legitimate end state, and it is precisely the end
    state #1149 to #1154 were filed to reach, so asserting a pending entry
    exists would be asserting that those issues can never all be closed.
    """
    assert _settled(), (
        "no reason is marked settled, so both tests below skip and judge "
        "nothing")


@pytest.mark.parametrize("code", sorted(_settled()))
def test_a_settled_reason_records_when_and_on_what_evidence(code):
    """A settled decision is only settled if it says what settled it.

    `issue` alone cannot carry this. A closed issue number and an open one read
    identically in the source, so an entry that merely names an issue is read
    as pending forever after, and the next reader reopens a question that was
    answered (L65, L346). The date matters for the same reason a premise does:
    a decision is only true as of the evidence it was made on, and that
    evidence has to be re-measurable rather than asserted (L61, L316).
    """
    entry = REPAIRERS[code]
    assert re.search(r"\d{4}-\d{2}-\d{2}", entry.settled), (
        f"{code}: settled reads {entry.settled!r} with no date. A decision "
        f"carries the date of the evidence it was made on, or nothing can "
        f"tell whether that evidence still holds.")
    without_dates = re.sub(r"\d{4}-\d{2}-\d{2}", "", entry.settled)
    assert re.search(r"\b\d+\b", without_dates), (
        f"{code}: settled names no count once its date is removed. The gate "
        f"was a review of a STATED number of real posts, and a review with no "
        f"number is an opinion. Matching before stripping the date would let "
        f"the date's own digits answer this check (L178).")


@pytest.mark.parametrize("code", sorted(_settled()))
def test_a_settled_reason_states_no_outstanding_gate(code):
    """Settled and gated are contradictory states, and the pair reads as both.

    An entry carrying a gate says work is waiting on a condition; one carrying
    `settled` says the decision is made. Together they say a decision was made
    while something is still waiting, which is the state that produced #926 and
    #1105 in this repo.
    """
    entry = REPAIRERS[code]
    assert not entry.gate, (
        f"{code} is marked settled but still states a gate: {entry.gate!r}. "
        f"Fold what the gate asked into `settled` and say how it was answered.")


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
