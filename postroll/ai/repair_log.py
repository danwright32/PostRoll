"""What the app changed in a post, after the post has been published (#1135).

Rule 1 makes repairs SILENT. The panel says which findings survived and what the
pass did about them; it does not say what the alt text USED to be. The question
anybody actually asks is "what did the app change in this post", and it arrives
after publication, by which time the run's own output is gone.

**Not stderr.** `PythonBridgeError.rotate` keeps 500 lines of a SHARED log and a
single blog run already prints 23 CHECK lines, so the evidence of a repair is
evicted within days, and evidence attached to a store swept on a retention
schedule inherits that schedule's lifetime (L191, L202).

**Not capped and not rotated.** A capped store evicts the oldest real records
first, and those are the expensive observations it exists to hold. One line per
repair on a handful of posts a week is a file measured in kilobytes a year.

Three kinds of record, and all three matter:

1. one ATTEMPT per repair attempt: the text before, the text after, the outcome,
   and for a blocked one WHICH of its three causes it was;
2. one DECLINED per finding the pass did not attempt, carrying the written
   reason and the filed issue from the REPAIRERS table. This is what produces
   the per-code FIRING rate the deferral gates are stated against. It is
   explicitly NOT a false positive count, and the field is named `fired` so a
   reader cannot mistake one for the other (L90);
3. one PASS record on EVERY exit path, in a `finally`. Zero attempts must read
   as a recorded observation with its own wording, not as silence: rule 1
   removed every other signal, so without it a pass that made no attempt, a post
   with nothing to repair, a pass that threw before the loop, a pass whose table
   resolved nothing, and a run killed at the process ceiling all read
   identically (L98, L11).

Nothing here raises. Accounting must never take down a generation that has
already been paid for, exactly as `usage_log.record` documents.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from ..data_root import data_root

#: What a PASS record says, per outcome. Distinct wordings, because these are
#: the states the record exists to tell apart and two of them sharing a sentence
#: is two states sharing an appearance (L11, L98).
_PASS_WORDING = {
    "never_ran": "the repair pass did not run on this post at all",
    "nothing_to_repair": "the repair pass ran and found nothing to repair",
    "ran": "the repair pass ran and attempted what it found",
    "ended_early": "the repair pass ran out of time before reaching everything "
                   "it had selected",
}


class RepairLogUnreadable(OSError):
    """The journal is there and cannot be read.

    Its own type because it must never be confused with an absent journal: one
    means no pass has run, the other means the evidence of every pass that did
    is unavailable, and answering both with an empty list tells Dan no repair
    happened on a post where one did (L10, L11).
    """


def default_log_path() -> Path:
    """Beside everything else the app owns, through the one shared answer."""
    return data_root() / "blog-repairs.jsonl"


class RepairLog:
    """An append-only journal of what one repair pass did."""

    def __init__(self, path: str | Path | None = None, *,
                 event: str = "", script: str = "") -> None:
        self.path = Path(path) if path is not None else default_log_path()
        self.event = event
        self.script = script

    def attempt(self, *, target: str, marker: str, codes: list[str],
                before: str | None, after: str | None, outcome: str,
                reason: str) -> bool:
        return self._write({
            "kind": "attempt",
            "target": target,
            "marker": marker,
            "codes": list(codes),
            "before": before,
            "after": after,
            "outcome": outcome,
            "reason": reason,
        })

    def declined(self, *, code: str, count: int, reason: str,
                 issue: str) -> bool:
        """One code the pass did not attempt, and how often it fired.

        `fired` and not `false_positives`. This says the check FIRED, never that
        it fired WRONGLY: rule 1 removed the surface where Dan might have said
        so, and a field named for the wrong question would let a rate that
        cannot be measured read as one that was (L90).
        """
        return self._write({
            "kind": "declined",
            "code": code,
            "fired": count,
            "reason": reason,
            "issue": issue,
        })

    def finish(self, *, ran: bool, selected: int, attempted: int,
               remaining: float, placed: list[str] | None = None) -> bool:
        """The record written on EVERY exit path, including the empty one."""
        if not ran:
            wording = _PASS_WORDING["never_ran"]
        elif remaining <= 0:
            wording = _PASS_WORDING["ended_early"]
        elif not selected:
            wording = _PASS_WORDING["nothing_to_repair"]
        else:
            wording = _PASS_WORDING["ran"]

        return self._write({
            "kind": "pass",
            "ran": ran,
            "selected": selected,
            "attempted": attempted,
            "remaining_seconds": round(remaining, 1),
            # Which photographs the post PLACED. The evidence
            # `blog_marker_missing_photo` was providing incidentally, and stops
            # providing once the repair pass acts on it (L277).
            "placed": list(placed or []),
            "wording": wording,
        })

    def _write(self, record: dict) -> bool:
        line = {
            "at": datetime.now(timezone.utc).isoformat(),
            "script": self.script,
            "event": self.event,
            **record,
        }
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(line, ensure_ascii=False) + "\n")
        except OSError as e:
            # Reported to the caller AND on stderr, so the journal is known to
            # be short rather than silently incomplete. Never raised: a
            # generation that has already been paid for must not die because its
            # bookkeeping failed.
            print(f"warning: could not write the blog repair record "
                  f"({record.get('kind')}): {e}. The journal for this post will "
                  f"be incomplete.", file=sys.stderr, flush=True)
            return False
        return True


def read_records(path: str | Path | None = None) -> list[dict]:
    """Every record in the journal, oldest first.

    A missing journal is an empty list; a line that will not parse is SKIPPED
    and reported, rather than taking the whole read down, because one bad line
    must not hide every good one.
    """
    target = Path(path) if path is not None else default_log_path()
    try:
        raw = target.read_text(encoding="utf-8")
    except FileNotFoundError:
        # Genuinely nothing recorded: no pass has run against this data
        # directory yet. An empty list is the honest answer.
        return []
    except OSError as e:
        # The file is THERE and could not be read. That is not "nothing was
        # recorded", and answering with an empty list would have the reader
        # tell Dan no repair happened on a post where one did (L10, L11). This
        # is the only evidence a silent repair leaves, so the failure is said
        # out loud and raised rather than flattened into an empty answer.
        raise RepairLogUnreadable(
            f"the repair journal at {target} exists and could not be read: "
            f"{e}. This is the only record of what the app changed in a post, "
            f"so treat this as evidence missing rather than as no repairs.") from e
    out: list[dict] = []
    for number, line in enumerate(raw.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError:
            print(f"warning: {target}:{number} is not readable JSON and was "
                  f"skipped", file=sys.stderr, flush=True)
            continue
        if isinstance(record, dict):
            out.append(record)
    return out
