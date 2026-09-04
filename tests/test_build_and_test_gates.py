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


#: The marker the stub xcbeautify prints, so a test can prove the log really was
#: piped through it rather than through the `cat` fallback wearing the same
#: result. Two branches that produce identical output are one untested branch.
XCBEAUTIFY_MARKER = "stub xcbeautify saw the log"

#: A PATH with nothing on it but the stubs and the system tools the script
#: needs. Used to make the ABSENCE of xcbeautify a fact of the test rather than
#: a fact of whichever machine happens to be running it.
BARE_PATH_DIRS = "/usr/bin:/bin"


def _write_stub(path: Path, body: str) -> None:
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def _stub_dir(tmp_path: Path, *, xcodebuild_exit: int, xcodebuild_output: str = "",
              with_xcbeautify: bool = False) -> Path:
    """A PATH entry whose xcodebuild exits with the given code.

    `with_xcbeautify` adds a passthrough stub of it. The script pipes the Swift
    log through xcbeautify when it is installed and through `cat` when it is
    not, and which of those happens was, until #510 put this suite on a Mac,
    decided entirely by the machine: the Linux CI image and this Mac both lack
    xcbeautify, so the branch that actually runs on a developer machine with it
    installed had never been exercised anywhere (L101, L102).
    """
    d = tmp_path / "stubbin"
    d.mkdir()
    extra = f'echo "{xcodebuild_output}"\n' if xcodebuild_output else ""
    _write_stub(
        d / "xcodebuild",
        "echo \"stub xcodebuild $*\"\n" + extra + f"exit {xcodebuild_exit}\n",
    )
    if with_xcbeautify:
        # Passthrough, not a reimplementation: what is under test is that the
        # script hands the captured log on to the operator, not what the real
        # xcbeautify chooses to render from it.
        _write_stub(d / "xcbeautify", f'echo "{XCBEAUTIFY_MARKER}"\nexec cat\n')
    return d


def _run_install(tmp_path: Path, *, xcodebuild_exit: int, env_extra: dict | None = None,
                 xcodebuild_output: str = ""):
    stubs = _stub_dir(tmp_path, xcodebuild_exit=xcodebuild_exit,
                      xcodebuild_output=xcodebuild_output)
    env = dict(os.environ)
    env["PATH"] = f"{stubs}:{env['PATH']}"
    env.pop("SKIP_INSTALL_TESTS", None)
    # These tests are about the TEST gate, and they run the real script against
    # the real checkout, which is dirty whenever somebody is working. Without
    # this they would pass or fail on whether the tree happened to be clean,
    # which is a test asserting about the machine rather than the code (L205).
    # The checkout gate has its own tests below, with git stubbed.
    env["ALLOW_DIRTY_INSTALL"] = "1"
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


def _run_green_install(tmp_path: Path, *, with_xcbeautify: bool):
    """A green Swift run of the script, from a copy with no venv so it stops at
    the Python step rather than going on to run the real suite (which is this
    one) inside itself.

    PATH is built from scratch rather than inherited, so whether xcbeautify is
    found is decided here and not by the machine.
    """
    stubs = _stub_dir(tmp_path, xcodebuild_exit=0,
                      xcodebuild_output="Executed 927 tests",
                      with_xcbeautify=with_xcbeautify)
    fake_repo = tmp_path / "repo"
    (fake_repo / "PostRollApp").mkdir(parents=True)
    shutil.copy2(BUILD_INSTALL, fake_repo / "PostRollApp" / "build-install.sh")
    # The script sources this for the shared build-cache location (#485), so a
    # copy of the script without it cannot run at all.
    shutil.copy2(CACHE_PATH_FILE, fake_repo / "PostRollApp" / "derived-data-path.sh")

    env = dict(os.environ)
    env["PATH"] = f"{stubs}:{BARE_PATH_DIRS}"
    env.pop("SKIP_INSTALL_TESTS", None)
    result = subprocess.run(
        ["/bin/bash", str(fake_repo / "PostRollApp" / "build-install.sh")],
        capture_output=True, text=True, env=env, timeout=600,
    )
    return result.stdout + result.stderr


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_the_swift_output_reaches_the_operator_with_no_xcbeautify(tmp_path):
    """Capturing the output to classify it must not swallow it: the run's own
    log is how anyone reads what happened.

    This is the `cat` fallback, pinned by a PATH that genuinely has no
    xcbeautify on it.
    """
    combined = _run_green_install(tmp_path, with_xcbeautify=False)

    assert XCBEAUTIFY_MARKER not in combined, (
        "this case is meant to exercise the fallback, and xcbeautify ran")
    assert "Executed 927 tests" in combined, combined[-2000:]
    assert "permissions problem" not in combined, combined[-2000:]


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_the_swift_output_reaches_the_operator_through_xcbeautify(tmp_path):
    """The same promise on the other branch, which is the one that runs on a
    machine with xcbeautify installed.

    The marker is asserted first: without it this test would pass by quietly
    taking the `cat` fallback, which is the same way the single version of this
    check passed everywhere for months while never once exercising the pipe
    (L70).
    """
    combined = _run_green_install(tmp_path, with_xcbeautify=True)

    assert XCBEAUTIFY_MARKER in combined, (
        "the log was not piped through xcbeautify, so this proves nothing about "
        f"that branch: {combined[-2000:]}")
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
        "CI is deselecting the slow files as well, so the files the fast local "
        "run skips now run nowhere: the install gate was relaxed on the promise "
        "that every merge still runs them")


# ── The screenshot baseline survives an ordinary suite run (#644) ─────────────


def _makefile() -> str:
    return (Path(__file__).resolve().parent.parent / "Makefile").read_text()


def _review_tests() -> list[str]:
    """The renderings, read from the one list the Makefile keeps them in."""
    text = _makefile()
    start = text.index("REVIEW_TESTS := ")
    block = text[start:text.index("\n\n", start)]
    names = [line.strip().rstrip("\\").strip()
             for line in block.split("\n")[1:]]
    return [name for name in names if name]


def test_the_makefile_names_the_renderings_once():
    """If this finds nothing the two checks below pass while proving nothing
    (L98)."""
    assert len(_review_tests()) >= 3, _review_tests()


def _recipe(name: str) -> str:
    """One make target's recipe, and only that one.

    Read per target rather than as the span between two headers, because #932
    split the Swift run out of `test:` into `test-swift:` and a span from `test`
    to `test-python` then covered BOTH. Either check below would have gone on
    passing while measuring a target neither of them is about, which is what a
    split does to every guard calibrated against the whole (L220).
    """
    text = _makefile()
    header = re.search(rf"^{re.escape(name)}:(?!=)", text, re.M)
    assert header, f"there is no {name} target in the Makefile"

    lines = []
    for line in text[header.end():].splitlines()[1:]:
        if line.startswith("\t"):
            lines.append(line)
        elif not line.strip() or line.lstrip().startswith("#"):
            continue
        else:
            break
    return "\n".join(lines)


def test_the_rendering_run_is_a_target_of_its_own():
    """The precondition of both checks below. If the Swift leg stopped being a
    target with a recipe, `_recipe` would return nothing and an empty string
    contains no forbidden spec, so both would pass while reading nothing
    (L98, L100)."""
    assert "xcodebuild" in _recipe("test-swift")


def test_an_ordinary_suite_run_skips_the_renderings():
    """The dumps clear the sheet folder and keep what was there as the
    baseline, so rendering them during the Swift leg rotated the POST-change
    pictures into the baseline and the comparison then reported that nothing
    had moved (#644).

    A comparison reporting no difference because its reference point was
    overwritten is worse than no comparison, because it is believed."""
    body = _recipe("test-swift")

    for name in _review_tests():
        assert f"-skip-testing:{name}" in body or "$(REVIEW_TESTS)" in body, (
            f"the Swift leg runs {name}, which re-renders the review sheet and "
            "consumes the baseline the comparison needs")


def test_the_sheet_selects_exactly_what_the_suite_skips():
    """One list, so the two cannot drift into disagreeing about which tests are
    renderings rather than checks (L41)."""
    target = _makefile()
    selecting = target[target.index("\nreview-sheet:"):]

    assert "$(foreach t,$(REVIEW_TESTS),-skip-testing:$(t))" in _recipe("test-swift")
    assert "$(foreach t,$(REVIEW_TESTS),-only-testing:$(t))" in selecting


# ── the gate says what it vouched for, and refuses what it cannot (#957) ─────
#
# On 2026-08-29 an update ran the pre-install Swift suite against a checkout
# carrying another session's uncommitted work AND a branch switch mid run. It
# failed after four minutes on a source-scanning test reading a file swapped out
# underneath it (#956). The build was fine; Dan saw that his app was out of
# date, the update had stopped, and a test name that meant nothing to him.
#
# `git` is stubbed rather than the real checkout being dirtied, so nothing here
# can touch the tree it is running from (L2).

def _git_stub(d: Path, *, status: str = "", heads: list[str] | None = None) -> None:
    """A `git` whose status and successive HEADs the test chooses.

    The heads are consumed in order from a counter file, so a run that reads
    HEAD twice can be given two different answers, which is the branch-switch
    case and the one that cannot be staged any other way.
    """
    revs = heads or ["deadbeef"]
    # POSIX `sh` only. `_write_stub` writes a `#!/bin/sh` shebang, and on Ubuntu
    # that is dash: a first version used a bash ARRAY to hold the heads, which
    # works on this Mac because /bin/sh is bash there and fails on every Linux
    # CI run. That is the same trap `test_the_install_script_uses_no_bsd_only_
    # shell_forms` exists for, one file along (L504).
    _write_stub(d / "git", f"""
counter="${{TMPDIR:-/tmp}}/postroll-git-stub-count"
case "$*" in
  *"rev-parse --git-dir"*) echo ".git" ;;
  *"status --porcelain"*) printf '%s' {status!r} ;;
  *"rev-parse HEAD"*)
    n=$(cat "$counter" 2>/dev/null || echo 0)
    echo $((n + 1)) > "$counter"
    set -- {" ".join(revs)}
    while [ "$n" -gt 0 ] && [ "$#" -gt 1 ]; do
      shift
      n=$((n - 1))
    done
    echo "$1"
    ;;
  *) echo "" ;;
esac
exit 0
""")


def _run_install_with_git(tmp_path: Path, *, status: str = "",
                          heads: list[str] | None = None,
                          xcodebuild_exit: int = 0,
                          env_extra: dict | None = None):
    stubs = _stub_dir(tmp_path, xcodebuild_exit=xcodebuild_exit)
    _git_stub(stubs, status=status, heads=heads)
    counter = Path(os.environ.get("TMPDIR", "/tmp")) / "postroll-git-stub-count"
    counter.unlink(missing_ok=True)
    env = dict(os.environ)
    env["PATH"] = f"{stubs}:{env['PATH']}"
    env.pop("SKIP_INSTALL_TESTS", None)
    env.pop("ALLOW_DIRTY_INSTALL", None)
    env.update(env_extra or {})
    return subprocess.run(["/bin/bash", str(BUILD_INSTALL)],
                          capture_output=True, text=True, env=env, timeout=600)


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_a_dirty_checkout_is_refused_before_the_suite_is_paid_for(tmp_path):
    result = _run_install_with_git(tmp_path, status=" M PostRollApp/Sources/AppState.swift\n")

    assert result.returncode != 0, "a dirty tree installed anyway"
    combined = result.stdout + result.stderr
    assert "AppState.swift" in combined, (
        "it refused without naming what is uncommitted, so the person has to go "
        f"and find out: {combined[-800:]}")
    assert "Running the Swift tests" not in combined, (
        "it paid for the four minute suite before discovering the checkout was "
        "unusable, which is half of what #957 is about")


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_the_refusal_names_the_override(tmp_path):
    # A message that tells somebody how to recover has to name a step that
    # changes the state they are stuck in (L111), and installing from the
    # working tree deliberately is a real thing to want.
    result = _run_install_with_git(tmp_path, status=" M a.swift\n")

    assert "ALLOW_DIRTY_INSTALL=1" in result.stdout + result.stderr


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_the_override_installs_from_the_working_tree_and_says_so(tmp_path):
    # The positive control (L159). Without it, "a dirty tree is refused" is
    # satisfied by a script that refuses everything.
    result = _run_install_with_git(
        tmp_path, status=" M a.swift\n",
        env_extra={"ALLOW_DIRTY_INSTALL": "1", "SKIP_INSTALL_TESTS": "1"})

    combined = result.stdout + result.stderr
    assert "ALLOW_DIRTY_INSTALL=1" in combined
    assert "vouches for whatever is on disk" in combined, (
        "the override is silent about what it gave up, so a green install "
        f"reads the same either way (L98): {combined[-800:]}")


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_a_clean_checkout_says_which_commit_it_vouched_for(tmp_path):
    result = _run_install_with_git(tmp_path, status="", heads=["c0ffee1"],
                                   env_extra={"SKIP_INSTALL_TESTS": "1"})

    assert "c0ffee1" in result.stdout, (
        "a green install names no commit, so nothing says what it green-lit: "
        f"{result.stdout[-800:]}")


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_a_branch_switch_during_the_suite_stops_the_install(tmp_path):
    # The more dangerous half. A red run at least stops; a green one that
    # switched underneath vouches for a commit nobody tested (L179).
    result = _run_install_with_git(tmp_path, status="",
                                   heads=["before111", "after222"],
                                   env_extra={"SKIP_INSTALL_TESTS": "1"})

    combined = result.stdout + result.stderr
    assert result.returncode != 0, "it built against a tree nothing had judged"
    assert "before111" in combined and "after222" in combined, (
        f"it did not say what moved: {combined[-800:]}")
    assert "==> Building" not in combined, (
        "it noticed after building rather than before")


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_a_checkout_that_did_not_move_is_not_refused(tmp_path):
    # The other direction, or every install would be refused and the check
    # would be noise rather than a signal (L36).
    result = _run_install_with_git(tmp_path, status="", heads=["same333"],
                                   env_extra={"SKIP_INSTALL_TESTS": "1"})

    assert "the checkout moved" not in (result.stdout + result.stderr)


@pytest.mark.skipif(not BUILD_INSTALL.exists(), reason="build-install.sh missing")
def test_a_copy_that_is_not_a_checkout_says_it_names_no_commit(tmp_path):
    # An exported copy is a legitimate thing to build from. Saying nothing
    # would make a green install there read exactly like one held to a commit
    # (L98).
    stubs = _stub_dir(tmp_path, xcodebuild_exit=0)
    _write_stub(stubs / "git", 'exit 1\n')
    env = dict(os.environ)
    env["PATH"] = f"{stubs}:{env['PATH']}"
    env["SKIP_INSTALL_TESTS"] = "1"
    env.pop("ALLOW_DIRTY_INSTALL", None)
    result = subprocess.run(["/bin/bash", str(BUILD_INSTALL)],
                            capture_output=True, text=True, env=env, timeout=600)

    assert "names no commit" in result.stdout, result.stdout[-800:]
