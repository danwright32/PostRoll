"""A view must not bind FileManager.default to a local the nested helpers share.

#485. `importFromFolder` held `let fm = FileManager.default` and passed it to
nested helpers. That local is task-isolated while the helpers are main actor
isolated, and a Release build refuses it outright:

    error: sending 'fm' risks causing data races
    note: task-isolated 'fm' is captured by a main actor-isolated closure

Debug accepts it, so the error sat on main for three merges with every check
green, because CI built Debug while `make install` builds Release. CI builds
Release now, which is the real catch for this class. This is the cheaper one
that names the specific shape, runs in seconds rather than minutes, and says
what to do instead.

`FileManager.default` is a shared singleton. Reaching for it at each point of
use costs nothing and carries no isolation with it; binding it to a local buys
nothing and carries the isolation of wherever the binding happened.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
VIEWS_DIR = REPO_ROOT / "PostRollApp" / "Sources" / "Views"

#: `let fm = FileManager.default`, under any name.
BINDING = re.compile(r"^\s*(?:let|var)\s+(\w+)\s*(?::\s*FileManager\s*)?=\s*FileManager\.default\s*$")


def view_sources() -> list[Path]:
    return sorted(VIEWS_DIR.rglob("*.swift"))


def bindings_in(text: str) -> list[tuple[int, str]]:
    """Every FileManager local, with comments stripped first (L103)."""
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        if line.strip().startswith("//"):
            continue
        match = BINDING.match(line)
        if match:
            found.append((number, match.group(1)))
    return found


def test_there_are_views_to_scan():
    """An empty scan would pass the assertion below while checking nothing."""
    assert len(view_sources()) > 10


def test_no_view_binds_the_shared_file_manager_to_a_local():
    offenders = []
    for path in view_sources():
        for number, name in bindings_in(path.read_text(encoding="utf-8")):
            offenders.append(f"{path.name}:{number} (let {name} = FileManager.default)")

    assert not offenders, (
        "these bind the shared FileManager to a local. A nested helper that "
        "captures it takes the binding's isolation with it, which a Release "
        "build refuses as a data race while a Debug build accepts. Use "
        "FileManager.default at each point of use instead:\n  "
        + "\n  ".join(offenders))


def test_the_scanner_sees_the_shape_it_looks_for():
    assert bindings_in("        let fm = FileManager.default") == [(1, "fm")]
    assert bindings_in("    let manager: FileManager = FileManager.default") == [(1, "manager")]


@pytest.mark.parametrize("line", [
    "        // let fm = FileManager.default, until #485",
    "        let found = DirectoryListing.of(dir, fileManager: .default)",
    "        FileManager.default.fileExists(atPath: p)",
    "        let store = FileManagerStore.default",
])
def test_what_it_does_not_flag(line):
    """Including a comment recording the removal, which is how a text scan gets
    satisfied by prose about the thing it was written to catch (L103)."""
    assert bindings_in(line) == []
