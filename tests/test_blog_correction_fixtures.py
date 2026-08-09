"""#204: Dan's two hand-corrected posts, as regression fixtures.

Those before and after pairs are the only concrete evidence of what the blog
generator actually gets wrong, and they lived in an issue body, where nothing
stopped a prompt change that fixed one failure from reintroducing another.

The pairs are lifted from the stored blog output (`generated_body` is the
draft, `body` is Dan's correction), so they are measured from real work rather
than shaped by hand to make a check fire.

What is asserted:

1. Every rule claimed for a draft actually fires on it, so no rule ships
   without a case that has been seen to fail on real output.
2. The correction is substantially cleaner than the draft.
3. The findings that STILL fire on a correction match exactly what is recorded,
   with a written reason each. That pins the checker's false-positive rate,
   so a new one appears as a failure rather than blending into the noise.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.ai.blog_quality import check_blog

FIXTURE_DIR = Path(__file__).parent / "fixtures" / "blog_corrections"
EXPECTATIONS = json.loads((FIXTURE_DIR / "expectations.json").read_text())["pairs"]


def _load(pair):
    data = json.loads((FIXTURE_DIR / pair["fixture"]).read_text())
    return data, pair


def _codes(findings):
    return {f.code for f in findings}


def _check(data, key):
    return check_blog(data[key], program=data["program"], venue=data["venue"])


PAIRS = [_load(p) for p in EXPECTATIONS]
IDS = [p["fixture"].replace(".json", "") for p in EXPECTATIONS]


@pytest.mark.parametrize("data,pair", PAIRS, ids=IDS)
def test_the_fixture_holds_a_real_pair(data, pair):
    """A fixture that lost its content would assert nothing while staying green."""
    assert len(data["draft"]) > 1000, "the draft looks truncated"
    assert len(data["corrected"]) > 500, "the correction looks truncated"
    assert data["draft"] != data["corrected"]
    assert data["venue"], "the venue drives two of the alt text checks"


@pytest.mark.parametrize("data,pair", PAIRS, ids=IDS)
def test_every_claimed_rule_fires_on_the_draft(data, pair):
    """No rule ships without a real draft that breaks it."""
    fired = _codes(_check(data, "draft"))
    missing = sorted(set(pair["draft_must_fire"]) - fired)
    assert not missing, (
        f"these rules are claimed for this draft but did not fire: {missing}. "
        f"What did fire: {sorted(fired)}"
    )


@pytest.mark.parametrize("data,pair", PAIRS, ids=IDS)
def test_the_correction_is_substantially_cleaner(data, pair):
    draft = _check(data, "draft")
    corrected = _check(data, "corrected")
    assert len(corrected) < len(draft) / 3, (
        f"the correction should clear most of the draft's findings: "
        f"{len(draft)} to {len(corrected)}"
    )


@pytest.mark.parametrize("data,pair", PAIRS, ids=IDS)
def test_the_rules_the_correction_fixed_stay_fixed(data, pair):
    """Every rule the draft broke and the correction resolved must stay
    resolved. This is the regression the issue is about: a later prompt change
    that reintroduces one of these has to fail here."""
    accepted = set(pair["accepted_on_corrected"])
    should_be_gone = set(pair["draft_must_fire"]) - accepted
    still_firing = _codes(_check(data, "corrected")) & should_be_gone
    assert not still_firing, (
        f"the correction fixed these and they have come back: {sorted(still_firing)}"
    )


@pytest.mark.parametrize("data,pair", PAIRS, ids=IDS)
def test_no_unrecorded_finding_fires_on_a_finished_post(data, pair):
    """Anything firing on a post Dan considered finished is either a real miss
    or a false positive, and both need to be written down. A new one appearing
    unannounced is how an alert starts crying wolf."""
    fired = _codes(_check(data, "corrected"))
    unrecorded = sorted(fired - set(pair["accepted_on_corrected"]))
    assert not unrecorded, (
        f"new findings on the corrected post: {unrecorded}. Either the check "
        "found something real, or it is a false positive. Record it in "
        "expectations.json with the reason."
    )


@pytest.mark.parametrize("data,pair", PAIRS, ids=IDS)
def test_a_recorded_acceptance_that_no_longer_fires_must_be_removed(data, pair):
    """Otherwise the list of known false positives silently becomes fiction,
    and the count stops meaning anything."""
    fired = _codes(_check(data, "corrected"))
    stale = sorted(set(pair["accepted_on_corrected"]) - fired)
    assert not stale, (
        f"these no longer fire, so the checker improved: {stale}. Remove them "
        "from expectations.json so the accepted list stays honest."
    )


@pytest.mark.parametrize("data,pair", PAIRS, ids=IDS)
def test_every_acceptance_carries_a_reason(data, pair):
    for code, reason in pair["accepted_on_corrected"].items():
        assert len(reason.strip()) > 40, f"{code} is accepted without a real reason"
