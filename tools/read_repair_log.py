#!/usr/bin/env python3
"""What the app changed in one blog post (#1135).

Repairs are SILENT, so the review panel never says a rewrite happened. This is
where to find out, after the fact:

    venv/bin/python tools/read_repair_log.py "Greatest Hits"
    venv/bin/python tools/read_repair_log.py --all

A field with a writer and no reader is not evidence (L46). This is the reader,
and it ships in the same change as the writer.

Written in plain language rather than as a JSON dump, because the person reading
it wants to know what changed in a post, not what shape the record has.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from postroll.ai.repair_log import (  # noqa: E402
    RepairLogUnreadable, default_log_path, read_records)


def report(path: str | Path | None = None, *, event: str | None = None) -> int:
    try:
        records = read_records(path)
    except RepairLogUnreadable as e:
        # Said as what it is. "No repair records" here would be a claim that
        # nothing happened, about a file that is sitting right there (L10).
        print(f"The journal could not be read, so this says nothing about "
              f"whether the app changed anything.\n{e}", file=sys.stderr)
        return 2
    if event:
        records = [r for r in records if r.get("event") == event]

    if not records:
        # An empty answer is not a post with no repairs (L98).
        where = f" for {event}" if event else ""
        print(f"No repair records{where}. That means nothing has been recorded, "
              f"which is not the same as nothing having been changed: a post "
              f"generated before this journal existed leaves no trace here.")
        return 1

    after_refused = "(unchanged: the rewrite was refused)"

    for record in records:
        kind = record.get("kind")
        when = str(record.get("at", ""))[:19].replace("T", " ")
        who = record.get("event") or "(no event)"

        if kind == "attempt":
            outcome = record.get("outcome", "?")
            print(f"\n[{when}] {who}: {record.get('marker')}")
            print(f"  {outcome} ({', '.join(record.get('codes') or []) or 'no codes'})")
            print(f"  was:  {record.get('before')}")
            after = record.get("after")
            print(f"  now:  {after if after is not None else after_refused}")
            if record.get("reason"):
                print(f"  why:  {record['reason']}")
        elif kind == "declined":
            print(f"\n[{when}] {who}: declined to repair "
                  f"{record.get('code')}, which fired {record.get('fired')} "
                  f"time(s)")
            print(f"  reason: {record.get('reason')}")
            print(f"  tracked on {record.get('issue')}")
            print("  this counts how often the check FIRED. It says nothing "
                  "about whether it was right to.")
        elif kind == "pass":
            print(f"\n[{when}] {who}: {record.get('wording')}")
            print(f"  selected {record.get('selected')}, attempted "
                  f"{record.get('attempted')}, "
                  f"{record.get('remaining_seconds')}s of budget left")
            placed = record.get("placed") or []
            if placed:
                print(f"  the post placed {len(placed)} photograph(s): "
                      f"{', '.join(placed)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("event", nargs="?", help="The event name to report on")
    parser.add_argument("--all", action="store_true",
                        help="Every event in the journal")
    parser.add_argument("--path", type=Path, default=None,
                        help="A journal other than the app's own")
    args = parser.parse_args()

    if not args.event and not args.all:
        print(f"name an event, or pass --all. The journal is at "
              f"{default_log_path()}", file=sys.stderr)
        return 1
    return report(args.path, event=None if args.all else args.event)


if __name__ == "__main__":
    sys.exit(main())
