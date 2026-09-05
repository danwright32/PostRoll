#!/usr/bin/env python3
"""The rates the repair journal already holds (#1157, #1168).

    venv/bin/python tools/measure_repair_rates.py [--within-days 7] [--path P]

#1157 is done when three real blog generations have been read back and the
per-check firing rate on those repairs recorded with the date. #1168 needs the
share of attempts ending `blocked` over a recent window, and says plainly that
its threshold has to be measured against the real distribution before it is set
(L172). Both are the same arithmetic over the same journal, so this is one
reading rather than two.

It COUNTS and does not judge. No threshold lives here, because the distribution
it would be set against has never been measured: as of 2026-09-05 the live
journal is empty and the only surviving records are test pollution, every one
of whose 43 `blocked` outcomes is synthetic. A threshold picked now would be a
number nobody measured, wearing the authority of a signal (L172, L1).

`tools/read_repair_log.py` stays the reader for "what did the app change in
this post": one narrative paragraph per record, which is the right shape for
that question and the wrong one for a rate. Counting a rate off its output by
hand is the second definition, beside the code, that drifts towards whatever
flatters the argument (L107).

Prints COUNTS only, never a repaired sentence and never an event name. A
privacy guard that scans the repository cannot see what a tool PRINTS, so a
reading over the live journal otherwise delivers a real post's prose and a real
venue into a transcript by a route nothing inspects (L222).
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from postroll.ai.repair_log import (  # noqa: E402
    RepairLogUnreadable, default_log_path, read_records)


class EmptyJournal(Exception):
    """Nothing has been written to the journal.

    Its own type, and never an empty `Rates`. Zero attempts and zero blocked
    reads exactly like a repair pass that met nothing wrong, and those are
    opposite facts: one is a healthy run, the other is no run at all (L98).
    Distinct from `RepairLogUnreadable`, which the reader raises and this does
    not catch, because a journal that is there and cannot be read is a third
    state again (L11).
    """


@dataclass(frozen=True)
class Rates:
    """What the journal says, counted. Every share names its denominator."""

    attempts: int
    #: Attempts per outcome. A state nothing recorded is ABSENT rather than
    #: zero, because zero is the positive claim that the pass met it.
    by_outcome: dict[str, int]
    #: Attempts each finding code fired on, and how many of those ended
    #: repaired. Counted per ATTEMPT, so one attempt against three findings is
    #: one for each of the three rather than three of anything.
    by_code: dict[str, int] = field(default_factory=dict)
    repaired_by_code: dict[str, int] = field(default_factory=dict)
    #: Attempts carrying no timestamp, kept in the count and named here.
    #: Dropping them would shrink the denominator every share is over, quietly.
    undated: int = 0
    within_days: int | None = None

    def share(self, outcome: str) -> float | None:
        """The share of attempts ending `outcome`, or None if none did.

        None rather than 0.0, for the same reason the outcome is absent from
        the map: a rate of zero is a measurement and this is the absence of one.
        """
        if outcome not in self.by_outcome or not self.attempts:
            return None
        return self.by_outcome[outcome] / self.attempts


def _lines_in(target: Path) -> int:
    """Non-blank lines in the journal, to tell corrupt from absent."""
    try:
        return sum(1 for line in target.read_text(encoding="utf-8").splitlines()
                   if line.strip())
    except OSError:
        return 0


def _within(record: dict, since: datetime | None) -> tuple[bool, bool]:
    """Whether the record is inside the window, and whether it is undated."""
    stamp = record.get("at")
    if not stamp:
        return True, True
    if since is None:
        return True, False
    try:
        return datetime.fromisoformat(str(stamp)) >= since, False
    except ValueError:
        # A stamp that cannot be parsed is kept for the same reason an absent
        # one is: silently dropping it moves the denominator.
        return True, True


def read_rates(path: str | Path | None = None, *, now: datetime | None = None,
               within_days: int | None = None) -> Rates:
    """Count the journal at `path`, optionally over the last `within_days`."""
    target = Path(path) if path is not None else default_log_path()
    records = read_records(path)
    if not records:
        # A journal whose every line is corrupt arrives here as no records,
        # because `read_records` SKIPS a line it cannot parse, deliberately, so
        # that one bad line does not hide every good one. That is right per
        # line and wrong in the aggregate: nothing written and nothing readable
        # are opposite facts, and only one of them is a healthy pass (L11, L98).
        if _lines_in(target):
            raise RepairLogUnreadable(
                f"{target} holds {_lines_in(target)} line(s) and not one of "
                f"them could be read as a record. That is the evidence of "
                f"every repair pass being unavailable, not a journal nothing "
                f"has written to.")
        raise EmptyJournal(
            f"{target} holds no records, so every count below would be zero "
            "and that reads exactly like a repair pass that met nothing "
            "wrong. Nothing was measured.")

    at = now if now is not None else datetime.now(timezone.utc)
    since = at - timedelta(days=within_days) if within_days else None

    outcomes: Counter[str] = Counter()
    codes: Counter[str] = Counter()
    repaired: Counter[str] = Counter()
    attempts = undated = 0
    for record in records:
        if record.get("kind") != "attempt":
            continue
        inside, no_date = _within(record, since)
        if not inside:
            continue
        attempts += 1
        undated += 1 if no_date else 0
        outcome = str(record.get("outcome") or "")
        if outcome:
            outcomes[outcome] += 1
        for code in sorted(set(record.get("codes") or [])):
            codes[code] += 1
            if outcome == "repaired":
                repaired[code] += 1

    if not attempts:
        raise EmptyJournal(
            f"{path or default_log_path()} holds records but no repair "
            "attempts"
            + (f" in the last {within_days} days" if within_days else "")
            + ", so there is nothing to take a rate over. Nothing was measured.")

    return Rates(attempts=attempts, by_outcome=dict(outcomes.most_common()),
                 by_code=dict(codes.most_common()),
                 repaired_by_code=dict(repaired.most_common()),
                 undated=undated, within_days=within_days)


def render(rates: Rates) -> str:
    """The counts, with the denominator on the page beside every share."""
    window = (f", over the last {rates.within_days} days"
              if rates.within_days else "")
    lines = [f"{rates.attempts} attempts{window}"]
    if rates.undated:
        lines.append(f"  {rates.undated} of them carry no timestamp and are "
                     f"counted anyway, so the window does not silently shrink "
                     f"the denominator")

    lines += ["", "OUTCOME, as a share of attempts:"]
    for outcome, count in rates.by_outcome.items():
        lines.append(f"  {outcome:<12} {count:>5} of {rates.attempts} "
                     f"({count / rates.attempts * 100:.0f}%)")
    lines.append("  a state absent here was never recorded, which is not the "
                 "same as recorded zero times")

    lines += ["", "CHECK, attempts each finding fired on and how many ended "
                  "repaired:"]
    for code, count in rates.by_code.items():
        mended = rates.repaired_by_code.get(code, 0)
        lines.append(f"  {code:<44} {count:>5} fired, {mended:>5} repaired "
                     f"({mended / count * 100:.0f}%)")

    lines += ["",
              "No threshold is applied. #1168's would have to be measured "
              "against this",
              "distribution first, and as of 2026-09-05 nothing real had been "
              "recorded to",
              "measure it against (L172)."]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--path", type=Path, default=None,
                        help="a journal other than the app's own")
    parser.add_argument("--within-days", type=int, default=None,
                        help="count only attempts from the last N days")
    args = parser.parse_args(argv)

    try:
        print(render(read_rates(args.path, within_days=args.within_days)))
    except EmptyJournal as refusal:
        print(refusal, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
