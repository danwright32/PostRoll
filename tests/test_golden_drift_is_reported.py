"""#787: the reference frames write down what they measured, on every run.

`MAX_CHANGED_FRACTION` is 0.005 and its stated justification is that a moved
element covers far more of the frame than that. Measured on 2026-08-21, lifting
the plate reels' entire footer colophon 160 pixels moved 7336 pixels, 0.35% of
the canvas, and both reels passed their reference frames unchanged.

Choosing a better number needs the distribution the passing comparisons sit in,
on the runner where the tolerance is actually needed, and nothing was writing
that down. These cover the writing down. The threshold itself is not touched
here: setting it from this Mac, where an unchanged render re-records byte for
byte identically, would be setting it from the machine the question is not about
(L177).

The point of the reporting is that it happens on the PASSING path. A reading
taken only when a check fails says nothing about where the healthy ones sit,
which is the whole distribution.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image

from golden_drift import LOG_VARIABLE, destination, line, report
from test_golden_frames import CHANNEL_TOLERANCE, assert_matches_golden

REPO_ROOT = Path(__file__).resolve().parent.parent


def test_a_reading_carries_the_count_as_well_as_the_share():
    # The share is what the threshold is compared against; the count is what it
    # was derived from. A record of shares alone could not be re-derived if the
    # canvas size ever changed.
    written = line("story", 7336, 1080 * 1920)

    assert "7336" in written
    assert "0.3538%" in written, written
    assert "story" in written


def test_nothing_is_collecting_is_its_own_answer():
    # None rather than a path into the checkout: a file quietly written there is
    # one nobody reads and nobody clears.
    assert destination({}) is None
    assert destination({LOG_VARIABLE: "   "}) is None


def test_the_github_summary_is_used_when_there_is_one(tmp_path):
    summary = tmp_path / "summary.md"

    written = report("story", 10, 1000, {"GITHUB_STEP_SUMMARY": str(summary)})

    assert written is not None
    assert summary.read_text(encoding="utf-8").splitlines() == [written]


def test_the_explicit_log_wins_over_the_summary(tmp_path):
    # So a run can collect readings without writing into a GitHub summary that
    # is there for other reasons.
    log, summary = tmp_path / "log.txt", tmp_path / "summary.md"

    report("story", 10, 1000,
           {LOG_VARIABLE: str(log), "GITHUB_STEP_SUMMARY": str(summary)})

    assert log.exists()
    assert not summary.exists()


def test_readings_from_several_writers_all_survive(tmp_path):
    """Appended, not written.

    The reference frames are spread over three matrix shards and several xdist
    workers, and there is no moment when one process holds them all. A writer
    that opened for writing would leave whichever reading happened to be last.
    """
    log = tmp_path / "log.txt"
    for name in ("story", "collage", "morph_reel"):
        report(name, 1, 100, {LOG_VARIABLE: str(log)})

    assert len(log.read_text(encoding="utf-8").splitlines()) == 3


def test_a_reading_that_could_not_be_written_says_so_rather_than_nothing():
    # "written" and "there was nowhere to write it" are different outcomes, and
    # a caller reading silence as success would report a run that collected
    # nothing as a run in which nothing drifted (L11, L98).
    assert report("story", 1, 100, {}) is None


# ── the comparison itself reports ────────────────────────────────────────────


def test_a_passing_comparison_still_writes_its_reading(tmp_path, monkeypatch):
    """The case the whole issue turns on.

    A frame that passes is a data point about where "unchanged" really sits, and
    it is the only kind of data point a healthy suite produces. Reporting only
    on failure would leave the threshold to be chosen from nothing.
    """
    log = tmp_path / "log.txt"
    monkeypatch.setenv(LOG_VARIABLE, str(log))
    goldens = tmp_path / "goldens"
    goldens.mkdir()
    monkeypatch.setattr("test_golden_frames.GOLDEN_DIR", goldens)

    frame = Image.new("RGB", (40, 30), (250, 248, 245))
    frame.save(goldens / "unmoved.png")

    assert_matches_golden(frame, "unmoved", tmp_path)

    written = log.read_text(encoding="utf-8").strip()
    assert written.startswith("- unmoved:"), written
    assert "0 of 1200 px" in written, written


def test_a_frame_that_moved_a_little_reports_the_share_it_moved(tmp_path,
                                                                monkeypatch):
    """A change under the threshold passes and is still worth writing down.

    This is exactly the shape of the defect #787 was filed about: 0.35% of the
    canvas, under the 0.5% limit, and the entire colophon of a template.
    """
    log = tmp_path / "log.txt"
    monkeypatch.setenv(LOG_VARIABLE, str(log))
    goldens = tmp_path / "goldens"
    goldens.mkdir()
    monkeypatch.setattr("test_golden_frames.GOLDEN_DIR", goldens)

    reference = Image.new("RGB", (40, 30), (250, 248, 245))
    reference.save(goldens / "nudged.png")
    rendered = reference.copy()
    # Four pixels of 1200, a third of a percent, well past the per-channel
    # tolerance so they count as changed rather than as codec noise.
    for x in range(4):
        rendered.putpixel((x, 0), (0, 0, 0))

    assert_matches_golden(rendered, "nudged", tmp_path)

    written = log.read_text(encoding="utf-8").strip()
    assert "4 of 1200 px" in written, written
    assert CHANNEL_TOLERANCE < 255, "the tolerance would count nothing as changed"
