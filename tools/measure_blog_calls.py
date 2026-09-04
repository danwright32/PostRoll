#!/usr/bin/env python3
"""Time the passes whose estimates were chosen rather than measured (#1189).

`BlogSection` showed "~2 to 5 min" for a blog revision and "~1 to 3 min" for a
photo swap. Both were picked. Since #1164 they sit beside `RepairRetryEstimate`,
which IS derived from timed calls, and a chosen figure standing next to a
measured one reads as a measurement.

`RunEstimate` now says which is which, in one place. This is the other half: the
thing that turns a chosen figure into a measured one.

## It costs money and it is not run on anybody's behalf

Every pass here is real Claude calls against a real event with real
photographs. `tools/measure_alt_text_call.py` records the precedent for that
kind of spend, and it records it as DAN'S DECISION on a named date, not as
something a tool did because it seemed reasonable. This is the same: it exists
so the reading can be taken when he decides to take it, and it does nothing
until then.

A TOOL and not a test, for that reason and because it reaches the live API,
which the suite may never do (L2).

    venv/bin/python tools/measure_blog_calls.py --pass blog --event <id>

## What it writes

`tests/fixtures/blog_call_timing.json`, appending. One reading is a sample of
one, and an estimate derived from a single call would be the same guess with a
date on it, which reads as MORE trustworthy rather than less (L316).

Once there are readings, `RunEstimate` takes its figure from them the way
`RepairRetryEstimate` does, and its provenance changes from `chosen` to
`measured`. That edit is one line in one file, which is the point of having
declared them there.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

RECORD = REPO_ROOT / "tests" / "fixtures" / "blog_call_timing.json"

#: The passes this can time, and what each one runs.
#:
#: Named rather than taking a module path, so it cannot be pointed at something
#: that costs a different amount than the person expected.
PASSES = {
    "blog": "postroll.ai.revise_blog",
    "photos": "postroll.ai.swap_blog_photos",
    "week": "postroll.ai.generate_week",
}

# The story graphics and the app update are NOT here, and that is the point.
#
# Neither is a Claude call this can start: the graphics are local rendering
# driven from the app, and the updater is a detached script that replaces the
# running app when it finishes. `RunEstimate` records both as chosen and not yet
# measurable, with the reason, rather than naming a `--pass` here that would
# fail after somebody had already agreed to spend (L109).


def record(pass_name: str, seconds: float, note: str) -> None:
    held = (json.loads(RECORD.read_text(encoding="utf-8"))
            if RECORD.exists() else {"_what": [], "readings": []})
    held.setdefault("readings", []).append({
        "pass": pass_name,
        "measured_on": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "seconds": round(seconds, 1),
        "note": note,
    })
    RECORD.parent.mkdir(parents=True, exist_ok=True)
    RECORD.write_text(json.dumps(held, indent=2) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--pass", dest="which", required=True,
                        choices=sorted(PASSES),
                        help="which pass to time")
    parser.add_argument("--event", required=True,
                        help="the event id to run it against")
    parser.add_argument("--note", default="",
                        help="anything about this run worth recording beside it")
    parser.add_argument("--i-mean-it", action="store_true",
                        help="required: this spends real Claude calls")
    args = parser.parse_args(argv)

    if not args.i_mean_it:
        # A refusal rather than a prompt, because a prompt handed to somebody in
        # a hurry is a yes. This costs money and nothing about the command line
        # otherwise says so.
        print(f"this runs {PASSES[args.which]} against event {args.event} for "
              f"real, which is paid Claude calls on real photographs. Add "
              f"--i-mean-it once you have decided to spend them.",
              file=sys.stderr)
        return 2

    started = time.monotonic()
    module = __import__(PASSES[args.which], fromlist=["run"])
    runner = getattr(module, "run", None)
    if runner is None:
        raise SystemExit(
            f"{PASSES[args.which]} has no `run`, so this does not know how to "
            f"start that pass. Nothing was timed and nothing was spent.")
    runner(args.event)
    elapsed = time.monotonic() - started

    record(args.which, elapsed, args.note)
    print(f"{args.which}: {elapsed:.1f}s, recorded in {RECORD.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
