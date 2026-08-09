"""#96 and #95: a long run has to prove it is still alive.

Blog generation fires five to ten sequential Claude calls, each up to a ten
minute timeout. Between them the process says nothing, so the UI showed one
spinner that looked identical whether the run was progressing, hung, or dead.
An indefinite spinner is not a progress indicator, it is a shape.

The writer here is what makes the difference visible: each pass records what it
is doing and when it said so, and the app reads that file. "When" is the part
that separates alive from hung, because a step label alone freezes just as
silently as a spinner does.
"""

from __future__ import annotations

import json

import pytest

from postroll.ai.progress import ProgressWriter, read_progress


def test_a_step_is_readable_as_soon_as_it_is_written(tmp_path):
    path = tmp_path / "progress.json"
    writer = ProgressWriter(path)

    writer.step("Sunday caption", index=1, total=7)

    doc = read_progress(path)
    assert doc["label"] == "Sunday caption"
    assert doc["index"] == 1
    assert doc["total"] == 7


def test_each_step_replaces_the_last(tmp_path):
    # The file is "where the run is now", not a log. A reader that had to parse
    # a growing file would be doing the log-tailing this exists to avoid.
    path = tmp_path / "progress.json"
    writer = ProgressWriter(path)

    writer.step("Sunday caption", index=1, total=7)
    writer.step("Blog pass 2 of 4", index=5, total=7)

    assert read_progress(path)["label"] == "Blog pass 2 of 4"


def test_every_step_carries_the_time_it_was_written(tmp_path):
    # A label with no timestamp cannot tell alive from hung: it sits there
    # reading "Blog pass 2" whether the pass is running or the process died
    # during it.
    path = tmp_path / "progress.json"
    writer = ProgressWriter(path)

    writer.step("Blog pass 2 of 4")

    assert read_progress(path)["updated_at"], "a step with no time proves nothing"


def test_the_timestamp_advances_between_steps(tmp_path):
    path = tmp_path / "progress.json"
    writer = ProgressWriter(path)

    writer.step("first")
    first = read_progress(path)["updated_at"]
    writer.step("second")
    second = read_progress(path)["updated_at"]

    assert second >= first


def test_a_missing_file_reads_as_nothing_rather_than_raising(tmp_path):
    # The app reads this on a timer, including before the run has written
    # anything. A missing file is "no progress yet", not a failure.
    assert read_progress(tmp_path / "never-written.json") is None


def test_a_half_written_file_is_never_returned(tmp_path):
    # The reader polls while the writer is writing. A torn read must not
    # surface as a step, or the UI shows garbage for a frame.
    path = tmp_path / "progress.json"
    path.write_text('{"label": "Blog pa')

    assert read_progress(path) is None


def test_writing_is_atomic_so_a_reader_never_sees_a_partial_file(tmp_path):
    # Written to a temp file and renamed, so a concurrent reader gets either
    # the old step or the new one, never a fragment of either.
    path = tmp_path / "progress.json"
    writer = ProgressWriter(path)
    writer.step("first step")

    for i in range(50):
        writer.step(f"step {i}")
        doc = read_progress(path)
        assert doc is not None, "a reader must never catch the file mid-write"
        assert doc["label"] == f"step {i}"


def test_a_writer_with_no_path_is_a_no_op(tmp_path):
    # The CLI can be run without --progress, and every generator calls the
    # writer unconditionally. It must not have to check first.
    writer = ProgressWriter(None)

    writer.step("Sunday caption")  # must not raise


def test_a_write_failure_never_kills_the_run(tmp_path):
    # Progress reporting is decoration around work that costs real money. A
    # run must not die because it could not write a status file.
    # Parent is a regular file, so the directory can never be created and the
    # write cannot succeed however it is attempted.
    blocker = tmp_path / "blocker"
    blocker.write_text("not a directory")
    unwritable = blocker / "progress.json"
    writer = ProgressWriter(unwritable)

    writer.step("Sunday caption")  # must not raise

    assert read_progress(unwritable) is None


def test_the_finished_marker_says_the_run_is_over(tmp_path):
    # Without this the last step sits on screen looking in flight forever.
    path = tmp_path / "progress.json"
    writer = ProgressWriter(path)
    writer.step("Blog pass 4 of 4")

    writer.finish()

    assert read_progress(path)["done"] is True


def test_a_step_is_not_marked_done(tmp_path):
    path = tmp_path / "progress.json"
    writer = ProgressWriter(path)

    writer.step("Blog pass 1 of 4")

    assert read_progress(path).get("done") is not True


# ── the generators actually report ────────────────────────────────────────────

def test_generate_week_names_the_day_it_is_working_on(tmp_path):
    # Built is not wired. The writer above is worth nothing unless the run
    # calls it, and the whole point is that the silence between days ends.
    from unittest.mock import patch

    from postroll.ai import generate_week as gw

    photo = tmp_path / "a.jpg"
    from PIL import Image
    Image.new("RGB", (120, 90), (40, 60, 80)).save(photo)

    manifest = {
        "event": "E", "org": "O", "venue": "V", "date": "2026-04-05",
        "days": {"sunday": {"photos": [str(photo)]}},
        "program": {"performers": [], "pieces": []},
    }
    seen: list[str] = []
    progress = tmp_path / "progress.json"

    def fake_caption(**kw):
        # Read the file the way the app does, mid-run, while a day is in flight.
        doc = read_progress(progress)
        if doc:
            seen.append(doc["label"])
        return {"caption": "c", "hashtags": [], "alt_texts": ["a"],
                "scene_labels": [None], "skipped_photos": []}

    with patch("postroll.ai.generate_week.generate_caption", side_effect=fake_caption):
        gw.generate_week(manifest, tmp_path / "out.json", None, progress)

    assert any("Sunday" in label for label in seen), (
        f"the run must name the day it is on while working: {seen}")


def test_generate_week_marks_itself_finished(tmp_path):
    # Otherwise the last step sits on screen looking in flight forever.
    from unittest.mock import patch

    from postroll.ai import generate_week as gw

    manifest = {"event": "E", "org": "O", "venue": "V", "date": "2026-04-05",
                "days": {}, "program": {}}
    progress = tmp_path / "progress.json"

    gw.generate_week(manifest, tmp_path / "out.json", None, progress)

    assert read_progress(progress)["done"] is True


def test_a_run_without_a_progress_path_still_works(tmp_path):
    # The CLI and every existing caller omit it.
    from postroll.ai import generate_week as gw

    manifest = {"event": "E", "org": "O", "venue": "V", "date": "2026-04-05",
                "days": {}, "program": {}}

    gw.generate_week(manifest, tmp_path / "out.json")  # must not raise
