#!/usr/bin/env python3
"""Run a command while holding the shared build lock (#642).

Since #621 every build in this project writes into one DerivedData: `make
build`, `make test`, `make review-sheet`, `build-install.sh` and the guard
sweep. Two xcodebuilds against one DerivedData produce errors that read like
real compile failures in whichever run notices first, and sessions run side by
side on this machine, so the window is not hypothetical.

## Why this exists rather than `flock`

`flock(1)` is a Linux tool. On this Mac it is present only because Homebrew
installed it, at /opt/homebrew/bin/flock, so a Makefile calling it would fail
on any checkout without that package, and fail as "command not found" long
after somebody had stopped expecting a build to need Homebrew. `fcntl.flock`
is Python standard library and needs nothing installed.

It also keeps ONE implementation of the lock. `tools/check_guards.py` takes the
same lock, at the same path, derived from the same shell definition, and two
implementations of one lock is how two runs end up each holding a different
file and both believing they are alone (L41).
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.check_guards import build_lock, build_lock_path  # noqa: E402


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: with_build_lock.py <command> [args...]", file=sys.stderr)
        return 2

    repo_root = Path(__file__).resolve().parent.parent
    path = build_lock_path(repo_root)

    if path is None:
        # Nothing names a shared cache here, so there is nothing to contend
        # over. Said out loud rather than passed over: a run that silently
        # stopped locking looks exactly like one that is locking (L11).
        print("no shared build cache is named, so this build takes no lock",
              file=sys.stderr, flush=True)
        return subprocess.run(argv).returncode

    started = time.monotonic()
    with build_lock(path, log=lambda message: print(message, flush=True)):
        waited = time.monotonic() - started
        if waited > 1:
            print(f"waited {waited:.0f}s for the shared build cache", flush=True)
        return subprocess.run(argv).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
