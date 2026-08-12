"""The guard mutation registry stays honest inside the normal suite (#416).

`tools/check_guards.py` only runs when someone invokes it, so on its own the
registry would rot silently: an anchor drifts, a test gets renamed, and the
mutation check quietly stops covering what it claims to. These run on every
suite run and in CI, and hold the registry to the code in both directions:

* registry to code: every entry's file exists and its anchor matches exactly
  once, so a recorded perturbation still names one real place.
* registry to tests: every named test still exists, so the checker can never
  green-light an entry by running nothing (L98).

What these deliberately do NOT check is the verdict itself: whether the guard
actually goes red on the mutated code needs a real test run against a mutated
tree, which is `make check-guards`.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tools.check_guards import DEFAULT_REGISTRY, Entry, load_registry

REPO_ROOT = Path(__file__).resolve().parent.parent
SWIFT_TESTS_DIR = REPO_ROOT / "PostRollApp" / "Tests"


def entries() -> list[Entry]:
    return load_registry(REPO_ROOT / DEFAULT_REGISTRY)


def test_the_registry_loads_and_is_not_empty():
    """An empty registry checks nothing while looking installed (L98, L65)."""
    assert len(entries()) >= 1


@pytest.mark.parametrize("entry", entries(), ids=lambda e: e.name)
def test_every_anchor_still_matches_its_file_exactly_once(entry: Entry):
    target = REPO_ROOT / entry.file
    assert target.is_file(), f"{entry.file} has moved; update the registry"
    count = target.read_text().count(entry.find)
    assert count == 1, (
        f"the anchor for {entry.name} matches {count} places in {entry.file} "
        f"instead of exactly one, so the recorded perturbation no longer "
        f"names one real place. Anchor: {entry.find!r}")


@pytest.mark.parametrize("entry", entries(), ids=lambda e: e.name)
def test_every_named_test_still_exists(entry: Entry):
    if entry.test.startswith("PostRollTests/"):
        _, class_name, method = entry.test.split("/")
        matches = [
            path for path in sorted(SWIFT_TESTS_DIR.glob("*.swift"))
            if re.search(rf"\bclass {re.escape(class_name)}\b", path.read_text())
        ]
        assert len(matches) == 1, (
            f"{class_name} is declared in {len(matches)} files under "
            f"PostRollApp/Tests; the registry entry {entry.name} needs a real "
            "test class")
        assert f"func {method}(" in matches[0].read_text(), (
            f"{class_name} no longer has {method}; update the {entry.name} "
            "entry")
    else:
        path_part, method = entry.test.split("::")
        # A parametrised node id carries its case in brackets; the function
        # the file declares is the part before them.
        method = method.split("[")[0]
        test_file = REPO_ROOT / path_part
        assert test_file.is_file(), f"{path_part} has moved"
        assert f"def {method}(" in test_file.read_text(), (
            f"{path_part} no longer defines {method}")
