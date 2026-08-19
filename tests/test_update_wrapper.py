"""The updater that outlives the app it updates (#686).

The out of date sheet used to hand Dan a command to copy. Pressing a button
instead means something has to keep running after PostRoll is asked to quit,
because installing over /Applications/PostRoll.app is exactly what
build-install.sh does once the build is green. So the work happens in
`update-postroll.sh`, which PostRoll starts and then stops being able to watch.

Two things follow from that, and they are what this file is about:

* while the app IS alive it has to be able to see progress, so the wrapper
  writes the same step file shape the Python runs write, with a heartbeat that
  moves on every line of output rather than only when a phase changes;
* when the app is NOT alive, a failure has nowhere to be shown, so it is
  written to an outcome file the next launch reads. A failure recorded only on
  a surface that dies with the attempt leaves Dan pressing the same button with
  no way to learn why it did nothing (L148, L164).

The wrapper is run for real here against a stub build-install.sh, because the
paths worth proving are the ones that only happen when something goes wrong.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
WRAPPER = REPO_ROOT / "PostRollApp" / "update-postroll.sh"


# ── the fixture: a fake checkout whose build-install.sh we control ────────────


def make_checkout(tmp_path: Path, script_body: str) -> Path:
    """A directory shaped like the checkout, with a stub build-install.sh.

    Shaped like the real one rather than passed in as a path, so the wrapper's
    own derivation of where build-install.sh lives is under test too. A test
    that hands it the answer proves only that it can be told (L52).
    """
    repo = tmp_path / "checkout"
    (repo / "PostRollApp").mkdir(parents=True)
    script = repo / "PostRollApp" / "build-install.sh"
    script.write_text(script_body)
    script.chmod(0o755)
    return repo


def run_wrapper(repo: Path, tmp_path: Path, *extra: str, env: dict | None = None):
    """Run the wrapper to completion and hand back its three output files."""
    progress = tmp_path / "progress.json"
    outcome = tmp_path / "outcome.json"
    log = tmp_path / "update.log"
    proc = subprocess.run(
        [
            "/bin/bash", str(WRAPPER),
            "--repo", str(repo),
            "--progress", str(progress),
            "--outcome", str(outcome),
            "--log", str(log),
            *extra,
        ],
        capture_output=True,
        text=True,
        timeout=120,
        env={**os.environ, **(env or {})},
    )
    return proc, progress, outcome, log


def read_json(path: Path):
    return json.loads(path.read_text())


# ── it exists and is runnable ────────────────────────────────────────────────


def test_the_wrapper_is_executable():
    """PostRoll runs it through bash, but a script nobody can execute is a
    script somebody has to remember to make executable."""
    assert WRAPPER.exists(), f"{WRAPPER} is missing"
    assert os.access(WRAPPER, os.X_OK), f"{WRAPPER} is not executable"


# ── the happy path ───────────────────────────────────────────────────────────


def test_a_successful_update_records_that_it_succeeded(tmp_path):
    repo = make_checkout(tmp_path, """#!/usr/bin/env bash
echo "==> Running the Swift tests before installing"
echo "==> Building PostRoll (Release)"
echo "==> Installed: /Applications/PostRoll.app"
exit 0
""")
    proc, progress, outcome, log = run_wrapper(repo, tmp_path)

    assert proc.returncode == 0, proc.stderr
    result = read_json(outcome)
    assert result["ok"] is True
    assert result["exit_code"] == 0
    assert "==> Building PostRoll (Release)" in log.read_text()


def test_progress_names_the_phase_the_build_is_in(tmp_path):
    """A spinner that looks the same in every phase is the defect this whole
    sheet exists to avoid. The phase comes from the build script's own markers,
    so the two cannot drift into describing different steps."""
    repo = make_checkout(tmp_path, """#!/usr/bin/env bash
echo "==> Running the Swift tests before installing"
echo "some test output"
echo "==> Building PostRoll (Release)"
sleep 3
exit 0
""")
    progress = tmp_path / "progress.json"
    proc = subprocess.Popen(
        ["/bin/bash", str(WRAPPER), "--repo", str(repo),
         "--progress", str(progress), "--outcome", str(tmp_path / "outcome.json"),
         "--log", str(tmp_path / "update.log")])
    try:
        # Read it WHILE the build is in flight, which is the only moment the
        # answer means anything: by the end every run says the same thing.
        time.sleep(1.0)
        step = read_json(progress)
        assert step["label"] == "Building PostRoll (Release)", (
            "the phase the build last reported is not what the sheet would "
            f"show, so the progress line is stuck on something else: {step}"
        )
    finally:
        proc.wait(timeout=60)


def test_the_heartbeat_moves_while_output_flows(tmp_path):
    """The difference between alive and hung.

    `updated_at` is what LongRunState measures silence against, so it must move
    on every line rather than only when a phase changes: a phase that runs for
    four minutes with output streaming the whole time would otherwise be shown
    as stalled, and a phase that died one second in would look identical to one
    that is working.
    """
    repo = make_checkout(tmp_path, """#!/usr/bin/env bash
echo "==> Building PostRoll (Release)"
sleep 2
echo "still compiling"
sleep 5
exit 0
""")
    progress = tmp_path / "progress.json"
    proc = subprocess.Popen(
        ["/bin/bash", str(WRAPPER), "--repo", str(repo),
         "--progress", str(progress), "--outcome", str(tmp_path / "outcome.json"),
         "--log", str(tmp_path / "update.log")])
    try:
        # Read DURING the phase, not after the run. The write that marks the
        # whole update finished would otherwise answer this, and it moves
        # whether or not anything beat while the build was going: measured, and
        # this assertion passed with the heartbeat deliberately removed until it
        # read the file at this moment instead.
        time.sleep(3.0)
        step = read_json(progress)
    finally:
        proc.wait(timeout=60)

    # The label was written at second zero and the next line landed two seconds
    # later. If the heartbeat only moved on a phase change, the two stamps here
    # would still be the same.
    assert step["updated_at"] >= step["started_at"] + 2, (
        "the heartbeat did not move between the phase starting and the next "
        f"line of its output, so a live build reads as a stalled one: {step}"
    )


# ── the failure paths, which are the point ───────────────────────────────────


def test_a_failed_build_records_the_phase_and_the_exit_code(tmp_path):
    """"Update failed" covers a red test suite, a compile error, a dirty tree
    and a missing toolchain, and is the right next step for none of them."""
    repo = make_checkout(tmp_path, """#!/usr/bin/env bash
echo "==> Running the Swift tests before installing"
echo "PostRollTests.BuildFreshnessTests: XCTAssertEqual failed"
exit 65
""")
    proc, _, outcome, _ = run_wrapper(repo, tmp_path)

    assert proc.returncode != 0
    result = read_json(outcome)
    assert result["ok"] is False
    assert result["exit_code"] == 65
    assert result["phase"] == "Running the Swift tests before installing"
    assert "XCTAssertEqual failed" in result["message"], (
        "the outcome does not carry what the build actually said, so the only "
        f"place the reason exists is a log nobody opens: {result}"
    )


def test_a_missing_build_script_is_reported_rather_than_silently_nothing(tmp_path):
    """The launcher's own failure.

    Failure recording that lives inside the thing being launched cannot record
    a failure to launch it at all, and that reads exactly like the button never
    having been pressed (L164).
    """
    repo = tmp_path / "empty-checkout"
    repo.mkdir()
    proc, _, outcome, _ = run_wrapper(repo, tmp_path)

    assert proc.returncode != 0
    result = read_json(outcome)
    assert result["ok"] is False
    assert "build-install.sh" in result["message"], (
        f"the reason does not name what was missing: {result}"
    )


def test_a_failed_pull_stops_before_building(tmp_path):
    """A pull that failed leaves the checkout on the old code, so building it
    produces another copy missing the same work: the thing the sheet's two
    separate remedies exist to avoid. It must refuse, not carry on."""
    repo = make_checkout(tmp_path, """#!/usr/bin/env bash
echo "the build ran, which it should not have"
exit 0
""")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    git = fake_bin / "git"
    git.write_text("#!/usr/bin/env bash\necho 'error: Your local changes would be overwritten' >&2\nexit 1\n")
    git.chmod(0o755)

    proc, _, outcome, log = run_wrapper(
        repo, tmp_path, "--pull", env={"PATH": f"{fake_bin}:{os.environ['PATH']}"})

    assert proc.returncode != 0
    result = read_json(outcome)
    assert result["ok"] is False
    assert "the build ran" not in log.read_text(), (
        "the build went ahead on a checkout the pull had failed to update"
    )
    assert "local changes" in result["message"], (
        f"the reason the pull failed was not carried through: {result}"
    )


def test_the_pull_only_happens_when_it_was_asked_for(tmp_path):
    """The sheet decides which of the two remedies applies. A wrapper that
    always pulls would make that decision meaningless and would touch a
    checkout Dan deliberately left where it was."""
    repo = make_checkout(tmp_path, "#!/usr/bin/env bash\nexit 0\n")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    marker = tmp_path / "git-ran"
    git = fake_bin / "git"
    git.write_text(f"#!/usr/bin/env bash\ntouch {marker}\nexit 0\n")
    git.chmod(0o755)

    run_wrapper(repo, tmp_path, env={"PATH": f"{fake_bin}:{os.environ['PATH']}"})
    assert not marker.exists(), "the checkout was pulled without being asked"

    run_wrapper(repo, tmp_path, "--pull",
                env={"PATH": f"{fake_bin}:{os.environ['PATH']}"})
    assert marker.exists(), (
        "--pull did nothing, so the remedy for a checkout behind main quietly "
        "became the remedy for one that is not"
    )


def test_a_stale_outcome_is_cleared_before_the_run_starts(tmp_path):
    """An outcome file left by an earlier attempt would be read by the next
    launch as this attempt's, so a failure could be reported for an update that
    has just succeeded (L133)."""
    repo = make_checkout(tmp_path, """#!/usr/bin/env bash
sleep 1
exit 0
""")
    progress = tmp_path / "progress.json"
    outcome = tmp_path / "outcome.json"
    log = tmp_path / "update.log"
    outcome.write_text(json.dumps({"ok": False, "phase": "an older attempt",
                                   "exit_code": 1, "message": "stale",
                                   "finished_at": 1}))

    proc = subprocess.Popen(
        ["/bin/bash", str(WRAPPER), "--repo", str(repo), "--progress", str(progress),
         "--outcome", str(outcome), "--log", str(log)])
    # While the run is in flight there must be no outcome at all: an outcome
    # file and a running update are contradictory states, and the launch check
    # believes the file.
    time.sleep(0.4)
    assert not outcome.exists(), (
        "an earlier attempt's outcome was still on disk while this one ran, so "
        "a finished update would be reported as the failure before it"
    )
    proc.wait(timeout=60)
    assert read_json(outcome)["ok"] is True
