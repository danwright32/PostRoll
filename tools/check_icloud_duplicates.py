#!/usr/bin/env python3
"""Fail when iCloud has written a numbered copy of a file this project builds from.

This repo lives under `~/Documents`, which has iCloud Desktop and Documents sync
switched on. iCloud resolves a sync race by writing a second copy of the file
beside the original with a number appended: `DesignStamp 2.swift`,
`PostRoll 2.xcodeproj`. Six of them accumulated by 2026-08-10, byte identical to
their originals, which is the dangerous shape: a search matches the copy, an
edit lands in it, and both the file and the build look correct while the change
does nothing (#299).

`.gitignore` hides them from git, which is the opposite of reporting them, and
hiding is all it can do: the copies are still written to disk. This is the
report.

Usage:
    python3 tools/check_icloud_duplicates.py [repo_root]

Exit 0 when the tree is clean, 1 when a copy is found or the tracked file list
could not be read. Finding nothing tracked is a failure rather than a clean run:
an empty list is exactly what a broken git call returns, and a scan against it
reports a clean tree with total confidence.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Collection, Iterable

# `name N` or `name N.ext`, with the whole extension tail kept so a compound
# extension ("bundle 2.tar.gz") names "bundle.tar.gz" rather than "bundle.tar".
# The number is one or more digits: the .gitignore patterns match a single digit
# only, so a tenth copy would be one git had started tracking.
#
# The tail carries no space, which is what separates a copy from an ordinary
# name that happens to hold a number ("Screenshot 2026-08-10 at 3.45.02 PM.png"
# would otherwise read as a copy of "Screenshot 2026-08-10 at.45.02 PM.png").
_NUMBERED = re.compile(r"^(?P<stem>.+) (?P<n>\d+)(?P<ext>\.[^ ]*)?$")


def duplicate_of(name: str) -> str | None:
    """The file `name` looks like a numbered copy of, or None.

    Answers from the name alone. Whether the named file exists, and whether the
    project tracks it, is decided by the caller: the shape on its own is not a
    defect, only shadowing a real file is.
    """
    m = _NUMBERED.match(name)
    if m is None:
        return None
    return m.group("stem") + (m.group("ext") or "")


def tracked_paths(root: Path) -> set[str]:
    """Every file git tracks in `root`, repo relative.

    Read from git rather than from a list kept beside this file. A hand kept
    list only ever covers the names someone remembered, which is the blind spot
    a check like this exists to close (LESSONS.md L96).
    """
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                         capture_output=True, text=True, check=True)
    return {rel for rel in out.stdout.split("\0") if rel}


def _tracked_dirs(tracked: Collection[str]) -> set[str]:
    """Every directory holding a tracked file, repo relative.

    Needed because iCloud copies whole bundles (`PostRoll 2.xcodeproj`), and a
    bundle is not itself a tracked file, only the files inside it are.
    """
    dirs: set[str] = set()
    for rel in tracked:
        parent = Path(rel).parent
        while str(parent) != ".":
            dirs.add(str(parent))
            parent = parent.parent
    return dirs


def scan(root: Path, tracked: Collection[str],
         walk: Callable[..., Iterable] = os.walk) -> list[str]:
    """Numbered copies of tracked paths present under `root`, repo relative.

    A copy is compared against the tracked path it sits beside, not against a
    basename: iCloud writes the copy next to its original, and matching names
    alone would flag an unrelated file in a directory the project does not
    track.

    Raises ValueError when `tracked` is empty, because a scan against an empty
    list reports a clean tree whatever is on disk (LESSONS.md L98).
    """
    if not tracked:
        raise ValueError(
            "no tracked files: refusing to report a clean tree, because an "
            "empty tracked list is what a failed git call looks like")

    tracked = set(tracked)
    dirs = _tracked_dirs(tracked)
    found: list[str] = []

    for dirpath, dirnames, filenames in walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        prefix = "" if rel_dir == "." else rel_dir + "/"

        # Copied bundles are reported as one finding and not descended into, or
        # every file inside the copy is reported as a copy of nothing.
        copies = [d for d in dirnames
                  if (orig := duplicate_of(d)) is not None
                  and prefix + orig in dirs
                  and prefix + d not in dirs]
        found.extend(prefix + d for d in copies)

        # Prune to the directories the project actually tracks. Derived from the
        # tracked list rather than a list of names to skip, and it cannot hide a
        # finding: a copy sits beside its original, so every directory that can
        # hold one is on a tracked path. Keeps the scan off venv/, build/ and
        # the rest of the ignored tree, and off .git, where iCloud also writes
        # copies that nothing reads.
        dirnames[:] = [d for d in dirnames
                       if d not in copies and prefix + d in dirs]

        for f in filenames:
            orig = duplicate_of(f)
            if orig is None:
                continue
            rel = prefix + f
            # A numbered file the project tracks is the project's own file.
            if rel in tracked:
                continue
            if prefix + orig in tracked:
                found.append(rel)

    return sorted(found)


def main(argv: list[str]) -> int:
    root = Path(argv[1]).resolve() if len(argv) > 1 else Path(__file__).resolve().parent.parent

    try:
        tracked = tracked_paths(root)
    except (subprocess.CalledProcessError, OSError) as exc:
        print(f"check_icloud_duplicates: could not read the tracked files: {exc}",
              file=sys.stderr)
        return 1

    try:
        found = scan(root, tracked)
    except ValueError as exc:
        print(f"check_icloud_duplicates: {exc}", file=sys.stderr)
        return 1

    if not found:
        return 0

    print("iCloud has written numbered copies of files this project builds from.",
          file=sys.stderr)
    print("They are byte identical to the originals, so a search matches the copy,",
          file=sys.stderr)
    print("an edit lands in it, and nothing reports that the change did nothing.",
          file=sys.stderr)
    print("", file=sys.stderr)
    for rel in found:
        print(f"    {rel}", file=sys.stderr)
    print("", file=sys.stderr)
    print("Delete them, then try again.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
