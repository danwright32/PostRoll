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

from source_text import swift_files, text_of
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


@pytest.mark.parametrize("entry", entries(), ids=lambda e: e.name)
def test_every_anchor_still_matches_its_file_exactly_once(entry: Entry):
    refuse_if_a_prover_is_working()
    target = REPO_ROOT / entry.file
    assert target.is_file(), f"{entry.file} has moved; update the registry"
    count = text_of(target).count(entry.find)
    assert count == 1, (
        f"the anchor for {entry.name} matches {count} places in {entry.file} "
        f"instead of exactly one, so the recorded perturbation no longer "
        f"names one real place. Anchor: {entry.find!r}")


#: Which file declares each Swift test class, taken once instead of once per
#: entry (#1018).
#:
#: `test_every_named_test_still_exists` re-scanned all 294 files under
#: PostRollApp/Tests for every one of the 439 entries, which is 129,066 reads
#: and regex searches for an answer that does not change during a run: 20s of
#: the runner's Python leg, measured 2026-08-30.
#:
#: The same question, asked the same way. It reads RAW text, comments included,
#: exactly as the per-entry search did, so a class named only in a comment is
#: still found by both and this is a change of cost rather than of meaning
#: (L263). `test_the_class_index_agrees_with_scanning_for_one` holds that.
#:
#: Built off `swift_files`, which refuses an empty walk rather than caching
#: one: an empty index would report every registry entry as naming a class that
#: does not exist, which is loud, but the memo must still never be able to hold
#: it (L286).
_DECLARES = re.compile(r"\bclass (\w+)\b")


@lru_cache(maxsize=None)
def swift_test_classes() -> dict[str, tuple[Path, ...]]:
    found: dict[str, list[Path]] = {}
    for path in swift_files(SWIFT_TESTS_DIR):
        for name in set(_DECLARES.findall(text_of(path))):
            found.setdefault(name, []).append(path)
    assert found, (
        f"no class is declared anywhere under {SWIFT_TESTS_DIR}, so every "
        "registry entry naming a Swift test would be reported as dead")
    return {name: tuple(sorted(paths)) for name, paths in found.items()}


@pytest.mark.parametrize("entry", entries(), ids=lambda e: e.name)
def test_every_named_test_still_exists(entry: Entry):
    if entry.test.startswith("PostRollTests/"):
        _, class_name, method = entry.test.split("/")
        matches = swift_test_classes().get(class_name, ())
        assert len(matches) == 1, (
            f"{class_name} is declared in {len(matches)} files under "
            f"PostRollApp/Tests; the registry entry {entry.name} needs a real "
            "test class")
        assert f"func {method}(" in text_of(matches[0]), (
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
        source = text_of(test_file)
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
    declared = text_of(target) + entry.replace
    for name in sorted(set(re.findall(r"(?m)^\s*([a-z_][A-Za-z0-9_]*)\s*=\s*[^=]",
                                      entry.replace))):
        if name == "_":
            continue
        assert re.search(rf"\b(var|let)\s+{re.escape(name)}\b", declared), (
            f"the {entry.name} perturbation assigns to `{name}`, which "
            f"{entry.file} does not declare, so the mutated tree cannot build "
            f"and the guard can only ever report as unproven rather than as "
            f"kept or broken")


# ── the class index answers the same question the per-entry scan did ─────────
#
# #1018 replaced a scan of all 294 Swift test files, run once per registry
# entry, with one index built per run. A replacement is only safe if it answers
# the SAME question: two implementations behind one name are never compared and
# can implement different rules indefinitely, with every caller reading as
# correct (L263). So the old scan is kept here, as the thing the index is
# checked against, rather than deleted.

def _scanned_for(class_name: str) -> list[Path]:
    """The per-entry scan #1018 replaced, kept as the reference answer."""
    return sorted(
        path for path in sorted(SWIFT_TESTS_DIR.glob("*.swift"))
        if re.search(rf"\bclass {re.escape(class_name)}\b",
                     path.read_text(encoding="utf-8"))
    )


def test_the_class_index_agrees_with_scanning_for_one():
    """Every class the registry actually names, checked in ONE pass.

    Asked per class it would be one full scan per class, which is the very cost
    #1018 removed, so the reference is built by reading each file once and
    running the OLD expression against it for each named class. The expression
    is what is being compared; the number of passes is not.
    """
    named = sorted({entry.test.split("/")[1] for entry in entries()
                    if entry.test.startswith("PostRollTests/")})
    assert len(named) > 5, (
        f"only {named} Swift test classes are named by the registry, so this "
        "comparison is measuring almost nothing")

    reference: dict[str, list[Path]] = {name: [] for name in named}
    for path in sorted(SWIFT_TESTS_DIR.glob("*.swift")):
        source = path.read_text(encoding="utf-8")
        for name in named:
            if re.search(rf"\bclass {re.escape(name)}\b", source):
                reference[name].append(path)

    index = swift_test_classes()
    for name in named:
        assert list(index.get(name, ())) == sorted(reference[name]), (
            f"the index and a direct scan disagree about where {name} is "
            "declared, so one of them is answering a different question")


def test_the_index_and_the_scan_agree_that_an_absent_class_is_absent():
    """The negative direction, which is the one a wrong index would pass."""
    missing = "AClassNoFileDeclaresAnywhereInThisRepository"
    assert swift_test_classes().get(missing) is None
    assert _scanned_for(missing) == []


def test_the_index_is_built_once():
    """Otherwise the cost this replaced is still being paid (L289)."""
    swift_test_classes.cache_clear()
    swift_test_classes()
    swift_test_classes()
    assert swift_test_classes.cache_info().hits == 1


def test_the_index_covers_the_real_tree():
    """An index of nothing would report every entry as naming a dead class,
    and a memo that could hold one would make that permanent (L98, L286)."""
    index = swift_test_classes()
    assert len(index) > 100, f"the index holds only {len(index)} classes"
    assert all(paths for paths in index.values())
