#!/usr/bin/env python3
"""How far along is the evidence for letting the fetch write NO_SUCH_ACCOUNT?

`postroll/ai/account_numbers.py` can produce `NO_SUCH_ACCOUNT` and is not
allowed to write it: `allow_no_such_account=False` is the default, and an absent
verdict is recorded as `would_have_been` while the outcome reported is
`COULD_NOT_CLASSIFY`.

That gate is off for a good reason. `NO_SUCH_ACCOUNT` is TERMINAL: nothing ever
asks about that account again, so a wrong one is unrecoverable by design and
invisible afterwards. One observe cycle, over 122 handles on 2026-09-01,
produced exactly one absent verdict, and one observation cannot calibrate an
outcome with no way back (L248).

## What this is for

#1195 says what done looks like: absent verdicts observed across several cycles,
on a population that is not the same handles every time, with the count and the
dates recorded. Nothing recorded them. `would_have_been` was set on every cycle
and read by nobody, so the one observation survived only as a sentence somebody
typed into the issue (L46).

So the cycles accumulate now, and this says where the evidence has got to. It
does not switch anything on. The issue is explicit about that, and it is right:
the first version of this same classifier passed every invented fixture and
matched nothing at all in the real world.

## What it will not do

Answer "ready" on cycles that asked about the same handles every time. A
population that never changes is one population observed repeatedly, which is
the sample size the issue is warning about wearing a different hat (L354).

    venv/bin/python tools/check_no_such_account_calibration.py
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
OBSERVATIONS = REPO_ROOT / "tests" / "fixtures" / "no_such_account_observations.json"

#: How many cycles count as "several".
#:
#: Three, and the reason is the shape of the risk rather than a convention. The
#: verdict is terminal and a wrong one is invisible afterwards, so what is being
#: established is that the classifier's absent verdict is RARE and STABLE.
#: Two cycles cannot show stability, because any two readings agree or disagree
#: with nothing to say which is typical.
CYCLES_WANTED = 3

#: How many handles a later cycle has to bring that the one before it did not.
#:
#: The issue asks for "a population that is not the same 122 handles every
#: time". Twenty is a sixth of that population, which is enough that the second
#: reading is not simply the first one repeated, and low enough that an ordinary
#: week of new tags reaches it.
NEW_HANDLES_WANTED = 20


def observations(path: Path | None = None) -> list[dict]:
    """Every recorded cycle.

    `path` resolves HERE rather than as a default argument, because a default
    binds once when the function is defined: a caller replacing `OBSERVATIONS`
    on this module would be ignored, and the check that this reports the dates
    and counts could never drive it (L196, L284).
    """
    path = path or OBSERVATIONS
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8")).get("cycles", [])


def verdict(cycles: list[dict]) -> tuple[bool, list[str]]:
    """`(ready, why not)`. Never `(True, [...])`."""
    reasons: list[str] = []
    if len(cycles) < CYCLES_WANTED:
        reasons.append(
            f"{len(cycles)} observe cycle(s) recorded, {CYCLES_WANTED} wanted. "
            f"A terminal verdict cannot be calibrated on a sample that cannot "
            f"show whether it is stable")

    moved = [c for c in cycles[1:]
             if (c.get("new_since_last") or 0) >= NEW_HANDLES_WANTED]
    if len(cycles) > 1 and not moved:
        reasons.append(
            f"no cycle brought {NEW_HANDLES_WANTED} handles the one before it "
            f"had not seen, so this is one population observed several times "
            f"rather than several populations")

    absent = sum((c.get("would_have_been") or {}).get("no_such_account", 0)
                 for c in cycles)
    if absent == 0 and cycles:
        reasons.append(
            "no absent verdict has been seen at all across the recorded "
            "cycles, so there is nothing to calibrate and switching the gate "
            "on would change nothing while reading as a decision")

    return (not reasons, reasons)


def main(argv: list[str] | None = None) -> int:
    argparse.ArgumentParser(description=__doc__.split("\n")[0]).parse_args(argv)
    cycles = observations()

    if not cycles:
        # Distinct from "not enough yet". No record at all means the observe
        # cycle has not been run since it started recording, which is a
        # different thing to do about it (L11).
        print("::notice::no observe cycle has been recorded yet. Run "
              "tools/measure_account_population.py to take one.")
        return 0

    absent = sum((c.get("would_have_been") or {}).get("no_such_account", 0)
                 for c in cycles)
    asked = sum(c.get("asked", 0) for c in cycles)
    print(f"{len(cycles)} cycle(s), {asked} handles asked about, "
          f"{absent} absent verdict(s) that would have been written")
    for cycle in cycles:
        print(f"  {cycle.get('measured_on')}: {cycle.get('asked')} asked, "
              f"{(cycle.get('would_have_been') or {}).get('no_such_account', 0)} "
              f"absent, {cycle.get('new_since_last')} new since the last")

    ready, why = verdict(cycles)
    if ready:
        print("::notice::the evidence #1195 asks for is now recorded. Deciding "
              "to switch allow_no_such_account on is a person's call, not this "
              "tool's.")
    else:
        for reason in why:
            print(f"not ready: {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
