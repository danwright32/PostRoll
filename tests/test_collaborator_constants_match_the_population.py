"""The ranking's two numbers are what the committed population computes (#1005).

`CollaboratorPick.livelinessFloor` and `assumedRate` are the whole of #1005's
ranking behaviour, and both were measured against a population that lives in
`tests/fixtures/account_population.json` (#1114).

Two numbers maintained in two languages drift, and this one drifts silently:
the Swift constant goes on producing a ranking whatever the data says, and
nothing anywhere reports that the figure it was fitted to has moved. So the
Swift source is held to the Python derivation, the way the palette and crop
anchor parity guards already hold their pairs.

This is what makes #1114 worth having. Without it the population is committed
and read by nobody, which is a file written and never used (L46).
"""

from __future__ import annotations

import re
from pathlib import Path

from postroll.ai.collaborator_metric import assumed_rate, liveliness_floor, load

REPO = Path(__file__).resolve().parent.parent
PICK = REPO / "PostRollApp" / "Sources" / "Services" / "CollaboratorPick.swift"

#: How far the shipped constant may sit from the recomputed figure.
#:
#: The constants are rounded for reading (0.0037 against 0.003713...), so an
#: exact match would fail on the rounding rather than on any drift. This is
#: wide enough for that and narrow enough that a population which has really
#: moved turns it red.
TOLERANCE = 0.0005


def swift_constant(name: str) -> float:
    text = PICK.read_text(encoding="utf-8")
    found = re.search(rf"static let {name} = (0\.\d+)", text)
    assert found, (
        f"{name} is not declared in CollaboratorPick.swift as a literal, so "
        "nothing here can hold it to the population it was fitted to. If it "
        "moved or was renamed, this check has to move with it.")
    return float(found.group(1))


def test_the_liveliness_floor_is_the_populations_tenth_percentile():
    computed = liveliness_floor(load())
    shipped = swift_constant("livelinessFloor")

    assert abs(shipped - computed) < TOLERANCE, (
        f"the app demotes accounts below {shipped:.2%} but the committed "
        f"population puts its 10th percentile at {computed:.2%}. Either the "
        "population has moved and the constant has to be re-chosen, or the "
        "constant was changed without re-measuring. Run "
        "`venv/bin/python -m postroll.ai.collaborator_metric`.")


def test_the_assumed_rate_is_the_populations_band_quartile():
    computed = assumed_rate(load())
    shipped = swift_constant("assumedRate")

    assert abs(shipped - computed) < TOLERANCE, (
        f"the app scores an account Meta refused at {shipped:.2%} but the "
        f"committed population puts that quartile at {computed:.2%}. That "
        "number is applied to real accounts and rendered as an assumption, so "
        "it has to be the assumption the data actually supports.")


def test_the_two_numbers_are_not_the_same_number():
    # A guard that read one constant for both would pass the two checks above
    # while proving only one of them (L178).
    assert swift_constant("livelinessFloor") != swift_constant("assumedRate")
