"""Re-measure the account population the collaborator metric is fitted to (#1114).

Reads every handle the live store has tagged, asks Meta about each one through
the SHIPPING fetch module, and writes an ANONYMISED population to
`tests/fixtures/account_population.json`.

Through the shipping module deliberately. A probe written beside the code is a
second implementation that drifts, and the first calibration of
`account_numbers.py` found three defects that every invented fixture had passed:
the numbers here have to come from the thing that actually runs.

No handle ever reaches the output file or the terminal. A tool that reads a
live system delivers real names into transcripts, scrollback and logs by a
route no repository scanner can see (L222), and an issue written with real
evidence is what whoever implements it copies into fixtures (L155). The
identities are not needed to compute a percentile.

    venv/bin/python tools/measure_account_population.py

Costs one Meta call per handle, plus one profile page fetch per refusal. The
allowance is a rolling hour and 122 handles spent about a quarter of it, so
this is not a thing to run in a loop.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from postroll.ai.account_numbers import Outcome, fetch  # noqa: E402
from postroll.ai.collaborator_metric import POPULATION, load, summary  # noqa: E402
from postroll.ai.meta_app import TOKEN_ENV_VAR  # noqa: E402

#: Values stored in a handle field that are not handles.
#:
#: `unknown` is what the caption pipeline records when a lookup found nobody,
#: and the rest are what a person types in the same spirit.
SENTINELS = frozenset({"unknown", "none", "n/a", "na", "tbd", "null", "tba"})

#: What a real Instagram handle can be made of.
HANDLE = re.compile(r"[a-z0-9._]{2,30}")


def handles_in(value: object) -> set[str]:
    """Every handle a stored field holds, however the field spells it.

    Bare, at prefixed, a comma or space separated list, or a pasted profile
    URL. One reader for all of them, because a second spelling handled in one
    place and missed in another is how a population silently loses members.
    """
    found: set[str] = set()
    if isinstance(value, str):
        for part in re.split(r"[,\s]+", value):
            part = part.strip().lower()
            part = re.sub(r"^https?://(www\.)?instagram\.com/", "", part)
            part = part.strip("@/")
            if part and part not in SENTINELS and HANDLE.fullmatch(part):
                found.add(part)
    elif isinstance(value, list):
        for item in value:
            found |= handles_in(item)
    elif isinstance(value, dict):
        for item in value.values():
            found |= handles_in(item)
    return found


def harvest(events: list[dict]) -> list[str]:
    """Every account the events tag, from the four places one can be stored."""
    found: set[str] = set()
    for event in events:
        found |= handles_in(event.get("eventHandles", ""))
        for day in (event.get("days") or {}).values():
            found |= handles_in(day.get("tagHandles", []))
            found |= handles_in(day.get("photoTags", {}))
        for performer in ((event.get("ocrResult") or {}).get("performers") or []):
            found |= handles_in(performer.get("handle", ""))
    return sorted(found)


def store_path() -> Path:
    root = os.environ.get("POSTROLL_DATA_DIR")
    base = Path(root) if root else Path.home() / "Library/Application Support/PostRoll"
    return base / "events.json"


#: One line per observe cycle, appended (#1195).
OBSERVATIONS = REPO_ROOT / "tests" / "fixtures" / "no_such_account_observations.json"

#: The handles the LAST cycle asked about, as a set of salted digests.
#:
#: Only to answer "how many of these are new", which is the half of #1195's
#: condition about the population changing. The salt is regenerated every cycle
#: and stored beside the digests, so the digests are comparable within one
#: comparison and worthless afterwards: they cannot be run back through to
#: recover a handle, and they cannot be compared against any other file (L222).
_SALT_BYTES = 16


def _new_since_last(handles: list[str]) -> int | None:
    """How many of `handles` the previous cycle did not ask about.

    None when there is no previous cycle, which is not zero: a first cycle has
    not failed to bring new handles, it simply has nothing to be new against
    (L11).
    """
    import hashlib

    held = _observations()
    previous = held["cycles"][-1] if held.get("cycles") else None
    if previous is None or "salt" not in previous:
        return None
    salt = bytes.fromhex(previous["salt"])
    seen = set(previous.get("digests") or [])
    mine = {hashlib.blake2b(h.encode(), salt=salt, digest_size=8).hexdigest()
            for h in handles}
    return len(mine - seen)


def _observations() -> dict:
    if not OBSERVATIONS.exists():
        return {"cycles": []}
    return json.loads(OBSERVATIONS.read_text(encoding="utf-8"))


def record_observation(*, handles: list[str], outcomes, would_have_been,
                       new_since_last: int | None) -> None:
    """Append this cycle to the record #1195 reads."""
    import hashlib
    import os

    held = _observations()
    salt = os.urandom(_SALT_BYTES)
    held.setdefault("cycles", []).append({
        "measured_on": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "asked": len(handles),
        "outcomes": dict(sorted(outcomes.items())),
        "would_have_been": dict(sorted(would_have_been.items())),
        "new_since_last": new_since_last,
        "salt": salt.hex(),
        "digests": sorted(
            hashlib.blake2b(h.encode(), salt=salt, digest_size=8).hexdigest()
            for h in handles),
    })
    OBSERVATIONS.parent.mkdir(parents=True, exist_ok=True)
    OBSERVATIONS.write_text(json.dumps(held, indent=2) + "\n", encoding="utf-8")


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=0,
                        help="stop after this many handles, for a cheap smoke run")
    parser.add_argument("--out", type=Path, default=POPULATION)
    args = parser.parse_args(argv)

    token = os.environ.get(TOKEN_ENV_VAR)
    if not token:
        # Named rather than falling back to an empty string, which Meta answers
        # with a rejected token and which would read as a credential problem
        # rather than as one nobody set (L138).
        print(f"{TOKEN_ENV_VAR} is not set. See docs/META-APP.md.", file=sys.stderr)
        return 2

    events = json.loads(store_path().read_text(encoding="utf-8"))
    handles = harvest(events)
    if args.limit:
        handles = handles[:args.limit]
    if not handles:
        print("the store tags no accounts at all, so there is no population to "
              "measure. Refusing to write a file that would read as one.",
              file=sys.stderr)
        return 1
    print(f"asking Meta about {len(handles)} handles")

    rows: list[dict] = []
    outcomes: Counter[str] = Counter()
    # What the fetch WOULD have written with `allow_no_such_account` on (#1195).
    #
    # Nothing read that field. The observe gate set it on every cycle and it
    # went nowhere, so the one absent verdict seen on 2026-09-01 survives only
    # as a sentence somebody typed into an issue. Stored data needs a reader
    # (L46), and this is it.
    would_have_been: Counter[str] = Counter()
    for index, handle in enumerate(handles, 1):
        figures = fetch(handle, token=token)
        outcomes[figures.outcome.value] += 1
        if figures.would_have_been is not None:
            would_have_been[figures.would_have_been.value] += 1
        rows.append({
            "followers": figures.followers,
            "likes": figures.likes,
            "comments": figures.comments,
            "measured": figures.outcome is Outcome.MEASURED,
            "likes_hidden": figures.likes_hidden,
        })
        if index % 20 == 0:
            print(f"  {index}/{len(handles)}", flush=True)

    # Proved rather than assumed. The whole safety of this file is that it
    # names nobody, and an assertion here is cheaper than discovering a handle
    # in version control afterwards.
    body = json.dumps(rows)
    leaked = [h for h in handles if h in body]
    if leaked:
        print(f"{len(leaked)} handles reached the output. Refusing to write it.",
              file=sys.stderr)
        return 1

    args.out.write_text(json.dumps({
        "measured_on": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "outcomes": dict(sorted(outcomes.items())),
        "accounts": rows,
    }, indent=1) + "\n", encoding="utf-8")

    # The population file above is REPLACED every cycle, which is right for it:
    # it is the current shape of the population. It is wrong for #1195, which
    # asks for absent verdicts seen across SEVERAL cycles on a population that
    # is not the same handles every time. A file that replaces itself can never
    # answer that, so the cycle is appended to its own record here.
    #
    # Counts only, and how many handles were new since the last cycle, computed
    # now from the live list. No handle is stored: a hash would be one too,
    # because the set of handles this asks about is small enough to run back
    # through any hash (L222).
    record_observation(
        handles=handles,
        outcomes=outcomes,
        would_have_been=would_have_been,
        new_since_last=_new_since_last(handles),
    )

    print(f"\nwrote {len(rows)} anonymised accounts to {args.out}")
    for outcome, count in outcomes.most_common():
        print(f"  {count:4d}  {outcome}")
    print()
    for key, value in summary(load(args.out)).items():
        print(f"{key}: {value:.2%}" if isinstance(value, float) else f"{key}: {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
