"""#993: CI's Release build compiles one architecture, the shipped one builds both.

`swift-unit` is the pull request critical path, and its `Build the app` step was
132s of a 410s job. Release builds universal by default, so every source is
compiled whole-module for arm64 AND for x86_64, with a separate link per slice.
Read off a real runner log on 2026-08-30: one whole-module `SwiftCompile normal
arm64`, one whole-module `SwiftCompile normal x86_64`, and two `Ld` lines under
`Release/PostRoll.build/Objects-normal/`.

That second slice runs on no machine this app is installed on, and it is not
what the step exists to catch. The step is there for the Release-only
diagnostics of #485 and #521, which are the same for both slices.

## Two separate rules, and they point opposite ways

CI builds ONE architecture, because it is buying diagnostics and pays for them
twice. `make build` and the shipped bundle build BOTH, because that is what
somebody installs. A change that gave `ONLY_ACTIVE_ARCH=YES` to the shipping
build would ship a bundle that runs on one kind of Mac, which is a far worse
failure than a slow CI job and would look exactly like this speedup.

So both directions are asserted here. A guard that only checked CI carried the
flag would be silent on the dangerous half (L142: check WHICH half the
observation covers).

## The exemption has a reviewer

Dropping a slice is only safe while nothing is architecture-specific. Nothing is
today, measured: no `#if arch` or `#if targetEnvironment` anywhere in
`PostRollApp/Sources` or `PostRollApp/Tests`. That is a property of the code
right now, not a promise, so it is checked rather than recorded in a comment,
and the day somebody writes one this fails and names why (L96, L129: a category
exempted for a correct reason has no reviewer unless one is named in the same
change).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"
MAKEFILE = REPO_ROOT / "Makefile"
SWIFT_DIRS = (REPO_ROOT / "PostRollApp" / "Sources",
              REPO_ROOT / "PostRollApp" / "Tests")

FLAG = "ONLY_ACTIVE_ARCH=YES"

#: The shapes that make a source file's meaning depend on the architecture it is
#: compiled for. Matched on shape rather than by listing spellings, so a form
#: nobody thought of is covered the day it lands (L96).
#: `#elseif` is Swift's spelling; `#elif` is C's. The first version of this
#: pattern only had `#(?:el)?if`, which covers `#if` and `#elif` and NOT the
#: one Swift actually uses, so it would have read every `#elseif arch(...)` in
#: the codebase as innocent. Caught by the control below rather than by review.
ARCH_CONDITIONAL = re.compile(
    r"#(?:el(?:se)?)?if\s+(?:!\s*)?(?:arch\s*\(|targetEnvironment\s*\()")


def _step(name: str) -> str:
    """One workflow step's body, comments dropped.

    Comments here name every setting they explain, so a scan of the raw text
    could be satisfied by prose describing a flag that had been deleted (L103).
    """
    text = "\n".join(line for line in WORKFLOW.read_text(encoding="utf-8").splitlines()
                     if not line.strip().startswith("#"))
    match = re.search(rf"^      - name: {re.escape(name)}\s*$(.*?)(?=^      - |\Z)",
                      text, re.M | re.S)
    assert match, (
        f"there is no `{name}` step in swift.yml any more, so this is reading "
        "nothing rather than reading a clean step (L98)")
    return match.group(1)


def _make_target(name: str) -> str:
    text = "\n".join(line for line in MAKEFILE.read_text(encoding="utf-8").splitlines()
                     if not line.strip().startswith("#"))
    match = re.search(rf"^{re.escape(name)}:\s*$(.*?)(?=^\S|\Z)", text, re.M | re.S)
    assert match, f"there is no `{name}:` target in the Makefile any more"
    return match.group(1)


def test_the_ci_release_build_compiles_one_architecture():
    build = _step("Build the app")
    assert FLAG in build, (
        f"the CI Release build has no {FLAG}, so it compiles the whole module "
        "twice and links twice for a slice that runs on no machine this app is "
        "installed on. That was 132s of a 410s job on the pull request critical "
        "path.")


def test_the_shipped_build_still_compiles_both():
    """The dangerous direction. A universal app built for one architecture runs
    on one kind of Mac, and the failure is invisible until somebody installs it
    on the other."""
    assert FLAG not in _make_target("build"), (
        f"`make build` carries {FLAG}, so the bundle somebody installs is built "
        "for whichever architecture happened to build it. CI may drop a slice "
        "because it is buying diagnostics; the shipped app may not.")


def test_the_installer_still_compiles_both():
    """`make install` goes through build-install.sh, which is what actually
    produces the signed bundle, so the rule has to reach there too rather than
    stopping at the target this file happened to look at (L247)."""
    script = REPO_ROOT / "PostRollApp" / "build-install.sh"
    assert script.exists(), "build-install.sh has moved, so this reads nothing"
    assert FLAG not in script.read_text(encoding="utf-8"), (
        f"the install script carries {FLAG}, so the bundle it signs is built "
        "for one architecture")


def _swift_files() -> list[Path]:
    found = [path for directory in SWIFT_DIRS
             for path in sorted(directory.rglob("*.swift"))]
    assert len(found) > 100, (
        f"only {len(found)} Swift files found, so the scan below would pass "
        "over almost nothing (L98)")
    return found


def test_nothing_in_the_app_is_architecture_specific():
    """What makes dropping a slice safe, checked rather than assumed.

    If this ever fails it is not necessarily wrong to add such code; it is that
    the CI build stops being a build of the same program the other slice would
    have been, and somebody has to decide that on purpose.
    """
    offenders = [f"{path.relative_to(REPO_ROOT)}:{n}"
                 for path in _swift_files()
                 for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
                 if ARCH_CONDITIONAL.search(line)]
    assert not offenders, (
        "these lines make the build depend on the architecture it is compiled "
        f"for, and CI now compiles only one: {offenders}. Either make the code "
        f"architecture-neutral, or take {FLAG} off the CI build and accept the "
        "second slice's cost.")


def test_the_scan_can_actually_see_an_architecture_conditional(tmp_path):
    """The guard's own mechanism, seen working (L1). Without this the check
    above passes whenever the pattern stops matching, which is the same green as
    a codebase with none."""
    for source in ("#if arch(x86_64)", "  #elseif arch(arm64)",
                   "#if targetEnvironment(simulator)", "#if !arch(arm64)"):
        assert ARCH_CONDITIONAL.search(source), f"not matched: {source!r}"
    for innocent in ("#if DEBUG", "// #if arch(x86_64) in a comment is prose",
                     "#if POSTROLL_TESTS"):
        if innocent.startswith("//"):
            continue
        assert not ARCH_CONDITIONAL.search(innocent), f"over-matched: {innocent!r}"
