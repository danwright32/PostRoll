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


# ── the workflows collect and publish what the checks measure ─────────────────
#
# Built is not wired (L3). The reporting above is only worth having if the jobs
# that render the reference frames actually collect it and put it somewhere a
# person, or a query, can read.

WORKFLOWS = REPO_ROOT / ".github" / "workflows"

#: The jobs that render the reference frames, and therefore take readings.
COLLECTING = {
    "swift.yml": "reference-frames",
    "tests.yml": "macos",
}


def _job(workflow: str, name: str) -> str:
    import re

    text = (WORKFLOWS / workflow).read_text(encoding="utf-8")
    match = re.search(rf"^  {re.escape(name)}:[ \t]*$(.*?)(?=^  \S|\Z)",
                      text, re.M | re.S)
    assert match, (
        f"there is no `{name}:` job in {workflow} any more, so the check below "
        "is reading nothing at all")
    return match.group(1)


def test_every_rendering_job_collects_the_readings():
    for workflow, name in sorted(COLLECTING.items()):
        body = _job(workflow, name)
        assert LOG_VARIABLE in body, (
            f"{workflow}'s {name} job does not set {LOG_VARIABLE}, so its "
            "reference-frame readings go to the step summary unheaded, or "
            "nowhere at all")


def test_every_rendering_job_publishes_them_even_when_it_fails():
    """A red run is when the numbers are most worth having.

    A publishing step without `if: always()` is skipped on exactly the runs
    whose readings would explain the failure.
    """
    for workflow, name in sorted(COLLECTING.items()):
        body = _job(workflow, name)
        publish = body.split("Publish the reference-frame drift readings", 1)
        assert len(publish) == 2, (
            f"{workflow}'s {name} job collects readings and never publishes "
            "them, so nothing reads the file it writes")
        assert "if: always()" in publish[1].split("run:", 1)[0], (
            f"{workflow}'s {name} job publishes the readings only on a green "
            "run, which drops them exactly when they explain something")


def test_the_readings_reach_the_log_and_not_only_the_summary():
    """Two audiences, and only one of them is a person.

    A step summary is not fetchable through the API, so a summary-only reading
    can be looked at by hand and by nothing else. The log is what any later
    question about what a run measured can actually read.
    """
    for workflow, name in sorted(COLLECTING.items()):
        published = _job(workflow, name).split(
            "Publish the reference-frame drift readings", 1)[1]
        step = published.split("- name:", 1)[0]
        assert "GITHUB_STEP_SUMMARY" in step, workflow
        assert any(line.strip() == 'cat "${POSTROLL_GOLDEN_DRIFT_LOG}"'
                   for line in step.splitlines()), (
            f"{workflow}'s {name} job writes the readings to the step summary "
            "only, so nothing but a person opening the page can ever read them")
