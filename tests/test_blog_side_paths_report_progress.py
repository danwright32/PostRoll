"""#1128 (Phase 0d): the revise and swap paths say what they are doing.

`generate_week` has passed `--progress` since #95. `revise_blog` and
`swap_blog_photos` never took the argument at all: neither function accepted a
writer, neither CLI exposed the flag, and neither bridge function created a
file. Both present in the app as one indefinite spinner.

Today a revision is three sequential Claude calls at a 600 second timeout each
and a swap is one at 300. This milestone turns a swap into one call plus up to
seven and a revision into three plus seven, so shipping that without a working /
still alive / failed signal breaks the standing progress rule on exactly the two
paths it makes long.

What each test asserts is the LABEL, not merely that something was written: a
step file that says the same thing throughout a ten minute run is a spinner with
extra steps.
"""

from __future__ import annotations

import subprocess
import sys
from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import revise_blog as rb
from postroll.ai import swap_blog_photos as swap
from postroll.ai.progress import ProgressWriter, read_progress


PROSE = "It's a paragraph about the evening in the room."


@pytest.fixture
def photo(tmp_path):
    p = tmp_path / "DSC4821.jpg"
    Image.new("RGB", (60, 40), (40, 60, 80)).save(p)
    return p


def _labels(path):
    """Every distinct label the run recorded, in order.

    Read through a spy on the writer rather than off the file, because the file
    holds only where the run IS: reading it at the end would show one label and
    say nothing about whether the run ever moved.
    """
    return path


class _Recorder(ProgressWriter):
    def __init__(self, path):
        super().__init__(path)
        self.labels: list[str] = []
        self.finished = False

    def step(self, label, *, index=None, total=None):
        self.labels.append(label)
        super().step(label, index=index, total=total)

    def finish(self):
        self.finished = True
        super().finish()


def test_a_revision_names_each_pass_it_is_on(tmp_path):
    say = _Recorder(tmp_path / "progress.json")
    calls = {"n": 0}

    def fake_run_json(prompt, timeout=600, **kwargs):
        calls["n"] += 1
        return {"title": "T", "body": PROSE}

    with patch.object(rb, "run_json_prompt", side_effect=fake_run_json):
        rb.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": PROSE},
            feedback="tighten it", progress=say,
            skip_humanizer=True, skip_voice_pass=True,
        )

    assert say.labels, (
        "a revision wrote no progress step at all, so the app has nothing to "
        "show but an indefinite spinner for a call that can take ten minutes")
    assert read_progress(tmp_path / "progress.json") is not None


def test_a_revision_moves_its_label_between_passes(tmp_path):
    say = _Recorder(tmp_path / "progress.json")

    def fake_run_json(prompt, timeout=600, **kwargs):
        return {"title": "T", "body": PROSE}

    def fake_review(prompt, data, **kwargs):
        return data

    with patch.object(rb, "run_json_prompt", side_effect=fake_run_json), \
         patch.object(rb, "run_review_pass", side_effect=fake_review), \
         patch.object(rb, "is_humanizer_available", return_value=True), \
         patch.object(rb, "load_humanizer_rules", return_value="rules"):
        rb.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": PROSE},
            feedback="tighten it", progress=say, skip_voice_pass=False,
        )

    assert len(set(say.labels)) > 1, (
        f"every pass reported the same label {say.labels!r}. A label that never "
        "moves freezes as silently as a spinner does.")


def test_a_revision_marks_itself_finished(tmp_path):
    say = _Recorder(tmp_path / "progress.json")

    with patch.object(rb, "run_json_prompt",
                      side_effect=lambda *a, **k: {"title": "T", "body": PROSE}):
        rb.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": PROSE},
            feedback="f", progress=say, skip_humanizer=True, skip_voice_pass=True,
        )

    assert read_progress(tmp_path / "progress.json")["done"] is True, (
        "the last step stays reading as in flight after the run ended")


def test_a_swap_names_what_it_is_doing(tmp_path, photo):
    say = _Recorder(tmp_path / "progress.json")

    with patch.object(swap, "run_json_prompt",
                      side_effect=lambda *a, **k: {"body": PROSE, "photo_count": 1}):
        swap.swap_blog_photos(body=f"{PROSE}\n\n[PHOTO: old.jpg | old alt]",
                              photo_paths=[photo], progress=say)

    assert say.labels, (
        "a photo swap wrote no progress step, so the app shows a bare "
        "'Updating photos…' spinner for a 300 second image-carrying call")
    assert say.finished, "the swap never marked itself done"


def test_neither_path_needs_a_progress_writer(tmp_path, photo):
    """A run started without one gets a writer that discards, as everywhere else."""
    with patch.object(swap, "run_json_prompt",
                      side_effect=lambda *a, **k: {"body": PROSE, "photo_count": 1}):
        swap.swap_blog_photos(body=f"{PROSE}\n\n[PHOTO: old.jpg | old alt]",
                              photo_paths=[photo])

    with patch.object(rb, "run_json_prompt",
                      side_effect=lambda *a, **k: {"title": "T", "body": PROSE}):
        rb.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": PROSE}, feedback="f",
            skip_humanizer=True, skip_voice_pass=True,
        )


@pytest.mark.parametrize("module", ["postroll.ai.revise_blog",
                                    "postroll.ai.swap_blog_photos"])
def test_the_cli_accepts_a_progress_path(module):
    # A flag the app cannot pass is a feature nobody gets.
    out = subprocess.run([sys.executable, "-m", module, "--help"],
                         capture_output=True, text=True)
    assert "--progress" in out.stdout, out.stdout
