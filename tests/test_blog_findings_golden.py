"""#1133 (Phase 5a): the extraction changes no finding, in order or in wording.

`check_alt_text` is pulled out of `check_blog` so the repairer can re-run
exactly the rules that selected a marker. The claim that its output "stays byte
identical" is not something to assert; it is something to prove, and the
existing suite cannot.

`tests/test_blog_correction_fixtures.py` asserts through a SET of codes plus one
length ratio. Order, `message`, `detail`, and how many findings of one code fire
are all invisible to it, and those are exactly what the rest of this milestone is
load bearing on: `QualityFinding.id` embeds `detail`, the panel renders one
detail line per finding, and the repairer's whole argument is that `detail`
embeds the offender (L228).

The mechanism the golden is guarding: `check_blog` emits RULE major, not marker
major. A length loop over every marker, then a separate venue-and-performer
loop, then the openings pass, then a separate inferred-state loop, then a
separate appearance loop. Calling a per-marker function once per marker produces
MARKER major order and changes the ordered list, so the extraction buckets by
code and re-emits in the original rule order. The golden was recorded from the
pre-refactor code; nothing in this file was written to match the new one.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.ai.blog_quality import check_blog


FIXTURES = Path(__file__).parent / "fixtures"
GOLDEN = json.loads((FIXTURES / "blog_findings_golden.json").read_text(encoding="utf-8"))


def _cases():
    return sorted(GOLDEN["goldens"])


@pytest.mark.parametrize("case", _cases())
def test_the_findings_match_the_recorded_golden_exactly(case):
    fixture, key = case.split(".")
    data = json.loads((FIXTURES / "blog_corrections" / f"{fixture}.json")
                      .read_text(encoding="utf-8"))

    found = check_blog(data[key], program=data["program"], venue=data["venue"])
    actual = [[f.code, f.message, f.detail] for f in found]

    assert actual == GOLDEN["goldens"][case], (
        f"{case}: the findings moved. If this is a deliberate rule change, "
        f"re-record the golden and say what changed; if it is the check_alt_text "
        f"extraction, the re-emission order is wrong.")


def test_the_golden_is_not_vacuous():
    """A golden of empty lists would pass whatever the code did (L215)."""
    total = sum(len(v) for v in GOLDEN["goldens"].values())
    assert total > 50, f"the golden holds only {total} findings"
    assert any(GOLDEN["goldens"][c] for c in _cases())


def test_the_golden_records_order_and_not_just_membership():
    """The property the existing set-based suite cannot see.

    If every recorded list were already sorted, the golden would be asserting
    membership under another name and a marker-major re-emission would pass it.
    """
    ordered = GOLDEN["goldens"]["one_man_odyssey.draft"]
    codes = [row[0] for row in ordered]
    assert codes != sorted(codes), (
        "the golden's order is the same as its sorted order, so it cannot tell "
        "a rule-major re-emission from a marker-major one")


def test_the_golden_records_more_than_one_finding_of_some_code():
    """The other property a set cannot see: how MANY of a code fire."""
    codes = [row[0] for row in GOLDEN["goldens"]["one_man_odyssey.draft"]]
    assert any(codes.count(c) > 1 for c in set(codes)), (
        "no code fires twice in the golden, so it cannot notice a repair that "
        "turns one finding into two")
