"""Temp files written beside an output and renamed into place (#1458).

Every reel renderer encodes to `<stem>.<pid>.tmp.mp4` and the music download
streams to `<stem>.<pid>.part`, then each renames into place, so a cancelled or
failed run never leaves a truncated file at the real path. The pid keeps two
runs from sharing a temp.

What none of them could do was clean up after a run that never reached its own
cleanup: a render cancelled mid encode, or a Python killed outright. Its temp
stayed beside the output for good (one was found on 2026-09-28, a day old). So
the name is handed out here, and handing it out first removes the leftovers of
runs that are no longer alive.
"""

from __future__ import annotations

import os
import re
import sys
import time
from pathlib import Path
from typing import Callable

#: How long a leftover must have gone unchanged before it is swept. A cancelled
#: render's ffmpeg can go on writing for seconds after the Python that started
#: it has gone, so a file still being written is not yet a leftover.
QUIET_FOR_S = 60.0


def pid_is_alive(pid: int) -> bool:
    """Whether a process with this id exists. A process owned by somebody else
    still exists, so a permission refusal counts as alive."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def temp_sibling(output: Path, tag: str, *, now: float | None = None,
                 is_alive: Callable[[int], bool] | None = None) -> Path:
    """This process's temp name for `output`, after sweeping dead runs' ones.

    Only `<output stem>.<digits>.<tag>` beside `output` is ever considered, so
    another template's temp, another kind of temp, and the finished file itself
    are never touched. A leftover goes only when the run that wrote it is not
    alive AND it has been quiet for `QUIET_FOR_S`. A removal that fails is
    said and skipped: tidying up must never stop the render it precedes.
    """
    output = Path(output)
    now = time.time() if now is None else now
    # Resolved here rather than defaulted in the signature, so the real check
    # stays replaceable (L394): a default binds once, at definition.
    alive = pid_is_alive if is_alive is None else is_alive
    pattern = re.compile(rf"^{re.escape(output.stem)}\.(\d+)\.{re.escape(tag)}$")
    try:
        siblings = list(output.parent.iterdir())
    except FileNotFoundError:
        siblings = []
    for path in siblings:
        match = pattern.match(path.name)
        if not match:
            continue
        pid = int(match.group(1))
        if pid == os.getpid() or alive(pid):
            continue
        try:
            if now - path.stat().st_mtime < QUIET_FOR_S:
                continue
            path.unlink()
            print(f"[temp_files] removed {path.name}, left by a run that is no "
                  f"longer alive", file=sys.stderr, flush=True)
        except OSError as e:
            print(f"[temp_files] could not remove {path.name}: {e}",
                  file=sys.stderr, flush=True)
    return output.with_suffix(f".{os.getpid()}.{tag}")
