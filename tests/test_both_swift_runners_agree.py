"""#992: `make test-swift` and the CI step run the Swift suite the same way.

Two places invoke the same suite, and since #992 they carry three settings that
have to match or the two disagree about what was proved: parallel execution, a
result bundle to count from, and the bundle being handed to `suite_counts.py`
as well as to xcodebuild.

A setting present in one and not the other is the failure this exists to stop,
and it is silent in the direction that matters. A local run that is serial while
CI is parallel passes every shared-state bug straight through to the runner,
which is exactly the class of defect parallelism introduces and exactly what
#992 found: the review sheet dump failed the first time the suite ran in
parallel, and would have gone on passing locally forever.

Derived from the two files rather than from a list of expected flags kept here,
so a fourth setting added to one side is reported the day it lands rather than
the day somebody remembers this file (L41, L96).

Read as text rather than parsed, for the reason `tests/test_ci_gates.py` gives:
a YAML parser is not worth a runtime dependency for this. Comment lines are
dropped first, because both places explain every one of these settings in prose
that names it, and a guard satisfied by the comment describing a rule would pass
over the rule having been deleted (L103).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
MAKEFILE = REPO_ROOT / "Makefile"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"

#: What each side must carry. The VALUES are not compared, only the presence of
#: each setting: the bundle paths differ legitimately (one is under the build
#: directory the Makefile computes, the other under the runner's checkout), and
#: pinning the paths equal would be a guard on a coincidence rather than on the
#: rule (L63).
SETTINGS = {
    "parallel execution": "-parallel-testing-enabled YES",
    "a result bundle for xcodebuild to write": "-resultBundlePath",
    "that bundle handed to the counter": "--result-bundle",
    "a worker count sized on the machine": "-parallel-testing-worker-count",
}


def _uncommented(text: str, marker: str) -> str:
    return "\n".join(line for line in text.splitlines()
                     if not line.strip().startswith(marker))


@pytest.fixture
def make_target() -> str:
    """The body of `test-swift`, so a claim about it cannot be met by another
    target that happens to use the same flag."""
    text = _uncommented(MAKEFILE.read_text(encoding="utf-8"), "#")
    match = re.search(r"^test-swift:\s*$(.*?)(?=^\S|\Z)", text, re.M | re.S)
    assert match, (
        "there is no `test-swift:` target in the Makefile any more, so every "
        "check derived from it is reading nothing (L98)")
    return match.group(1)


@pytest.fixture
def ci_step() -> str:
    """The `Run the Swift unit tests` step, for the same reason."""
    text = _uncommented(WORKFLOW.read_text(encoding="utf-8"), "#")
    match = re.search(
        r"^      - name: Run the Swift unit tests\s*$(.*?)(?=^      - |\Z)",
        text, re.M | re.S)
    assert match, (
        "there is no `Run the Swift unit tests` step in swift.yml any more, so "
        "this is comparing the make target against nothing")
    return match.group(1)


@pytest.mark.parametrize("what,flag", sorted(SETTINGS.items()))
def test_the_make_target_carries_it(make_target, what, flag):
    assert flag in make_target, (
        f"`make test-swift` no longer asks for {what} ({flag}), so a local run "
        "proves something different from what CI proves, and the difference is "
        "invisible until a runner finds it")


@pytest.mark.parametrize("what,flag", sorted(SETTINGS.items()))
def test_the_ci_step_carries_it(ci_step, what, flag):
    assert flag in ci_step, (
        f"the CI Swift step no longer asks for {what} ({flag}), so the runner "
        "proves something different from what a local run proves")


def test_neither_side_puts_parallelism_in_the_scheme():
    """The scheme is deliberately left serial (#992).

    `tools/check_guards.py` runs ONE test at a time through this scheme to watch
    it go red. Parallelism means nothing to a single test, and it would take the
    `Executed N tests` line away from all 60-odd Swift guard entries, which is
    the only thing that tells a proof that ran from one that never started.

    Asserted here rather than left to a comment, because the flag and the scheme
    setting do the same thing from two places and the scheme is the tempting one
    (L263).

    Scoped to the `schemes:` section before looking for `PostRollTests:`, because
    project.yml carries that name TWICE at the same indent, once as a target and
    once as a scheme. Written without the scoping this matched the target, and a
    `parallelizable: true` added to the real scheme sailed straight past it: a
    guard matching over the wrong region passes while the thing it names is
    broken (L135). Caught by mutating the file and watching this test stay green.
    """
    spec = (REPO_ROOT / "PostRollApp" / "project.yml").read_text(encoding="utf-8")
    schemes = re.search(r"^schemes:\s*$(.*?)(?=^\S|\Z)", spec, re.M | re.S)
    assert schemes, (
        "project.yml declares no `schemes:` section, so this is reading nothing "
        "at all rather than reading a clean scheme (L98)")
    block = re.search(r"^  PostRollTests:\s*$(.*?)(?=^  \S|\Z)",
                      schemes.group(1), re.M | re.S)
    assert block, "the PostRollTests scheme is gone, so this reads nothing"
    assert "parallelizable" not in block.group(1), (
        "the PostRollTests scheme turns on parallel testing, which also applies "
        "to the one-test-at-a-time runs tools/check_guards.py makes. Those read "
        "the executed-tests total that a parallel run does not print, so every "
        "Swift guard entry would report ERROR rather than a verdict. Keep it on "
        "the two full-suite command lines instead.")


def test_the_counter_is_what_runs_the_suite_on_both_sides(make_target, ci_step):
    """Neither side may call xcodebuild directly.

    The count is a SECOND verdict beside xcodebuild's exit code, and it is the
    one that says the suite was reached rather than green. A run that bypassed
    the wrapper would still report TEST SUCCEEDED having executed nothing (L53).
    """
    for label, body in (("make test-swift", make_target), ("the CI step", ci_step)):
        assert "suite_counts.py run swift" in body, (
            f"{label} runs xcodebuild without the counter, so a run that "
            "executed no tests reports exactly like a full one (L98)")
