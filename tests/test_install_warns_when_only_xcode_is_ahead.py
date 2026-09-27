"""An install goes ahead, loudly, when the only problem is this Mac's newer Xcode (#1441).

The install gate refused outright whenever this Mac's Xcode was ahead of CI's
pin. With 27.0 here and 26.6 pinned (#1419, not doing until the runner carries
27), that refused EVERY install after the Swift suite had already passed, and
the only way through was SKIP_INSTALL_TESTS=1, which skips the whole Python gate
as well. Dan, 2026-09-27: warn, don't block. Anything else the check finds, a
Python mismatch or a virtualenv built on another app's runtime, still refuses.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from source_text import without_prose
from tools.check_toolchain import Result, Verdict, exit_code

REPO_ROOT = Path(__file__).resolve().parent.parent
GATE = REPO_ROOT / "PostRollApp" / "toolchain-gate.sh"
BUILD_INSTALL = REPO_ROOT / "PostRollApp" / "build-install.sh"

MATCHED = Result(Verdict.MATCHED, "same on both sides")
AHEAD = Result(Verdict.LOCAL_IS_AHEAD, "this Mac is ahead")
CI_AHEAD = Result(Verdict.CI_IS_AHEAD, "CI is ahead")


def test_the_check_says_when_xcode_is_the_only_thing_ahead():
    assert exit_code(xcode=MATCHED, python=MATCHED) == 0
    assert exit_code(xcode=CI_AHEAD, python=MATCHED) == 0
    assert exit_code(xcode=AHEAD, python=MATCHED) == 3
    # A Python problem is not what Dan waived, so it refuses with or without
    # the Xcode one beside it.
    assert exit_code(xcode=MATCHED, python=AHEAD) == 1
    assert exit_code(xcode=AHEAD, python=AHEAD) == 1


def run_gate(check_exit: int):
    """Drive the gate with a stand-in check that exits as asked, and report
    whether the gate let the install on and what it left for the end."""
    script = (f'source "{GATE}"; toolchain_gate bash -c "exit {check_exit}"; '
              'rc=$?; echo "rc=$rc ahead=${XCODE_AHEAD:-0}"; '
              'echo "addopts=${PYTEST_ADDOPTS:-}"')
    # Without any PYTEST_ADDOPTS of its own: the installer runs this suite
    # with the gate's deselect already exported, and an inherited one would
    # answer for the gate (L439).
    env = {k: v for k, v in os.environ.items() if k != "PYTEST_ADDOPTS"}
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                          env=env, timeout=30)


def test_a_clean_check_lets_the_install_on_quietly():
    result = run_gate(0)
    assert "rc=0 ahead=0" in result.stdout, result.stdout + result.stderr
    assert "WARNING" not in result.stderr


def test_xcode_alone_ahead_warns_and_lets_the_install_on():
    result = run_gate(3)
    assert "rc=0 ahead=1" in result.stdout, result.stdout + result.stderr
    assert "WARNING" in result.stderr, "the install went on without saying why"
    assert "CI" in result.stderr, result.stderr


def test_anything_else_the_check_finds_still_refuses():
    for code in (1, 2):
        result = run_gate(code)
        assert "rc=1 ahead=0" in result.stdout, (
            f"a check exiting {code} let the install on: {result.stdout}{result.stderr}")


def test_the_installer_uses_the_gate_and_repeats_the_warning_at_the_end():
    # Built is not wired (L3). The warning is said again after the install,
    # because a line printed above minutes of test output is not read.
    body = without_prose(BUILD_INSTALL)
    assert "toolchain_gate " in body, "the installer does not go through the gate"
    assert 'tools/check_toolchain.py"\n' not in body.replace("toolchain_gate ", ""), (
        "the installer still runs the check bare, where set -e refuses on exit 3")
    assert body.index("toolchain_gate ") < body.index('echo "==> Installed: ${DEST}"')
    tail = body[body.index('echo "==> Installed: ${DEST}"'):]
    assert "XCODE_AHEAD" in tail, "the warning is not repeated once the install is done"


MACHINE_TEST = ("tests/test_toolchain_matches_ci.py::"
                "test_this_machine_is_not_ahead_of_the_compiler_ci_will_use")


def test_a_waived_xcode_gap_is_not_refused_again_by_the_same_comparison_as_a_test():
    # The first real install after the gate shipped still refused: the gate
    # warned and went on, then the fast Python run failed on the machine test,
    # which makes the same comparison (#1441, reopened). Waiving the gap once
    # has to waive it for the install's own test run too, and nothing else.
    result = run_gate(3)
    assert f"--deselect {MACHINE_TEST}" in result.stdout, result.stdout


def test_a_clean_or_refused_check_leaves_the_test_run_alone():
    for code in (0, 1):
        assert f"--deselect {MACHINE_TEST}" not in run_gate(code).stdout


def test_the_deselection_names_a_test_that_exists():
    # A misspelt id deselects nothing and says nothing, and the install would
    # refuse again on this Mac for the same reason (L100).
    import sys
    listed = subprocess.run(
        [sys.executable, "-m", "pytest", "--collect-only", "-q",
         "--deselect", MACHINE_TEST, "tests/test_toolchain_matches_ci.py"],
        capture_output=True, text=True, cwd=REPO_ROOT, timeout=120)
    assert "1 deselected" in listed.stdout, listed.stdout[-800:]
