#!/usr/bin/env python3
"""Whether two recorded fixtures say the same MEASUREMENT (#1392).

    python3 tools/same_measurement.py <a.json> <b.json>

Exit 0 they measure the same thing, 1 they do not, 2 one of them could not be
read. Three codes rather than two, because the caller reads "different" as
"commit and push it": an unreadable record must not take that branch by
accident, and it must not take the quiet one either (L11, L98).

## Why this exists

`tools/propose_recorded_change.sh` asked whether there was anything to add to
today's proposal with `git diff --cached --quiet` over the whole record file.
Every recorder stamps WHICH run produced the reading and WHEN, and those fields
move on every run whether the number did or not. So a re-run that measured the
identical number still wrote a different file, still committed, and moved the
open proposal's head away from the commit its checks belonged to.

Measured 2026-09-05 on PR #1383: three commits in half an hour, every one
recording 3175 tests, differing only in `measured_at_commit` and
`measured_from_run`. One of those greens was refused at the merge because the
branch had moved under it, and the script's own "already carries this record"
branch, written to prevent exactly this, could never be reached.

L40 is the same comparison failing the other way, and reading it as "compare
the whole file" is what produces this one.

## What is provenance and what is not

`re_measure_with` is NOT provenance. It names the command that retakes the
reading, so it is part of what the record SAYS, and a change to it is a real
change worth proposing.

`runs`, `passes` and `samples` are NOT provenance either. They say what a
figure was measured over, which is the whole point of #1328, and a record that
changed its sample size changed what it claims.

Deliberately NOT shared with `check_figures_say_their_sample.PROVENANCE_KEYS`,
which is a wider set answering a different question: whether a fixture claims
to record something somebody measured at all. That set includes `runs` and
`machine` precisely because they mark a file as a record, and folding the two
together would make this one ignore a changed sample size. Two questions, two
sets (L342).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

#: Fields saying WHICH run a reading came from and WHEN, rather than what was
#: measured. Matched by exact name at any depth, because the rule is about what
#: the field MEANS and not about where a record happens to put it.
PROVENANCE_ONLY = frozenset({
    "measured",
    "measured_at_commit",
    "measured_from",
    "measured_from_run",
    "measured_on",
})


class Unreadable(Exception):
    """A record could not be read, which is not the same as it being unchanged.

    Its own type so it can never be answered with True or False: both of those
    are claims about what the records SAY, and this is the case where one of
    them says nothing at all.
    """


def measurement_of(node):
    """`node` with every provenance-only field removed, at any depth."""
    if isinstance(node, dict):
        return {key: measurement_of(value) for key, value in node.items()
                if key not in PROVENANCE_ONLY}
    if isinstance(node, list):
        return [measurement_of(item) for item in node]
    return node


def _load(path: Path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise Unreadable(f"{path} is not there") from None
    except (json.JSONDecodeError, UnicodeDecodeError, OSError) as bad:
        raise Unreadable(f"{path} could not be read: {bad}") from bad


def same_measurement(a: Path, b: Path) -> bool:
    """Whether the two records measure the same thing."""
    return measurement_of(_load(a)) == measurement_of(_load(b))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("a", type=Path)
    parser.add_argument("b", type=Path)
    args = parser.parse_args(argv)

    try:
        return 0 if same_measurement(args.a, args.b) else 1
    except Unreadable as refusal:
        print(f"same_measurement: {refusal}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
