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

import re
from pathlib import Path

import pytest
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


def test_the_one_variable_asked_for_is_where_readings_go(tmp_path):
    log = tmp_path / "log.txt"

    written = report("story", 10, 1000, {LOG_VARIABLE: str(log)})

    assert written is not None
    assert log.read_text(encoding="utf-8").splitlines() == [written]


def test_a_step_summary_alone_collects_nothing(tmp_path):
    """Collecting is opt in, and this is the trap it is opt in to avoid.

    GITHUB_STEP_SUMMARY is set on EVERY GitHub runner, including the guard-proof
    job, which runs pytest against a tree it has deliberately broken. Falling
    back to it would write readings of a template that is meant to be wrong onto
    that job's summary with nothing saying so, and a measurement that can be
    taken by accident ends up in a distribution nobody chose.
    """
    summary = tmp_path / "summary.md"

    assert report("story", 10, 1000, {"GITHUB_STEP_SUMMARY": str(summary)}) is None
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
    """A change UNDER the limit passes and is still worth writing down.

    This is the reading that matters most and the one nothing was taking: a
    healthy run produces only these, so a threshold can only be chosen from
    them.

    Full canvas rather than a token one, because the limit is now small enough
    that no change at all fits under it on a 40 by 30 image: 26 pixels is what
    the CI runner really produces on the noisiest template, and this sits in the
    same territory.
    """
    log = tmp_path / "log.txt"
    monkeypatch.setenv(LOG_VARIABLE, str(log))
    goldens = tmp_path / "goldens"
    goldens.mkdir()
    monkeypatch.setattr("test_golden_frames.GOLDEN_DIR", goldens)

    reference = Image.new("RGB", (1080, 1920), (250, 248, 245))
    reference.save(goldens / "nudged.png")
    rendered = reference.copy()
    # Twenty-six pixels, which is exactly what clip_reel reads on the runner,
    # and well past the per-channel tolerance so they count as changed rather
    # than as codec noise.
    for x in range(26):
        rendered.putpixel((x, 0), (0, 0, 0))

    assert_matches_golden(rendered, "nudged", tmp_path)

    written = log.read_text(encoding="utf-8").strip()
    assert "26 of 2073600 px" in written, written
    assert CHANNEL_TOLERANCE < 255, "the tolerance would count nothing as changed"


def test_a_frame_that_moved_an_element_now_fails(tmp_path, monkeypatch):
    """The defect #787 was filed about, at the size it really was.

    7336 pixels is a whole footer colophon moving 160 pixels up the frame. Under
    the old limit this passed. It has to fail, or the limit was not fixed.
    """
    monkeypatch.setenv(LOG_VARIABLE, str(tmp_path / "log.txt"))
    goldens = tmp_path / "goldens"
    goldens.mkdir()
    monkeypatch.setattr("test_golden_frames.GOLDEN_DIR", goldens)

    reference = Image.new("RGB", (1080, 1920), (250, 248, 245))
    reference.save(goldens / "moved.png")
    rendered = reference.copy()
    for i in range(7336):
        rendered.putpixel((i % 1080, i // 1080), (0, 0, 0))

    with pytest.raises(BaseException) as failure:
        assert_matches_golden(rendered, "moved", tmp_path)

    assert "0.35%" in str(failure.value), str(failure.value)


# ── the workflows collect and publish what the checks measure ─────────────────
#
# Built is not wired (L3). The reporting above is only worth having if the jobs
# that render the reference frames actually collect it and put it somewhere a
# person, or a query, can read.

WORKFLOWS = REPO_ROOT / ".github" / "workflows"


def rendering_jobs() -> dict[tuple[str, str], str]:
    """Every CI job that could take a reference-frame reading, and its body.

    DERIVED, not listed. A hand-kept pair of job names checks only what it
    names, so a third job added next year would be exempt from the very check
    meant to catch it (L96). The property is what actually decides it: the
    reference frames render with the macOS system faces and skip everywhere
    else, so a job that could take a reading is one that runs on macOS AND
    invokes pytest.

    That deliberately excludes `guards.yml`, whose macOS jobs reach pytest
    through `tools/check_guards.py` against a tree they have broken on purpose.
    Readings there would be of a template meant to be wrong.
    """
    found = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        settings = "\n".join(
            line for line in path.read_text(encoding="utf-8").splitlines()
            if not line.strip().startswith("#"))
        for match in re.finditer(r"^  ([a-z0-9-]+):[ \t]*$(.*?)(?=^  \S|\Z)",
                                 settings, re.M | re.S):
            name, body = match.group(1), match.group(2)
            runs_on_mac = re.search(r"runs-on:\s*macos", body)
            runs_pytest = (re.search(r"^\s+run:.*\bpytest\b", body, re.M)
                           or re.search(r"run: >\s*\n\s*pytest", body))
            if runs_on_mac and runs_pytest:
                found[(path.name, name)] = body
    assert found, (
        "no job in .github/workflows runs pytest on macOS, which is not this "
        "repo. The derivation has stopped matching, and every check below would "
        "then pass over an empty set (L98).")
    return found


def test_the_derivation_finds_both_jobs_that_render_the_frames():
    """The control for the scan above.

    Named rather than implied, because the two it has to find are the two the
    reference frames actually run in, and a derivation that quietly found only
    one would leave the other unchecked while reporting green.
    """
    found = set(rendering_jobs())

    assert found == {("swift.yml", "reference-frames"), ("tests.yml", "macos")}, (
        f"the jobs that run pytest on macOS are now {sorted(found)}. If that is "
        "a deliberate change, the checks below follow it automatically; this is "
        "here so the change is noticed rather than silent.")


def test_every_rendering_job_collects_the_readings():
    """It has to SET the variable, not merely mention it.

    Matching the name anywhere in the job is satisfied by the publishing step,
    which reads it: the job would then take no readings at all while this
    reported that it collects them. A check over a whole body is answered by any
    occurrence in it (L135), so this looks for an assignment.
    """
    for (workflow, name), body in sorted(rendering_jobs().items()):
        sets_it = re.search(rf"^\s*run:.*{re.escape(LOG_VARIABLE)}=\S", body, re.M)
        assert sets_it, (
            f"{workflow}'s {name} job runs the reference frames on macOS and "
            f"never sets {LOG_VARIABLE} to anything, so it takes no readings at "
            "all and its share of the distribution is simply missing")


def test_every_rendering_job_publishes_them_even_when_it_fails():
    """A red run is when the numbers are most worth having.

    A publishing step without `if: always()` is skipped on exactly the runs
    whose readings would explain the failure.
    """
    for (workflow, name), body in sorted(rendering_jobs().items()):
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
    for (workflow, name), body in sorted(rendering_jobs().items()):
        step = body.split("Publish the reference-frame drift readings",
                          1)[1].split("- name:", 1)[0]
        assert "GITHUB_STEP_SUMMARY" in step, workflow
        assert any(line.strip() == 'cat "${POSTROLL_GOLDEN_DRIFT_LOG}"'
                   for line in step.splitlines()), (
            f"{workflow}'s {name} job writes the readings to the step summary "
            "only, so nothing but a person opening the page can ever read them")


# ── the limit is held to the readings it was chosen from ─────────────────────

from test_golden_frames import (  # noqa: E402
    MAX_CHANGED_FRACTION,
    SMALLEST_REAL_MOVE,
    UNCHANGED_ON_CI,
)

#: How much clear air the limit needs either side, as a multiplier.
#:
#: Four each way, against real margins of sixteen and eighteen. Deliberately
#: looser than the margins so an ordinary wobble in either reading does not fire
#: this; what it catches is the two closing on each other far enough that the
#: limit stops separating them.
GAP = 4.0


def test_the_limit_sits_between_the_noise_and_the_defect():
    """The whole of #787 in one assertion.

    The limit has to be above what an unchanged design produces, or every
    correct run fails and the check gets switched off (L36). It has to be below
    the smallest change the frames exist to catch, or it passes on exactly that.
    It was not: at 0.005 it sat ABOVE a whole colophon moving 160 pixels.
    """
    assert UNCHANGED_ON_CI * GAP <= MAX_CHANGED_FRACTION, (
        f"the limit {MAX_CHANGED_FRACTION:.4%} is close to what an unchanged "
        f"design already reads on the runner, {UNCHANGED_ON_CI:.4%}, so correct "
        "runs will start failing. Re-measure from a CI run's published readings "
        "and choose the limit again.")
    assert MAX_CHANGED_FRACTION * GAP <= SMALLEST_REAL_MOVE, (
        f"the limit {MAX_CHANGED_FRACTION:.4%} is close to the smallest real "
        f"change there is a reading for, {SMALLEST_REAL_MOVE:.4%}, so the "
        "reference frames are back to passing on a moved element. That is #787.")


def test_the_two_readings_are_far_enough_apart_to_put_a_limit_between():
    """The control for the check above.

    A limit can only separate them while they ARE separated. If a future
    template's encode became as noisy as a real layout change, no threshold over
    the whole canvas would work and the check would need a different shape
    entirely, which is a decision rather than a number.
    """
    assert UNCHANGED_ON_CI * GAP * GAP <= SMALLEST_REAL_MOVE, (
        f"an unchanged design reads {UNCHANGED_ON_CI:.4%} and the smallest real "
        f"change reads {SMALLEST_REAL_MOVE:.4%}. There is no longer room for a "
        "limit between them, so a share of the canvas has stopped being able to "
        "tell noise from a moved element at all.")
