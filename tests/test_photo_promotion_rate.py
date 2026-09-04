"""#1278: the recorded rate at which the photo promotion suggestion fires.

`CollaboratorPick.photoToPromote` fires whenever ANY later photograph carries a
stronger account than the first. The broad trigger was deliberate (#983): a
"much stronger" threshold would be a second constant calibrated against a
population nobody had measured. The cost is noise, and since #964 the
collaborator panel renders on every posting day, so a suggestion appearing on
most posts would sit above the findings that need judgement and teach everybody
to skip the panel (L36).

The reading itself is taken by `PhotoPromotionRateMeasurement`, which runs the
SHIPPING predicate against a copy of the live store. This holds what it recorded
to being readable and internally consistent, so the number cannot rot into
something nobody can interpret.
"""

from __future__ import annotations

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RECORD = REPO_ROOT / "tests" / "fixtures" / "photo_promotion_rate.json"

#: Every count the reading has to carry to mean anything.
#:
#: `days_it_could_rank_two_photographs` is the one that makes the rest
#: interpretable: a zero out of 35 reads as a narrow trigger when most of those
#: days simply carry no tagged photograph, and that is not a finding about the
#: trigger at all (L98).
REQUIRED = (
    "measured_on",
    "events",
    "accounts_carrying_figures",
    "collage_carousel_days",
    "days_with_any_tagged_photograph",
    "days_it_could_rank_two_photographs",
    "days_it_fired_on",
)


def record() -> dict:
    return json.loads(RECORD.read_text(encoding="utf-8"))


def test_the_reading_carries_every_count_it_needs():
    held = record()
    missing = [name for name in REQUIRED if name not in held]

    assert not missing, (
        f"the recorded reading is missing {missing}, so it cannot be "
        f"interpreted: a rate with no denominator, or one with no count of the "
        f"days the trigger could reach at all, says nothing about the trigger")


def test_the_counts_narrow_rather_than_contradicting_each_other():
    """Each count is a subset of the one above it. A record that says the
    suggestion fired on more days than it could reach describes something that
    did not happen, and it would still be a number somebody plans from."""
    held = record()

    assert held["days_it_fired_on"] <= held["days_it_could_rank_two_photographs"]
    assert (held["days_it_could_rank_two_photographs"]
            <= held["days_with_any_tagged_photograph"])
    assert (held["days_with_any_tagged_photograph"]
            <= held["collage_carousel_days"])


def test_the_reading_was_taken_on_something():
    """A reading over no days at all is not a rate, and zero out of zero would
    report as a quiet trigger (L98, L182)."""
    held = record()

    assert held["collage_carousel_days"] > 0, (
        "the measurement found no collage carousel day to look at, so the rate "
        "is about nothing")
    assert held["accounts_carrying_figures"] > 0, (
        "no account carried figures, so the suggestion could not fire whatever "
        "the trigger is, and the rate says nothing about it")


def test_the_reading_says_when_it_was_taken_and_how_to_take_it_again():
    """A number with a date on it reads as MORE trustworthy, not less (L316),
    so the date is not enough on its own: the command that reproduces it has to
    be there too, or nobody can check it."""
    held = record()

    assert held["measured_on"].count("-") == 2, (
        f"{held['measured_on']!r} is not a date this can be compared against")
    prose = "\n".join(held.get("_comment", []))
    assert "POSTROLL_MEASURE_PROMOTION" in prose, (
        "the record does not say how to take the reading again, so it is a "
        "dated assertion rather than a measurement")


def test_the_reading_states_what_it_does_not_prove():
    """Six days is a small sample. A record that reported "it does not fire"
    without saying how little it was measured over would be read as settled
    (L244, L182)."""
    prose = "\n".join(record().get("_reading", []))

    assert "small sample" in prose, (
        "the record does not say that its population is small, so a later "
        "reader takes 'no noise' as proven rather than as measured once")
