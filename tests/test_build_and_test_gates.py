"""The two gates that decide whether work is allowed to ship (#106, #98).

Both exist because something passed while protecting nothing: end-to-end media
tests skipping silently in CI, and an untested build being installed to
/Applications. A gate is only real once it has been seen to refuse.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from conftest import ffmpeg_required, should_skip_ffmpeg_tests

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_INSTALL = REPO_ROOT / "PostRollApp" / "build-install.sh"


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


def _stub_dir(tmp_path: Path, *, xcodebuild_exit: int) -> Path:
    """A PATH entry whose xcodebuild exits with the given code."""
    d = tmp_path / "stubbin"
    d.mkdir()
    stub = d / "xcodebuild"
    stub.write_text(
        "#!/bin/sh\n"
        "echo \"stub xcodebuild $*\"\n"
        f"exit {xcodebuild_exit}\n"
    )
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return d


def _run_install(tmp_path: Path, *, xcodebuild_exit: int, env_extra: dict | None = None):
    stubs = _stub_dir(tmp_path, xcodebuild_exit=xcodebuild_exit)
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
