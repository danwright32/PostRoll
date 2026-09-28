"""#1458: a render cleans up the half written files dead renders left beside it.

Every reel renderer (and the music download) writes to `<stem>.<pid>.<tag>` and
renames into place, and deletes the temp on an ffmpeg failure. A render that is
cancelled, or whose Python is killed, reaches neither, so the file stayed for
good: one was found on 2026-09-28 in Broadway Undressed's Thursday folder, 1 MB,
from a render cancelled the day before.

The clock and the liveness check are injected, so nothing here waits or depends
on which process ids happen to be running.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import pytest

from postroll import temp_files

NOW = 1_800_000_000.0
DEAD = 999_991
ALIVE = 999_992


def _is_alive(pid: int) -> bool:
    return pid == ALIVE


def _leftover(folder: Path, name: str, age_s: float) -> Path:
    path = folder / name
    path.write_bytes(b"half an encode")
    os.utime(path, (NOW - age_s, NOW - age_s))
    return path


def _temp(output: Path) -> Path:
    return temp_files.temp_sibling(output, "tmp.mp4", now=NOW, is_alive=_is_alive)


def test_the_temp_name_carries_this_process(tmp_path):
    out = tmp_path / "reel_scroll.mp4"
    assert _temp(out) == tmp_path / f"reel_scroll.{os.getpid()}.tmp.mp4"


def test_a_dead_renders_old_leftover_is_removed_and_named(tmp_path, capsys):
    stale = _leftover(tmp_path, f"reel_scroll.{DEAD}.tmp.mp4", age_s=86_400)
    _temp(tmp_path / "reel_scroll.mp4")
    assert not stale.exists()
    assert stale.name in capsys.readouterr().err


def test_a_running_renders_file_is_left_alone(tmp_path):
    live = _leftover(tmp_path, f"reel_scroll.{ALIVE}.tmp.mp4", age_s=86_400)
    _temp(tmp_path / "reel_scroll.mp4")
    assert live.exists()


def test_a_fresh_leftover_is_left_alone(tmp_path):
    """A cancelled render's orphaned ffmpeg can go on writing for seconds after
    its Python has gone, so a file still changing is not yet a leftover."""
    fresh = _leftover(tmp_path, f"reel_scroll.{DEAD}.tmp.mp4", age_s=5)
    _temp(tmp_path / "reel_scroll.mp4")
    assert fresh.exists()


@pytest.mark.parametrize("name", [
    "reel_scroll.mp4",                       # the finished reel itself
    f"reel_slider.{DEAD}.tmp.mp4",           # another template's temp
    f"reel_scroll.{DEAD}.part",              # a different kind of temp
    "reel_scroll.draft.tmp.mp4",             # not a pid
    "notes.txt",
])
def test_nothing_but_this_outputs_own_temps_is_touched(tmp_path, name):
    other = _leftover(tmp_path, name, age_s=86_400)
    _temp(tmp_path / "reel_scroll.mp4")
    assert other.exists()


def test_a_leftover_that_cannot_be_removed_does_not_stop_the_render(tmp_path, capsys):
    # A directory by that name cannot be unlinked, which stands in for any
    # removal that fails: the render goes ahead and the failure is said.
    stuck = tmp_path / f"reel_scroll.{DEAD}.tmp.mp4"
    stuck.mkdir()
    os.utime(stuck, (NOW - 86_400, NOW - 86_400))
    assert _temp(tmp_path / "reel_scroll.mp4").name.endswith(".tmp.mp4")
    assert "could not remove" in capsys.readouterr().err
    assert stuck.exists()


def test_a_missing_folder_is_not_an_error(tmp_path):
    _temp(tmp_path / "not_yet" / "reel_scroll.mp4")


def test_the_real_liveness_check_sees_this_process():
    assert temp_files.pid_is_alive(os.getpid())


def test_no_module_names_a_pid_temp_by_hand():
    """One helper for the whole class (L613): a renderer that builds its own
    `.{os.getpid()}.` name gets no sweep, and its leftovers pile up again."""
    root = Path(__file__).resolve().parent.parent / "postroll"
    pattern = re.compile(r"os\.getpid\(\)\}\.")
    offenders = [
        f"{path.relative_to(root)}"
        for path in root.rglob("*.py")
        if path.name != "temp_files.py" and pattern.search(path.read_text(encoding="utf-8"))
    ]
    assert not offenders, f"these build a pid temp name without the sweep: {offenders}"
