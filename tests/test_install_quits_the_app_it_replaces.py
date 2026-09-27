"""The installer quits the PostRoll it is about to replace, and only that one (#1434).

It used to ask "PostRoll" to quit by name, sleep one second and delete the
bundle whatever had happened. PostRoll's quit guard can answer a quit with its
"still working" sheet, so the app stayed open while its bundle was replaced
underneath it, and a name reaches whichever of the stale copies on this Mac
macOS resolves.

Driven against a stand-in: a copy of `sleep` placed at a bundle's executable
path, so a real process sits at a real path and nothing here touches the
installed app. The quit itself is injected through POSTROLL_QUIT_APP, the one
seam, so each test says what the "app" does when asked to quit.
"""

from __future__ import annotations

import os
import threading
import subprocess
import time
from pathlib import Path

import pytest

from source_text import without_prose

REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER = REPO_ROOT / "PostRollApp" / "quit-running-app.sh"
BUILD_INSTALL = REPO_ROOT / "PostRollApp" / "build-install.sh"


def fake_app(root: Path) -> Path:
    """The executable path of a stand-in app. Nothing is written there.

    The stand-in is the real /bin/sleep started with this path as its argv[0],
    so pgrep sees a process at the path while no binary is copied anywhere.
    Two cheaper stand-ins failed on 2026-09-27: a copy of sleep inside a folder
    named `.app` registered with LaunchServices, and Gatekeeper put "PostRoll is
    damaged and can't be opened" in front of Dan once per test; the same copy
    in a plainly named folder was killed on launch. The helper only compares
    paths and PIDs, so neither a bundle nor a binary buys the test anything.
    """
    return root / "PostRoll.standin" / "Contents" / "MacOS" / "PostRoll"


def start(exe: Path) -> subprocess.Popen:
    process = subprocess.Popen([str(exe), "30"], executable="/bin/sleep")
    # Wait on the condition, not a clock (L290): pgrep sees it once it exists.
    for _ in range(200):
        if subprocess.run(["pgrep", "-f", f"^{exe}( |$)"],
                          capture_output=True).returncode == 0:
            return process
        time.sleep(0.01)
    process.kill()
    raise AssertionError(f"the stand-in at {exe} never appeared")


def quit_script(tmp_path: Path, body: str) -> Path:
    script = tmp_path / "quit.sh"
    script.write_text("#!/bin/bash\n" + body + "\n")
    script.chmod(0o755)
    return script


def run_helper(exe: Path, quit_with: Path, deadline: str = "0.5"):
    env = {**os.environ, "POSTROLL_QUIT_APP": str(quit_with),
           "POSTROLL_QUIT_POLL": "0.02"}
    return subprocess.run(
        ["bash", "-c", f'source "{HELPER}" && quit_running_app "$1" "$2" "$3"',
         "quit", str(exe), str(exe.parents[2]), deadline],
        capture_output=True, text=True, env=env, timeout=30)


@pytest.fixture
def processes():
    started: list[subprocess.Popen] = []
    yield started
    for process in started:
        if process.poll() is None:
            process.kill()
            process.wait()


def test_an_app_that_will_not_quit_stops_the_install(tmp_path, processes):
    # The "still working" sheet: the quit is asked for and the app stays.
    exe = fake_app(tmp_path)
    app = start(exe)
    processes.append(app)
    marker = tmp_path / "asked"

    result = run_helper(exe, quit_script(tmp_path, f'touch "{marker}"'))

    assert marker.exists(), "the app was never asked to quit"
    assert result.returncode != 0, "the install went on with the app still open"
    assert app.poll() is None
    assert "Quit Anyway" in result.stderr, (
        "the refusal does not say what to press: " + result.stderr)
    assert "Nothing was installed" in result.stderr, result.stderr


def test_an_app_that_quits_lets_the_install_go_on(tmp_path, processes):
    exe = fake_app(tmp_path)
    app = start(exe)
    processes.append(app)

    # Reaped as soon as it dies. The stand-in is this test's child, so once
    # killed it lingers as a zombie that `kill -0` still answers for; the real
    # app is nobody's child here and is reaped by launchd.
    threading.Thread(target=app.wait, daemon=True).start()

    result = run_helper(exe, quit_script(tmp_path, f"kill {app.pid}"), deadline="10")

    assert result.returncode == 0, result.stderr
    app.wait(timeout=5)
    assert app.poll() is not None


def test_nothing_running_asks_nothing(tmp_path):
    exe = fake_app(tmp_path)
    marker = tmp_path / "asked"

    result = run_helper(exe, quit_script(tmp_path, f'touch "{marker}"'))

    assert result.returncode == 0, result.stderr
    assert not marker.exists(), "a quit was sent with nothing running"


def test_a_copy_at_another_path_is_left_alone(tmp_path, processes):
    # Same process name, different bundle: a Debug build in a build folder.
    # Found by its executable path, so it is neither asked to quit nor waited on.
    target = fake_app(tmp_path / "installed")
    other = fake_app(tmp_path / "debug-build")
    stranger = start(other)
    processes.append(stranger)
    marker = tmp_path / "asked"

    result = run_helper(target, quit_script(tmp_path, f'touch "{marker}"'))

    assert result.returncode == 0, result.stderr
    assert not marker.exists(), "the other copy was taken for the one being replaced"
    assert stranger.poll() is None


def test_the_installer_quits_through_the_helper():
    # Built is not wired (L3): the real script has to use it, and the name based
    # quit with its fixed sleep has to be gone.
    # Comments blanked, so a line ABOUT the old quit cannot answer the check.
    source = without_prose(BUILD_INSTALL)
    assert 'quit_running_app "${DEST}/Contents/MacOS/PostRoll"' in source
    assert 'tell application "PostRoll" to quit' not in source
    assert 'pgrep -xq "PostRoll"' not in source
