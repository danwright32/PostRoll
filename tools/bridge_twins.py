#!/usr/bin/env python3
"""Every pair that must agree across the Python and Swift halves (#1106).

Before this, a twin was found by a HUMAN noticing one. The evidence that a pair
was covered was a `Mirrors ...` line in a docstring, and every declared pair was
in fact pinned by a shared fixture. The gap was that the declaration is
voluntary: a twin whose author never wrote the comment was invisible to any
sweep built on it, which is a guard checking only what its hand written registry
names (L96, L217).

`is_real_handle` and `isRealHandle` were exactly that. Same question, same name,
two answers, no fixture, and they were found because somebody read both by
chance.

## What makes a pair a candidate

What made that one findable is derivable: a Python `snake_case` name and a Swift
`camelCase` name that map onto each other.

Three narrowings, each for a measured reason rather than to taste:

- **Multi-word names only.** A single word collides constantly (`add`, `at`,
  `fetch`, `finish`, `complete`), and every one of those was a false pair.
  Measured 2026-09-04: 86 candidates without this rule, 33 with it, and the
  removed 53 contained no real twin.
- **No `async` Swift function.** An `async` member here is a CALLER into
  Python, not a second implementation of a rule: it packs some JSON and waits
  for a subprocess. `suggestHandles` and `generateWeek` are those. A twin
  re-implements a pure rule and has nothing to await. This is what separates
  `PythonBridge.suggestHandles` (a caller) from `PythonBridge.isRealHandle` (a
  twin), which live in the same file.
- **No leading underscore on the Python side**, which is that module's own
  business.

## What counts as pinned

A shared fixture under `tests/fixtures/` that BOTH suites read, or one whose
content names the pair. Both routes, because both are how a twin gets pinned
here today: `is_real_handle` is named in `real_handle.json`, and
`layout_problems` is nowhere in `collage_layout_validity.json` while both
suites compare against it.

`guard_mutations/`, the durations record, the goldens and the CI log samples
are excluded: they are tooling records that happen to name things, not
contracts anybody agreed.

    venv/bin/python tools/bridge_twins.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
EXCLUSIONS = REPO_ROOT / "tests" / "fixtures" / "not_a_bridge_twin.json"

#: A module level Python function.
PY_DEF = re.compile(r"^def ([a-z_][a-z0-9_]*)\(", re.M)

#: A Swift function with a body. The third group is everything between the
#: parameter list and the brace, which is where `async` appears.
SW_FUNC = re.compile(r"\bfunc ([a-z]\w*)\s*(?:<[^>]*>)?\(([^)]*)\)\s*([^{]*)\{")

#: Fixtures that are records rather than contracts, so naming a twin in one
#: proves nothing about the two halves agreeing.
NOT_A_CONTRACT = ("guard_mutations", "test_file_durations", "goldens",
                  "ci_logs", "ci_profile")

#: The suffixes a shared contract is written in.
CONTRACT_SUFFIXES = {".json", ".csv", ".txt", ".yml"}


def camel(snake: str) -> str:
    head, *rest = snake.split("_")
    return head + "".join(word.capitalize() for word in rest)


def python_functions(root: Path = REPO_ROOT) -> dict[str, set[str]]:
    found: dict[str, set[str]] = {}
    for path in sorted((root / "postroll").rglob("*.py")):
        for match in PY_DEF.finditer(path.read_text(encoding="utf-8")):
            found.setdefault(match.group(1), set()).add(
                str(path.relative_to(root)))
    return found


def swift_functions(root: Path = REPO_ROOT) -> dict[str, set[str]]:
    """Swift functions with a body, minus the ones that await Python."""
    found: dict[str, set[str]] = {}
    sources = root / "PostRollApp" / "Sources"
    for path in sorted(sources.rglob("*.swift")):
        for match in SW_FUNC.finditer(path.read_text(encoding="utf-8")):
            if "async" in match.group(3):
                continue
            found.setdefault(match.group(1), set()).add(
                str(path.relative_to(root)))
    return found


def contracts(root: Path = REPO_ROOT) -> dict[str, str]:
    """Every shared fixture, by file name, with its text."""
    found = {}
    for path in sorted((root / "tests" / "fixtures").rglob("*")):
        if (path.is_file() and path.suffix in CONTRACT_SUFFIXES
                and not any(x in str(path) for x in NOT_A_CONTRACT)):
            found[path.name] = path.read_text(encoding="utf-8", errors="ignore")
    return found


def _reads(text: str, names: set[str]) -> set[str]:
    return {name for name in names if name in text}


def twins(root: Path = REPO_ROOT) -> list[dict]:
    """Every candidate pair, and what pins it."""
    python, swift = python_functions(root), swift_functions(root)
    shared = contracts(root)
    names = set(shared)

    py_tests = [p.read_text(encoding="utf-8")
                for p in sorted((root / "tests").glob("*.py"))]
    sw_tests = [p.read_text(encoding="utf-8")
                for p in sorted((root / "PostRollApp" / "Tests").glob("*.swift"))]

    found = []
    for name in sorted(python):
        if name.startswith("_") or "_" not in name:
            continue
        twin = camel(name)
        if twin not in swift:
            continue

        # Read by both suites, or named in a contract's own text.
        by_python: set[str] = set()
        for text in py_tests:
            if name in text:
                by_python |= _reads(text, names)
        by_swift: set[str] = set()
        for text in sw_tests:
            if twin in text:
                by_swift |= _reads(text, names)
        named = {f for f, body in shared.items() if name in body or twin in body}

        found.append({
            "python": name,
            "swift": twin,
            "python_files": sorted(python[name]),
            "swift_files": sorted(swift[twin]),
            "pinned_by": sorted((by_python & by_swift) | named),
        })
    return found


def excluded() -> dict[str, str]:
    """Pairs that share a name and are not twins, and why each.

    Keyed by the Python name, carrying the REASON: an entry with no reason is
    evidence nobody reasoned about it (L233).
    """
    if not EXCLUSIONS.exists():
        return {}
    return json.loads(EXCLUSIONS.read_text(encoding="utf-8"))


def main() -> int:
    reasons = excluded()
    unpinned = [t for t in twins()
                if not t["pinned_by"] and t["python"] not in reasons]
    for t in unpinned:
        print(f"{t['python']} <-> {t['swift']}")
        print(f"    {t['python_files'][0]}")
        print(f"    {t['swift_files'][0]}")
    print(f"\n{len(twins())} candidate pairs, {len(unpinned)} unpinned, "
          f"{len(reasons)} excluded with a reason")
    return 1 if unpinned else 0


if __name__ == "__main__":
    sys.exit(main())
