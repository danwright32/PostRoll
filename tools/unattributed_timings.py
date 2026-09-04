#!/usr/bin/env python3
"""Recorded durations that never said which machine produced them (#1245).

`.github/workflows/swift.yml` recorded the Swift suite as "294s of test bodies
serially and 106s wall in parallel". That reading came from the 12 core Mac this
repo is written on; the comment sat in a job that runs on a GitHub macOS runner
reporting THREE cores, where the same suite takes 212s. #1103 reasoned from the
106s figure and concluded the test run was the small remainder of `swift-unit`,
which sent a whole milestone's planning at the wrong half of the job.

#1243 fixed that one line. This finds the others.

## What makes a figure a problem

Not being wrong. Being unfalsifiable. A duration written as a bare assertion
reads as measured fact, and a reader has no way to tell a local reading from a
runner one, so nobody can check it and nobody knows what to compare a new
reading against (L316). Two machines here differ by 4x in cores.

## What counts as attribution

Any nearby phrase that says where the reading was taken: a runner label, a core
count, "locally", "this Mac", "in CI", a run id. Deliberately generous. The
point is that the reader can tell, not that a particular wording was used.

## What it does NOT do

It does not check that a reading is still true. Nothing here can. It checks that
no reading is recorded without saying where it came from.

    venv/bin/python tools/unattributed_timings.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
EXEMPTIONS = REPO_ROOT / "tests" / "fixtures" / "timings_without_a_machine.json"

#: A stated duration, or a count of the things that make one machine differ
#: from another. Percentages, ratios and byte sizes are deliberately out: a
#: ratio between two costs on one machine survives the move to another, which is
#: exactly what an absolute duration does not.
MEASUREMENT = re.compile(
    r"(?<![\w.])\d{1,3}(?:,\d{3})*(?:\.\d+)?\s?"
    r"(?:s\b|secs?\b|seconds?\b|ms\b|minutes?\b|mins?\b)"
    r"|(?<![\w.])\d+\s?(?:workers?|cores?)\b")

#: Somewhere the reading could have been taken. Generous on purpose: what makes
#: a figure checkable is that the reader can tell, not the wording (L273).
MACHINE = re.compile(
    r"macos-\d+|ubuntu-\d|self-hosted|runner"
    r"|\bcores?\b|\bworkers?\b"
    r"|\blocally\b|\blocal\b|this Mac|\bMac\b|\bin CI\b|on CI\b"
    r"|run \d{7,}|\bmy machine\b",
    re.I)

#: How far either side of the line the attribution may sit.
#:
#: A whole comment block, roughly. A reading and the sentence saying where it
#: came from are routinely a paragraph apart, and demanding them on one line
#: would fire on almost every honest comment here and stop being read (L36).
CONTEXT = 8

#: The files whose prose carries these figures.
SCANNED = (".github/workflows/*.yml", "tools/*.py", "Makefile",
           "PostRollApp/project.yml")


def _comment_lines(path: Path) -> list[tuple[int, str]]:
    """Every comment line, with its 1-based number.

    Prose only. A figure inside code is a value the code USES, and changing it
    changes behaviour; a figure in a comment is a claim about the world, which
    is what this is about.
    """
    text = path.read_text(encoding="utf-8")
    return [(n, line) for n, line in enumerate(text.splitlines(), 1)
            if line.lstrip().startswith("#")]


def scanned_files(root: Path = REPO_ROOT) -> list[Path]:
    """The files this reads, resolved.

    Its own function so a test can assert the sweep is actually looking at
    something. Derived from `unattributed`'s own selection rather than
    recomputed beside it, because two derivations of the same list drift and the
    control would then pass while the sweep read nothing (L70, L107).
    """
    found: list[Path] = []
    for pattern in SCANNED:
        paths = sorted(root.glob(pattern)) if "*" in pattern else [root / pattern]
        found += [path for path in paths if path.exists()]
    return found


def unattributed(root: Path = REPO_ROOT) -> list[dict]:
    """Every stated duration with nothing nearby saying where it was measured."""
    found: list[dict] = []
    for path in scanned_files(root):
        lines = path.read_text(encoding="utf-8").splitlines()
        for number, line in _comment_lines(path):
            if not MEASUREMENT.search(line):
                continue
            low = max(0, number - 1 - CONTEXT)
            block = "\n".join(lines[low:number + CONTEXT])
            if MACHINE.search(block):
                continue
            found.append({
                "file": str(path.relative_to(root)),
                "line": number,
                "text": line.strip(),
            })
    return found


def exempt() -> dict[str, str]:
    """Sites that state no machine and are right not to, and why each.

    Keyed by the matched text rather than by a line number, because a line
    number moves whenever anything above it is edited and a stale entry would
    silently excuse whatever moved into that position (L217).
    """
    if not EXEMPTIONS.exists():
        return {}
    return json.loads(EXEMPTIONS.read_text(encoding="utf-8"))


def main() -> int:
    reasons = exempt()
    missing = [site for site in unattributed() if site["text"] not in reasons]
    for site in missing:
        print(f"{site['file']}:{site['line']}: {site['text']}")
    print(f"\n{len(missing)} unattributed, {len(reasons)} exempt with a reason")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
