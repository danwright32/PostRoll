"""
PostRoll: retry the alt text repairs a pass could not finish (#1160)

Two of the five repair outcomes tell Dan to try again in as many words.
`blocked` says the app could not reach the model or could not read the
photograph; `not_reached` says the pass ran out of time before this one. Until
this existed nothing retried, so the panel named a recovery step nothing could
perform and left him facing the same panel with no way forward (L109). His only
route was regenerating the whole post or swapping photos, which pays for
everything again to redo one marker.

A retry is a FRESH pass over just the markers it was given, never a resumed
one: the round cap is per pass and the pass is already re-entrant.

It refuses an empty marker list rather than treating it as "everything". That
is the dangerous direction: this control exists to redo a few markers, and a
bug that redid all of them would pay for the whole post again without being
asked.

Input manifest:
{
  "body":        "<current blog body with [PHOTO: ...] markers>",
  "photo_paths": ["/path/to/p1.jpg", ...],
  "markers":     ["p2.jpg"],                     // which ones to retry
  "program":     {"performers": [{"name": "..."}]},   // optional
  "venue":       "..."                                // optional
}

Output JSON:
{
  "body":     "<the body the retry ended with>",
  "findings": [{"code": "...", "message": "...", "detail": "...", ...}],
  "retry":    {"ran": true, "selected": 1, "repaired": 1, "states": {...}}
}
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Callable

from .blog_findings import RepairState
from .blog_quality import check_blog_targeted, finding_entry
from .blog_repair import deadline_from, repair_alt_text
from .claude_client import ClaudeError, run_json_prompt
from .progress import ProgressWriter
from .repair_log import RepairLog


def retry_blog_repair(
        *,
        body: str,
        photo_paths: list[str],
        markers: list[str],
        program: dict[str, Any] | None = None,
        venue: str = "",
        event_id: str = "",
        runner: Callable[..., Any] = run_json_prompt,
        now: Callable[[], float] | None = None,
        deadline: float | None = None,
        say: Any = None,
) -> dict[str, Any]:
    """Re-run the alt text repair over `markers` only.

    Runs under a DEADLINE, like every other path that reaches the repair pass.
    Without one the pass gets `float("inf")`, its budget check can never fire,
    and this becomes the one route able to carry the process past the 1,800
    second ceiling, where the run is SIGTERM\'d, `outputMissing` is thrown and
    every paid call is destroyed (L110). `deadline` is absolute on `now()`\'s
    scale; left unset it is derived from this call, which is right for the
    dedicated process the bridge starts and wrong for a caller that has already
    spent part of the ceiling, so such a caller passes its own (L227, L522).

    Returns the body it ended with, the findings ON THAT BODY, and what it
    actually did. The last part is not decoration: repairs are silent, so a
    retry that repaired nothing and a retry that never ran would otherwise read
    identically to the only surface that reports either (L98).
    """
    if not body or not body.strip():
        raise ValueError("a retry needs the current body")
    if not markers:
        raise ValueError(
            "a retry names no markers. It is refused rather than treated as "
            "the whole post: this control exists to redo the few the pass "
            "could not finish, and repairing everything would pay for the "
            "whole post again without being asked.")

    import time

    now = now or time.monotonic
    if deadline is None:
        deadline = deadline_from(started_at=now(), now=now)

    paths = {Path(p).name: p for p in photo_paths}

    outcome = repair_alt_text(
        body, program=program, venue=venue, photo_paths=paths,
        runner=runner, now=now, deadline=deadline, say=say, only=list(markers),
        log=RepairLog(event=venue or "", event_id=event_id,
                      script="retry_blog_repair"))

    targeted = check_blog_targeted(outcome.body, program=program, venue=venue)
    repaired = sum(1 for state in outcome.states.values()
                   if state is RepairState.REPAIRED)
    return {
        "body": outcome.body,
        "findings": [finding_entry(f, repair=outcome.repair_for(f),
                                   target=t.key)
                     for f, t in targeted],
        "retry": {
            "ran": outcome.ran,
            "selected": len(outcome.selected),
            "repaired": repaired,
            "states": {k: v.value for k, v in outcome.states.items()},
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Retry the alt text repairs a pass could not finish")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--progress", help="Path to write step progress JSON")
    args = parser.parse_args()

    m = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    try:
        result = retry_blog_repair(
            body=m["body"],
            photo_paths=m.get("photo_paths") or [],
            markers=m.get("markers") or [],
            program=m.get("program"),
            venue=m.get("venue", "") or "",
            event_id=m.get("event_id", "") or "",
            say=ProgressWriter(args.progress),
        )
    except (ClaudeError, FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    Path(args.output).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
