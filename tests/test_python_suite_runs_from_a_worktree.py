"""#960: the Python suite could not run from a git worktree at all.

`venv/` is gitignored, so it exists in the primary checkout and nowhere else. A
worktree has none, and `venv/bin/python -m pytest` there fails with "no such
file or directory"; the only way through was to type another checkout's
interpreter as an absolute path.

That matters because working in a worktree is what keeps one session from
editing the primary checkout underneath another, which is exactly what broke an
app update on 2026-08-29 (#956, #957). A workflow that only half works is one
people stop using.

`venv-python.sh` resolves the interpreter through git's common dir, the way
`hooks/lib/issue-spool.sh` already resolves a worktree back to the checkout it
belongs to. These tests drive it against real git repositories in `tmp_path`
rather than against the machine's own, so nothing here depends on where this
checkout happens to be or on whether it has a venv (L2, L376).
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest
from source_text import without_prose

REPO_ROOT = Path(__file__).resolve().parent.parent
RESOLVER = REPO_ROOT / "venv-python.sh"


def _run(cwd: Path, argument: str | None = None) -> tuple[str, str]:
    """Source the resolver and report what it decided, and what it said."""
    script = f'. "{RESOLVER}" {argument or ""}; printf %s "$POSTROLL_PYTHON"'
    done = subprocess.run(["bash", "-c", script], cwd=cwd,
                          capture_output=True, text=True)
    return done.stdout, done.stderr


def _git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=cwd, check=True,
                   capture_output=True, text=True)


def _fake_venv(at: Path) -> Path:
    """A directory shaped like a virtualenv, with an interpreter that runs.

    Executable rather than merely present: the resolver tests for `-x`, because
    a half-created venv leaves the directory and not the binary, and reporting
    that as the interpreter would fail later and somewhere else (L67).
    """
    binary = at / "venv" / "bin" / "python"
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_text("#!/bin/sh\necho fake\n", encoding="utf-8")
    binary.chmod(0o755)
    return binary


@pytest.fixture
def primary(tmp_path: Path) -> Path:
    """A git checkout with a venv in it, which is the ordinary case."""
    root = tmp_path / "primary"
    root.mkdir()
    _git(root, "init", "-q", "-b", "main")
    _git(root, "config", "user.email", "t@example.com")
    _git(root, "config", "user.name", "t")
    (root / "README.md").write_text("x", encoding="utf-8")
    _git(root, "add", "README.md")
    _git(root, "commit", "-qm", "first")
    _fake_venv(root)
    return root


def test_the_primary_checkout_resolves_its_own_interpreter(primary: Path) -> None:
    found, said = _run(primary)

    assert found == str(primary / "venv" / "bin" / "python"), said
    assert said == "", f"it complained about a checkout that has a venv: {said}"


def test_a_worktree_resolves_the_primary_checkouts_interpreter(
        primary: Path, tmp_path: Path) -> None:
    """The whole point. A worktree has no venv of its own and never will, since
    the directory is gitignored and nothing creates one there."""
    tree = tmp_path / "wt"
    _git(primary, "worktree", "add", "-q", "-b", "side", str(tree))
    assert not (tree / "venv").exists(), "the fixture is not testing anything"

    found, said = _run(tree)

    assert found == str(primary / "venv" / "bin" / "python"), said
    assert said == "", f"it complained about a worktree it could resolve: {said}"


def test_a_worktree_with_its_own_venv_uses_that_one(
        primary: Path, tmp_path: Path) -> None:
    """The other direction. A worktree given its own venv is using it
    deliberately, and quietly preferring another checkout's would run the tests
    against dependencies nobody there installed."""
    tree = tmp_path / "wt-own"
    _git(primary, "worktree", "add", "-q", "-b", "own", str(tree))
    _fake_venv(tree)

    found, _ = _run(tree)

    assert found == str(tree / "venv" / "bin" / "python")


def test_a_venv_directory_with_no_interpreter_in_it_is_not_an_answer(
        primary: Path, tmp_path: Path) -> None:
    # A half-created venv leaves the directory and not the binary. Reporting
    # that as the interpreter fails later and somewhere else (L67).
    tree = tmp_path / "wt-half"
    _git(primary, "worktree", "add", "-q", "-b", "half", str(tree))
    (tree / "venv" / "bin").mkdir(parents=True)

    found, _ = _run(tree)

    assert found == str(primary / "venv" / "bin" / "python")


def test_with_no_venv_anywhere_it_says_where_it_looked(tmp_path: Path) -> None:
    """It refuses rather than falling back to a system python.

    That interpreter has none of the pinned dependencies, so the suite would
    fail on an import and report a missing PACKAGE rather than a missing
    virtualenv, sending the reader somewhere the problem is not (L11).
    """
    bare = tmp_path / "bare"
    bare.mkdir()

    found, said = _run(bare)

    assert "no PostRoll virtualenv found" in said
    assert str(bare) in said, f"it did not say where it looked: {said}"
    assert found.endswith("/venv/bin/python"), (
        "it answered with something other than a venv path, so whatever runs "
        f"next fails without naming the place that should hold one: {found!r}")
    assert found != "python3" and not found.startswith("/usr/"), (
        "it fell back to a system interpreter, which has none of the pinned "
        "dependencies")


def test_it_answers_about_the_directory_it_is_given_not_its_own(
        primary: Path, tmp_path: Path) -> None:
    # The argument is what makes this file able to test anything: without it
    # the resolver would only ever answer about the checkout the test runs in.
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()

    found, _ = _run(elsewhere, argument=str(primary))

    assert found == str(primary / "venv" / "bin" / "python")


# ── the Makefile actually uses it ────────────────────────────────────────────

def test_no_make_recipe_still_spells_the_interpreter_by_hand() -> None:
    """Built is not wired (L3). The resolver existing changes nothing until
    every recipe asks it, and a single one left behind is the one somebody runs
    from a worktree."""
    lines = (REPO_ROOT / "Makefile").read_text(encoding="utf-8").splitlines()

    hardcoded = [
        f"{n}: {line.strip()}"
        for n, line in enumerate(lines, 1)
        if line.startswith("\t") and "venv/bin/python" in line
    ]

    assert not hardcoded, (
        "these recipes name the interpreter by a path that only exists in the "
        "primary checkout, so they fail from a worktree:\n" + "\n".join(hardcoded))


def test_the_makefile_resolves_it_through_the_shared_definition() -> None:
    # And the check above is not satisfied by a Makefile that stopped running
    # Python at all (L283).
    # As code (#1074). The Makefile explains this resolution in a comment
    # that names the script, so a raw read passes on the explanation
    # alone, which is the defect this very check exists to prevent.
    text = without_prose(REPO_ROOT / "Makefile")

    assert "venv-python.sh" in text, (
        "the Makefile no longer resolves the interpreter through the one shared "
        "definition, so it is either hardcoding it somewhere this check cannot "
        "see or not running Python at all")
    assert "$(PY)" in text


def test_the_resolver_is_executable_and_runs_under_plain_sh() -> None:
    # The Makefile's $(shell ...) runs /bin/sh, not bash, so anything bash-only
    # in there works when a person sources it and fails when make does (L504).
    assert os.access(RESOLVER, os.R_OK)
    done = subprocess.run(
        ["sh", "-c", f'. "{RESOLVER}"; printf %s "$POSTROLL_PYTHON"'],
        cwd=REPO_ROOT, capture_output=True, text=True)

    assert done.returncode == 0, done.stderr
    assert done.stdout.endswith("/venv/bin/python"), done.stdout
