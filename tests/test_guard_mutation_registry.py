"""The guard mutation registry stays honest inside the normal suite (#416).

`tools/check_guards.py` only runs when someone invokes it, so on its own the
registry would rot silently: an anchor drifts, a test gets renamed, and the
mutation check quietly stops covering what it claims to. These run on every
suite run and in CI, and hold the registry to the code in both directions:

* registry to code: every entry's file exists and its anchor matches exactly
  once, so a recorded perturbation still names one real place.
* registry to tests: every named test still exists, so the checker can never
  green-light an entry by running nothing (L98).
* directory to registry: every file on disk is actually loaded, so a glob that
  quietly reads a subset cannot pass for a full registry (#506).

What these deliberately do NOT check is the verdict itself: whether the guard
actually goes red on the mutated code needs a real test run against a mutated
tree, which is `make check-guards`.
"""

from __future__ import annotations

import re
from functools import lru_cache
from pathlib import Path

import pytest

from tools import perturbation_lock
from tools.check_guards import DEFAULT_REGISTRY, Entry, load_registry

REPO_ROOT = Path(__file__).resolve().parent.parent


def refuse_if_a_prover_is_working(repo_root: Path = None) -> None:
    """Stop this check reporting a guard prover's deliberate break as a stale
    entry (#920).

    `check_guards.py` edits a real source file, runs one test and puts it back.
    A suite run alongside it reads the file mid perturbation and fails on
    whichever entry is in flight, naming a real file and a real entry, so it
    reads exactly like a registry that needs updating. Four false alarms in two
    days, all four green on a re-run.

    Three outcomes, three reactions, because a running prover and an abandoned
    lock are opposite situations (L11):

    * nothing held: judge normally.
    * a prover working: this check cannot judge, so it says so and stands down
      rather than asserting something it cannot see.
    * a lock nobody holds: FAIL. Standing down there would disable this check
      for as long as the file sits on disk, and a check that cannot fail is
      indistinguishable from one that passes (L182).
    """
    # Injectable so the three reactions can be asserted against a lock this
    # test controls, rather than against whatever the real checkout happens to
    # be doing. A helper whose input cannot be set is a helper nothing can
    # prove (L196).
    outcome, why = perturbation_lock.verdict(repo_root or REPO_ROOT)
    if outcome is perturbation_lock.Verdict.CANNOT_JUDGE:
        pytest.skip(why)
    if outcome is perturbation_lock.Verdict.STALE:
        pytest.fail(why)
SWIFT_TESTS_DIR = REPO_ROOT / "PostRollApp" / "Tests"


def entries() -> list[Entry]:
    return load_registry(REPO_ROOT / DEFAULT_REGISTRY)


def test_the_registry_loads_and_is_not_empty():
    """An empty registry checks nothing while looking installed (L98, L65)."""
    assert len(entries()) >= 1


def test_every_entry_file_on_disk_is_actually_loaded():
    """The registry is a directory read by globbing (#506), so the count that
    matters is the one on disk: a loader reading a subset of the files reports
    a clean sweep over guards it never touched, which is indistinguishable
    from the full one."""
    files = sorted((REPO_ROOT / DEFAULT_REGISTRY).glob("*.json"))
    assert len(files) >= 1, "no entry files under the registry directory"
    assert {path.stem for path in files} == {e.name for e in entries()}



@lru_cache(maxsize=None)
def _text(path: Path) -> str:
    """One file's text, read once per run (#1018).

    Three parametrised tests walk the whole registry and each re-reads every one
    of its target files, 29.4s of the Python suite to read the same bytes three
    times over. The files cannot change during a run: `refuse_if_a_prover_is_working`
    is what stops a sweep perturbing the tree underneath these, and it runs
    before any of them.

    Refuses an empty read rather than caching it, for the reason a memo always
    has to: a stored nothing is handed to every reader at once and each reports
    a clean check over no content (L286, L98).
    """
    text = path.read_text()
    assert text, f"{path} is empty, so every check reading it would pass over nothing"
    return text


@pytest.mark.parametrize("entry", entries(), ids=lambda e: e.name)
def test_every_anchor_still_matches_its_file_exactly_once(entry: Entry):
    refuse_if_a_prover_is_working()
    target = REPO_ROOT / entry.file
    assert target.is_file(), f"{entry.file} has moved; update the registry"
    count = _text(target).count(entry.find)
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
        # pytest node ids are `path::name` or `path::Class::name`, and both are
        # in the registry: the second is how a file groups a set of related
        # guards under one class. Reading only the first shape raised a
        # ValueError on the second rather than saying anything useful about it.
        path_part, *rest = entry.test.split("::")
        assert rest, f"{entry.name} names no test in {path_part}"
        class_name = rest[0] if len(rest) > 1 else None
        # A parametrised node id carries its case in brackets; the function
        # the file declares is the part before them.
        method = rest[-1].split("[")[0]
        test_file = REPO_ROOT / path_part
        assert test_file.is_file(), f"{path_part} has moved"
        source = _text(test_file)
        if class_name:
            assert f"class {class_name}" in source, (
                f"{path_part} no longer declares {class_name}; update the "
                f"{entry.name} entry")
        assert f"def {method}(" in source, (
            f"{path_part} no longer defines {method}")


@pytest.mark.parametrize("entry", entries(), ids=lambda e: e.name)
def test_no_swift_mutation_assigns_to_a_name_nothing_declares(entry: Entry):
    """A perturbation that cannot COMPILE is not a perturbation (#730).

    `a-failed-rebuild-keeps-its-reason` wrote its failure into `pickError`,
    the review screen's own state at the time. #728 renamed that field and the
    entry kept the old name, so the mutated tree stopped building and
    `check_guards` reported the guard as unproven. That is the honest answer,
    and it arrives only when somebody runs the sweep: the anchor still matched,
    the named test still existed, and every check in this file passed while the
    perturbation had been dead for a commit.

    Narrow on purpose. It reads only bare assignment targets, `name = value` at
    the start of a line, and asks whether the file being perturbed (or the
    replacement itself) declares that name at all. That is the one shape a
    rename breaks, and it says nothing about a call to a method that has moved,
    so the failure message claims only what was measured (L11). Measured across
    all 289 entries while it was written: it named exactly the one dead
    perturbation and nothing else (L147).
    """
    if not entry.file.endswith(".swift"):
        return
    target = REPO_ROOT / entry.file
    assert target.is_file(), f"{entry.file} has moved; update the registry"
    # The replacement's own locals count as declared: a perturbation may
    # introduce a variable and then write to it.
    declared = _text(target) + entry.replace
    for name in sorted(set(re.findall(r"(?m)^\s*([a-z_][A-Za-z0-9_]*)\s*=\s*[^=]",
                                      entry.replace))):
        if name == "_":
            continue
        assert re.search(rf"\b(var|let)\s+{re.escape(name)}\b", declared), (
            f"the {entry.name} perturbation assigns to `{name}`, which "
            f"{entry.file} does not declare, so the mutated tree cannot build "
            f"and the guard can only ever report as unproven rather than as "
            f"kept or broken")
