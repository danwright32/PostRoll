"""#528: a local build must be able to catch what CI's compiler rejects.

CI ran Xcode 16.4 while this Mac runs 26.6, and the older compiler rejects code
the newer one accepts. Six CI round trips in one session were compile errors
that build clean locally, every one of them visible only after a push, which
makes the feedback loop minutes long for a class of error a local build should
catch in seconds. It also means a change can look fully verified locally and
still be unbuildable.

The fix is the direction of the inequality, not an exact match. A CI compiler
NEWER than the local one is harmless: it accepts everything the local one does,
so local green stays meaningful. A CI compiler OLDER than the local one is the
hole, because the only machine that can see the error is the one that reports
minutes later.

So: CI selects the Xcode recorded in `PostRollApp/.ci-xcode-version`, and this
holds both ends to it. Nothing here reads a version out of a comment or a
second copy in the workflow, because two places to write it is two places to
drift (L41).
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from tools.check_toolchain import Verdict, parse_version, recorded_ci_version, verdict


REPO_ROOT = Path(__file__).resolve().parent.parent
SWIFT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"
VERSION_FILE = REPO_ROOT / "PostRollApp" / ".ci-xcode-version"


# ── the comparison itself ────────────────────────────────────────────────────

def test_a_local_compiler_newer_than_ci_is_the_hole_this_closes() -> None:
    result = verdict(local=(26, 6), ci=(16, 4))
    assert result.outcome is Verdict.LOCAL_IS_AHEAD
    # The message has to name both, or the person reading it cannot tell which
    # way round the problem is.
    assert "26.6" in result.detail and "16.4" in result.detail


def test_the_same_compiler_on_both_sides_passes() -> None:
    assert verdict(local=(26, 6), ci=(26, 6)).outcome is Verdict.MATCHED


def test_a_ci_compiler_ahead_of_local_is_reported_but_not_a_failure() -> None:
    # This direction only ever produces a local failure for code CI would have
    # accepted, which is the safe way round: it is noticed on the machine that
    # can fix it, in seconds.
    result = verdict(local=(26, 4), ci=(26, 6))
    assert result.outcome is Verdict.CI_IS_AHEAD
    assert result.ok, "a CI compiler ahead of local must not block a build"


def test_only_the_local_ahead_case_fails() -> None:
    assert not verdict(local=(26, 6), ci=(16, 4)).ok
    assert verdict(local=(26, 6), ci=(26, 6)).ok


def test_a_patch_level_counts() -> None:
    assert verdict(local=(26, 6, 1), ci=(26, 6)).outcome is Verdict.LOCAL_IS_AHEAD
    assert verdict(local=(26, 6), ci=(26, 6, 1)).outcome is Verdict.CI_IS_AHEAD


def test_an_unreadable_version_is_not_a_pass() -> None:
    # Absent and unreadable must not land on the permissive side, which is where
    # a failed parse silently goes when it feeds a comparison directly (L50).
    with pytest.raises(ValueError):
        parse_version("Xcode\nBuild version 17F113")


def test_it_reads_the_version_out_of_a_real_xcodebuild_banner() -> None:
    assert parse_version("Xcode 26.6\nBuild version 17F113\n") == (26, 6)
    assert parse_version("Xcode 16.4\nBuild version 16F6\n") == (16, 4)


# ── the two ends read one recorded version ───────────────────────────────────

def test_the_recorded_version_is_readable() -> None:
    assert recorded_ci_version() >= (16, 0), (
        f"{VERSION_FILE} does not hold a version this can compare against"
    )


def test_the_workflow_selects_the_recorded_xcode_rather_than_the_image_default() -> None:
    workflow = SWIFT_WORKFLOW.read_text()
    body = "\n".join(
        line for line in workflow.split("\n") if not line.strip().startswith("#")
    )
    assert ".ci-xcode-version" in body, (
        "the macOS job does not read PostRollApp/.ci-xcode-version, so the "
        "compiler CI uses is whatever the runner image happens to default to "
        "and can move under the repo without a commit"
    )
    assert "xcode-select" in body, (
        "the job reads the recorded version but never selects it, so the "
        "recording is decoration"
    )


def test_the_swift_job_runs_on_an_image_that_can_carry_that_xcode() -> None:
    # macos-15 tops out at Xcode 16.x, which is the mismatch itself.
    major = recorded_ci_version()[0]
    workflow = SWIFT_WORKFLOW.read_text()
    swift_job = workflow.split("swift-unit:", 1)[1].split("\n  reference-frames:", 1)[0]
    runs_on = [
        line.split("runs-on:", 1)[1].strip()
        for line in swift_job.split("\n")
        if line.strip().startswith("runs-on:")
    ]
    assert runs_on, "the swift-unit job has no runs-on, so this guard reads nothing"
    for image in runs_on:
        assert image != "macos-15" or major < 26, (
            f"Xcode {major}.x is recorded but the job runs on {image}, whose newest "
            "Xcode is 16.x. The selection step will fail on every run."
        )


def test_the_install_gate_runs_the_check() -> None:
    # A checker nothing invokes is a checker that never runs, and an unrun check
    # looks exactly like a passing one (L3). This is the gate Dan actually goes
    # through: `postroll` calls the script directly.
    script = REPO_ROOT / "PostRollApp" / "build-install.sh"
    body = "\n".join(
        line for line in script.read_text().split("\n") if not line.strip().startswith("#")
    )
    assert "check_toolchain.py" in body, (
        "build-install.sh never runs tools/check_toolchain.py, so a Mac whose "
        "Xcode has moved ahead of CI's installs a build nothing can reproduce"
    )


# ── the local machine ────────────────────────────────────────────────────────

@pytest.mark.skipif(
    shutil.which("xcodebuild") is None,
    reason="no xcodebuild here; this check belongs to the machines that build the app",
)
def test_this_machine_is_not_ahead_of_the_compiler_ci_will_use() -> None:
    banner = subprocess.run(
        ["xcodebuild", "-version"], capture_output=True, text=True, check=True
    ).stdout
    result = verdict(local=parse_version(banner), ci=recorded_ci_version())
    assert result.ok, result.detail
