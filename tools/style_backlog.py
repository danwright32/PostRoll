#!/usr/bin/env python3
"""How much of the writing style rule the tree already breaks (#948).

`check-style-guide.sh` is a pre-push hook and it reads the lines a push ADDS.
Anything that predates it is invisible to it, permanently, and there was no way
to ask it for a total.

That is the shape L223 describes: a check that finds violations by reading what
CHANGED can never see the backlog that existed before it shipped, which is
exactly the population it exists to find. Worse, the count of new violations
sitting at zero reads as the rule being kept, so nobody re-examines the rest
(L182).

#944 was one instance. Six user-facing strings carried an em dash, in violation
of an explicit standing rule, and the hook had never been able to see them. They
were found by putting a screen on the review sheet and reading the rendered
banner, which is not a method that scales.

## What this counts, and the three kinds it keeps apart

COPY IN THE APP is a string literal under `PostRollApp/Sources`: words on
Dan's screen. Held to ZERO, because #944 cleared that backlog and the rule is
unambiguous there.

COPY ELSEWHERE is a string literal in a prompt or a tool. #959 cleared the
caption prompt, the blog prompt and the brand voice document; `analyze_posts.py`
and its neighbours still carry over a hundred. Counted and held to not GROWING,
because rewriting a prompt is a change to what a model is shown and wants
reading sentence by sentence, which #959 did for three files and is separate
work for the rest.

PROSE is a comment or a doc comment. Counted and held to not growing, for the
same reason and with more of it.

The split is recorded rather than left implicit. "Zero except the ones we
decided not to count" is the answer this exists to avoid giving, so the ones
not counted at zero are named, with their number and the reason.

    venv/bin/python tools/style_backlog.py            # report
    venv/bin/python tools/style_backlog.py --record   # write the baseline

The characters are written as ESCAPES throughout. A file that names the
forbidden character is caught by the pre-push hook, which is the hook working
correctly: it cannot tell the line banning the character from the line using it.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BASELINE = REPO_ROOT / "tests" / "fixtures" / "style_backlog.json"

#: The characters the rule bans, as escapes so this file holds none of them.
#: Em dash, en dash, and the emoji ranges the pre-push hook already matches.
BANNED = re.compile(
    "["
    "\u2014\u2013"          # em dash, en dash
    "\U0001F300-\U0001FAFF"  # pictographs, emoticons, supplemental symbols
    "\u2600-\u27BF"          # misc symbols and dingbats
    "\uFE0F"                  # the variation selector that makes one emoji
    "]")

#: Where to look. Named rather than "everything", because the rule is about what
#: this repository WRITES, and a vendored copy or a cache is neither.
ROOTS = ("PostRollApp/Sources", "PostRollApp/Tests", "postroll", "tools",
         "tests", ".github", "docs")

#: Files whose whole content is prose a reader consumes, so every hit is copy.
COPY_SUFFIXES = (".md",)

#: The suffixes with a comment syntax this can tell from code.
CODE_SUFFIXES = (".swift", ".py", ".sh", ".yml", ".yaml")


def _split(path: Path, text: str) -> tuple[str, str]:
    """`(code, raw)` for one file, with the code half's comments blanked.

    Through `tests/source_text`, the module #1074 built for exactly this
    question, rather than a second set of comment patterns beside it (L41). A
    line based rule was tried first and got this wrong in the direction that
    matters: `var x = 1  // a comment with a dash` does not START with a comment
    marker, so 205 trailing comments were reported as copy and the zero the copy
    half is held to was unreachable.

    A banned character surviving the strip is inside a STRING, because none of
    these languages allows one in an identifier. That is what makes the
    distinction exact rather than approximate.
    """
    if path.suffix in COPY_SUFFIXES:
        return text, text
    sys.path.insert(0, str(REPO_ROOT / "tests"))
    from source_text import (python_without_comments, swift_without_comments,
                             yaml_without_comments)
    stripper = {".swift": swift_without_comments,
                ".py": python_without_comments}.get(
                    path.suffix, yaml_without_comments)
    try:
        return stripper(text), text
    except ValueError:
        # Unparseable. Counted as COPY rather than skipped: a file this cannot
        # read is not a file with nothing wrong in it (L98, L215).
        return text, text


def offences(root: Path = REPO_ROOT) -> dict[str, list[str]]:
    """Every line breaking the rule, as `kind -> ["path:line: text", ...]`."""
    found: dict[str, list[str]] = {"copyInTheApp": [], "copyElsewhere": [],
                                   "prose": []}
    for area in ROOTS:
        base = root / area
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file() or path.suffix not in (
                    set(CODE_SUFFIXES) | set(COPY_SUFFIXES)):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            if not BANNED.search(text):
                continue
            code, raw = _split(path, text)
            code_lines = code.splitlines()
            for number, line in enumerate(raw.splitlines(), 1):
                if not BANNED.search(line):
                    continue
                # The strippers BLANK rather than delete, so the two halves line
                # up and a line's own code half is at the same index.
                inCode = (number <= len(code_lines)
                          and BANNED.search(code_lines[number - 1]))
                relative = path.relative_to(root)
                if not inCode:
                    kind = "prose"
                elif str(relative).startswith("PostRollApp/Sources"):
                    kind = "copyInTheApp"
                else:
                    kind = "copyElsewhere"
                found[kind].append(f"{relative}:{number}: {line.strip()[:100]}")
    return found


def recorded() -> dict:
    """The baseline, or a zeroed one when there is none yet."""
    try:
        return json.loads(BASELINE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"copyInTheApp": 0, "copyElsewhere": 0, "prose": 0}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true",
                        help="write the current numbers as the new baseline")
    args = parser.parse_args(argv)

    found = offences()
    counts = {kind: len(lines) for kind, lines in found.items()}

    if args.record:
        BASELINE.write_text(json.dumps({
            **counts,
            "measured_on": date.today().isoformat(),
            "_what": [
                "How many lines break the writing style rule, by kind (#948).",
                "copyInTheApp is words on Dan's screen and is held to ZERO",
                "  (#944 cleared it).",
                "copyElsewhere is a prompt or tool string. Held to not growing:",
                "  rewriting a prompt changes what a model is SHOWN and wants",
                "  reading sentence by sentence, which #959 did for three files.",
                "prose is a comment. Held to not growing, for the same reason.",
                "Re-record with: venv/bin/python tools/style_backlog.py --record",
            ],
        }, indent=2) + "\n", encoding="utf-8")
        print("recorded " + " ".join(f"{k}={v}" for k, v in counts.items()))
        return 0

    was = recorded()
    for kind, count in counts.items():
        print(f"{kind}: {count} (baseline {was.get(kind, 0)})")
    for line in found["copyInTheApp"][:20]:
        print(f"  {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
