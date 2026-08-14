"""The two gates that decide whether work is allowed to ship (#106, #98).

Both exist because something passed while protecting nothing: end-to-end media
tests skipping silently in CI, and an untested build being installed to
/Applications. A gate is only real once it has been seen to refuse.
"""

from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from conftest import ffmpeg_required, should_skip_ffmpeg_tests

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_INSTALL = REPO_ROOT / "PostRollApp" / "build-install.sh"
CACHE_PATH_FILE = REPO_ROOT / "PostRollApp" / "derived-data-path.sh"


# ── #106: the ffmpeg gate ─────────────────────────────────────────────────────


def test_ffmpeg_present_means_the_tests_run():
    assert not should_skip_ffmpeg_tests(have_ffmpeg=True, require_ffmpeg=False)


def test_ffmpeg_absent_on_a_dev_machine_skips():
    """A laptop without ffmpeg should not fail the whole suite."""
    assert should_skip_ffmpeg_tests(have_ffmpeg=False, require_ffmpeg=True) is False
    assert should_skip_ffmpeg_tests(have_ffmpeg=False, require_ffmpeg=False) is True


def test_ffmpeg_absent_where_it_was_required_does_not_skip():
    """The defect this closes: in CI a skip is indistinguishable from a pass,
    so the tests must run and fail rather than quietly disappear."""
    assert not should_skip_ffmpeg_tests(have_ffmpeg=False, require_ffmpeg=True)


@pytest.mark.parametrize("value,expected", [
    ("1", True), ("true", True), ("yes", True), ("TRUE", True),
    ("", False), ("0", False), ("false", False), ("no", False),
])
def test_the_require_flag_reads_the_obvious_values(value, expected):
    assert ffmpeg_required({"POSTROLL_REQUIRE_FFMPEG": value}) is expected


def test_an_unset_flag_does_not_require_ffmpeg():
    assert ffmpeg_required({}) is False


# ── #98: the install gate ─────────────────────────────────────────────────────
#
# Driven with a stubbed PATH rather than a real build: the point is what the
# script does when the suite is red, and a real xcodebuild would take minutes
# and depend on the machine.


def _stub_dir(tmp_path: Path, *, xcodebuild_exit: int, xcodebuild_output: str = "") -> Path:
    """A PATH entry whose xcodebuild exits with the given code."""
    d = tmp_path / "stubbin"
    d.mkdir()
    stub = d / "xcodebuild"
    extra = f'echo "{xcodebuild_output}"\n' if xcodebuild_output else ""
    stub.write_text(
        "#!/bin/sh\n"
        "echo \"stub xcodebuild $*\"\n"
        + extra
        + f"exit {xcodebuild_exit}\n"
    )
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return d


def _run_install(tmp_path: Path, *, xcodebuild_exit: int, env_extra: dict | None = None,
                 xcodebuild_output: str = ""):
    stubs = _stub_dir(tmp_path, xcodebuild_exit=xcodebuild_exit,
                      xcodebuild_output=xcodebuild_output)
    env = dict(os.environ)
    env["PATH"] = f"{stubs}:{env['PATH']}"
    env.pop("SKIP_INSTALL_TESTS", None)
    env.update(env_extra or {})
    return subprocess.run(
        ["/bin/bash", str(BUILD_INSTALL)],
        capture_output=True, text=True, env=env, timeout=600,
    )


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_a_red_suite_stops_the_install_before_anything_is_built(tmp_path):
    """The failure this closes: compile straight to /Applications with no test
    having run, so a broken build is the one Dan uses."""
    result = _run_install(tmp_path, xcodebuild_exit=65)

    assert result.returncode != 0, "a red suite must not install"
    combined = result.stdout + result.stderr
    assert "==> Building" not in combined, (
        "the gate must stop before the build step, not after it\n" + combined[-2000:]
    )


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_the_escape_hatch_skips_the_suites_deliberately(tmp_path):
    """SKIP_INSTALL_TESTS is the documented override, so it must actually
    bypass the gate rather than being a comment that does nothing."""
    result = _run_install(tmp_path, xcodebuild_exit=65,
                          env_extra={"SKIP_INSTALL_TESTS": "1"})

    combined = result.stdout + result.stderr
    assert "Skipping tests" in combined, combined[-2000:]
    # It still fails, because the stubbed build produces no app bundle. What
    # matters is that it got past the gate to the build at all.
    assert "==> Building" in combined, combined[-2000:]


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_a_missing_venv_is_refused_rather_than_counted_as_a_pass(tmp_path, monkeypatch):
    """An absent Python environment means the generation pipeline went
    unchecked. That is not the same as passing."""
    # Green Swift stub, so the run reaches the Python step.
    stubs = _stub_dir(tmp_path, xcodebuild_exit=0)
    fake_repo = tmp_path / "repo"
    (fake_repo / "PostRollApp").mkdir(parents=True)
    shutil.copy2(BUILD_INSTALL, fake_repo / "PostRollApp" / "build-install.sh")
    # The script sources this for the shared build-cache location (#485), so a
    # copy of the script without it cannot run at all.
    shutil.copy2(CACHE_PATH_FILE, fake_repo / "PostRollApp" / "derived-data-path.sh")
    # No venv/ in fake_repo at all.

    env = dict(os.environ)
    env["PATH"] = f"{stubs}:{env['PATH']}"
    env.pop("SKIP_INSTALL_TESTS", None)
    result = subprocess.run(
        ["/bin/bash", str(fake_repo / "PostRollApp" / "build-install.sh")],
        capture_output=True, text=True, env=env, timeout=600,
    )

    assert result.returncode != 0
    combined = result.stdout + result.stderr
    assert "venv" in combined, combined[-2000:]
    assert "==> Building" not in combined, combined[-2000:]


# ── #271: a refused folder is not a red suite ─────────────────────────────────
#
# The repo lives under ~/Documents, which macOS protects, so the test process
# needs Documents access to read its own fixtures. On one run that was refused
# and five fixture-reading suites failed at once, which read as five broken
# suites. A gate that fails for reasons unrelated to the code teaches the
# operator to bypass it every time, and a gate that is always bypassed is the
# same as no gate.


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_a_permissions_refusal_is_named_as_one(tmp_path):
    result = _run_install(tmp_path, xcodebuild_exit=65,
                          xcodebuild_output="error: Operation not permitted")

    assert result.returncode != 0, "it still refuses to install"
    combined = result.stdout + result.stderr
    assert "permissions problem" in combined, combined[-2000:]
    assert "Privacy & Security" in combined, combined[-2000:]
    assert "SKIP_INSTALL_TESTS=1 is safe FOR THIS CAUSE ONLY" in combined, combined[-2000:]


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_an_ordinary_red_suite_is_not_blamed_on_permissions(tmp_path):
    # The two need opposite responses: one is a code failure to fix, the other
    # is a machine setting. Telling the operator to grant folder access for a
    # genuine test failure sends the diagnosis somewhere unrelated (L11).
    result = _run_install(tmp_path, xcodebuild_exit=65,
                          xcodebuild_output="error: XCTAssertEqual failed")

    combined = result.stdout + result.stderr
    assert "permissions problem" not in combined, combined[-2000:]


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_the_swift_output_still_reaches_the_operator_on_a_green_run(tmp_path):
    """Capturing the output to classify it must not swallow it: the run's own
    log is how anyone reads what happened.

    Run from a copy with no venv, so it stops at the Python step rather than
    going on to run the real suite (which is this one) inside itself.
    """
    stubs = _stub_dir(tmp_path, xcodebuild_exit=0, xcodebuild_output="Executed 927 tests")
    fake_repo = tmp_path / "repo"
    (fake_repo / "PostRollApp").mkdir(parents=True)
    shutil.copy2(BUILD_INSTALL, fake_repo / "PostRollApp" / "build-install.sh")
    # The script sources this for the shared build-cache location (#485), so a
    # copy of the script without it cannot run at all.
    shutil.copy2(CACHE_PATH_FILE, fake_repo / "PostRollApp" / "derived-data-path.sh")

    env = dict(os.environ)
    env["PATH"] = f"{stubs}:{env['PATH']}"
    env.pop("SKIP_INSTALL_TESTS", None)
    result = subprocess.run(
        ["/bin/bash", str(fake_repo / "PostRollApp" / "build-install.sh")],
        capture_output=True, text=True, env=env, timeout=600,
    )

    combined = result.stdout + result.stderr
    assert "Executed 927 tests" in combined, combined[-2000:]
    assert "permissions problem" not in combined, combined[-2000:]


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_the_install_gate_runs_the_suite_the_make_target_defines():
    """One spelling of the Python run, not two (#430).

    This script used to carry its own `pytest tests/ -q`, identical to the
    Makefile's. The day the full run was split into a serial pass and a parallel
    one, the install gate would have gone on running the old single command and
    nothing would have said so: it would still have been a full green suite, just
    five minutes slower than the one everybody else was running.

    Comment lines are stripped first, so the prose explaining the delegation
    cannot satisfy the check for it (L103).
    """
    code = "\n".join(
        line for line in BUILD_INSTALL.read_text().splitlines()
        if not line.strip().startswith("#")
    )

    assert re.search(r"make\s+-C\s+\S+\s+test-python", code), (
        "the install gate does not run the Makefile's Python test target, so "
        "how it runs the suite can drift from how everything else does")
    assert "-m pytest" not in code, (
        "the install gate has its own pytest invocation again; the Makefile is "
        "the one place that decides what the full run is")


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_the_install_script_uses_no_bsd_only_shell_forms():
    """The script runs on this Mac; parts of it also run under the Linux CI job.

    The short `-t NAME` form of mktemp is BSD-only and GNU mktemp refuses it,
    so a line that worked perfectly here failed on every CI run until somebody
    read the log. Checked as a class rather than on the one flag, because the
    next BSD-ism will be a different one.

    The needle is built from parts so this file, and the script's own comment
    explaining the rule, do not match the very thing they describe.
    """
    text = BUILD_INSTALL.read_text()
    assert ("mktemp" + " -t ") not in text, (
        "the short -t form of mktemp is BSD-only; GNU mktemp needs an explicit "
        "XXXXXX template, so use ${TMPDIR:-/tmp}/name.XXXXXX instead")
    assert "sed -i ''" not in text, (
        "`sed -i ''` is BSD-only; GNU sed reads the '' as a script")


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_the_install_gate_runs_the_fast_subset_and_ci_still_runs_everything():
    """#432: installs stop paying for the four reel-rendering files.

    This is a deliberate relaxation of #98's full-suite install gate, and it is
    only defensible while the full suite still gates every merge. Both halves are
    asserted here, because the second is what makes the first safe: if CI ever
    started deselecting the slow files too, nothing anywhere would run them and
    this test would be the only place that could have said so.
    """
    script = "\n".join(
        line for line in BUILD_INSTALL.read_text().splitlines()
        if not line.strip().startswith("#")
    )

    assert "test-python-fast" in script, (
        "the install gate no longer runs the fast subset, so either it is back to "
        "the full suite or it runs nothing")

    workflow = REPO_ROOT / ".github" / "workflows" / "tests.yml"
    ci = "\n".join(
        line for line in workflow.read_text().splitlines()
        if not line.strip().startswith("#")
    )
    assert "not slow" not in ci, (
        "CI is deselecting the slow files as well, so the four files that render "
        "real reels now run nowhere: the install gate was relaxed on the promise "
        "that every merge still runs them")
