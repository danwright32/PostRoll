"""Where a long run currently is, written where the app can read it (#95, #96).

Blog generation fires five to ten sequential Claude calls, each with a timeout
measured in minutes. Between them the process says nothing on any channel the
app reads, so a run that was working, a run that was hung and a run whose
process had died all presented as the same spinner.

This is deliberately a single small file rather than a log:

* It holds where the run IS, not where it has been, so the reader never parses
  a growing file and can never pick up a line belonging to another operation.
  Reading an unscoped tail of the shared log is exactly how a UUID containing
  "413" once turned a 401 into "photos too large" (#90).
* Every step carries the time it was written. A label on its own freezes just
  as silently as a spinner: it sits there reading "Blog pass 2" whether the
  pass is running or the process died during it. The timestamp is what lets
  the app tell still-alive from stalled.
* Writing is atomic (temp file plus rename), because the app polls this file on
  a timer and a torn read would surface as garbage on screen.
* Nothing here may raise. This is decoration around work that costs real money,
  and a run must not die because it could not write a status file.
"""

from __future__ import annotations

import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any


def _snapshot(*, label: str, index: int | None,
              total: int | None, done: bool) -> dict[str, Any]:
    """One progress record, as the app's GenerationStep reads it.

    Its own function so the key contract can see this payload (#262): a dict
    built inline as a call argument is invisible to it, and a payload nothing
    can inspect is one that drifts from its reader unnoticed. `updated_at` is
    added by the writer, which is the only thing that knows when the write
    happened.
    """
    return {
        "label": label,
        "index": index,
        "total": total,
        "done":  done,
    }


class ProgressWriter:
    """Records the current step of a run, or does nothing without a path.

    Every generator calls this unconditionally, so a run started without
    ``--progress`` gets a writer that silently discards. That keeps the check
    in one place instead of at every call site, where it would eventually be
    forgotten on the one path that mattered.
    """

    def __init__(self, path: str | Path | None) -> None:
        self._path = Path(path) if path else None

    @property
    def enabled(self) -> bool:
        return self._path is not None

    def step(self, label: str, *, index: int | None = None,
             total: int | None = None) -> None:
        """Record what the run is doing now."""
        payload = _snapshot(label=label, index=index, total=total, done=False)
        self._write(payload)

    def finish(self) -> None:
        """Mark the run over, so the last step stops reading as in flight."""
        payload = _snapshot(label="", index=None, total=None, done=True)
        self._write(payload)

    def _write(self, snapshot: dict[str, Any]) -> None:
        if self._path is None:
            return
        # Copy-then-set rather than `{**snapshot, "updated_at": ...}`: a splat
        # hides the resulting key set from the contract that keeps this payload
        # and the app's GenerationStep in step (#262).
        payload = dict(snapshot)
        payload["updated_at"] = time.time()
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            # Temp file in the same directory, then rename: rename is atomic
            # within a filesystem, so a reader polling this path sees either
            # the previous step or the new one and never a fragment.
            fd, tmp = tempfile.mkstemp(dir=str(self._path.parent),
                                       prefix=".progress-", suffix=".json")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(payload, f)
                os.replace(tmp, self._path)
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
        except Exception:
            # Never fatal. A run that has already paid for its Claude calls
            # must not be lost because a status file could not be written.
            return


def read_progress(path: str | Path) -> dict[str, Any] | None:
    """The current step, or None when there isn't a readable one.

    None covers "not written yet" and "caught mid-write" alike: both mean there
    is no step to show, and neither is a failure worth surfacing.
    """
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        doc = json.loads(raw)
    except (ValueError, TypeError):
        return None
    return doc if isinstance(doc, dict) else None
