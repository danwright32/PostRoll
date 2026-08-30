"""#787: the reference frames write down what they measured, on every run.

`MAX_CHANGED_FRACTION` was 0.005 and its stated justification was that a moved
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

from ci_workflow import IGNORE_FLAG
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

    written = report("story", 10, 1000, environment={LOG_VARIABLE: str(log)})

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

    assert report("story", 10, 1000, environment={"GITHUB_STEP_SUMMARY": str(summary)}) is None
    assert not summary.exists()


def test_readings_from_several_writers_all_survive(tmp_path):
    """Appended, not written.

    The reference frames are spread over three matrix shards and several xdist
    workers, and there is no moment when one process holds them all. A writer
    that opened for writing would leave whichever reading happened to be last.
    """
    log = tmp_path / "log.txt"
    for name in ("story", "collage", "morph_reel"):
        report(name, 1, 100, environment={LOG_VARIABLE: str(log)})

    assert len(log.read_text(encoding="utf-8").splitlines()) == 3


def test_a_reading_that_could_not_be_written_says_so_rather_than_nothing():
    # "written" and "there was nowhere to write it" are different outcomes, and
    # a caller reading silence as success would report a run that collected
    # nothing as a run in which nothing drifted (L11, L98).
    assert report("story", 1, 100, environment={}) is None


def test_a_reading_says_where_the_changed_pixels_are():
    """A count cannot tell scattered noise from a moved element (#793).

    That is the one thing not established about `clip_reel`, which reads 26
    pixels on the runner while the other nine templates read 0, reproducibly to
    the pixel across two separate runs.
    """
    written = line("clip_reel", 26, 1080 * 1920, box=(100, 200, 130, 220))

    assert "region 30x20 at (100,200)" in written, written


def test_a_tight_box_and_a_spread_one_read_differently():
    """The question the box is being added to answer.

    The same 26 pixels inside a mark and the same 26 dusted over a whole canvas
    are the same count and completely different findings, so the reading has to
    separate them without anybody fetching the frame.
    """
    tight = line("clip_reel", 26, 1080 * 1920, box=(100, 200, 106, 205))
    spread = line("clip_reel", 26, 1080 * 1920, box=(0, 0, 1080, 1920))

    assert "86.7% of it" in tight, tight
    assert "0.0% of it" in spread, spread
    assert tight != spread


def test_a_frame_that_did_not_move_says_so_rather_than_naming_a_corner():
    """None is its own answer.

    `getbbox()` returns None for a mask with nothing set. A box of zeros written
    in its place would read as a real one-pixel region at the top-left corner,
    which is a finding about a frame that did not move at all (L11).
    """
    written = line("story", 0, 1080 * 1920, box=None)

    assert "no changed region" in written, written
    assert "(0,0)" not in written, written


def test_an_environment_passed_positionally_is_refused():
    """`box` and `environment` are keyword only, and that is load bearing.

    `box` was added in front of `environment`, so a caller still passing an
    environment positionally would bind a dict to `box` and write a reading
    about a region nobody measured, with nothing raising (L168). Every caller
    was updated; this is what stops the next one being written that way.
    """
    with pytest.raises(TypeError):
        report("story", 1, 100, {})  # type: ignore[misc]


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
    # A frame that did not move says so, rather than naming the top-left corner.
    assert "no changed region" in written, written


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
    # And where they are: a row of 26 along the top edge, which the box says
    # outright rather than leaving to be guessed from a count (#793).
    assert "region 26x1 at (0,0)" in written, written
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
            runs_pytest = re.search(r"\bpytest\b", body)
            # A job that DESELECTS the reference frames cannot take a reading of
            # them, however much pytest it runs. Since #995 the `macos` leg is
            # exactly that: it runs the suite on a Mac with every
            # reference-frame file ignored, because the shards render them. Left
            # in, it would be required to collect readings it structurally
            # cannot produce, and the check below would be asserting about a job
            # that renders nothing (L144: judge by the same predicate the action
            # used).
            skips_the_frames = IGNORE_FLAG in body
            if runs_on_mac and runs_pytest and not skips_the_frames:
                found[(path.name, name)] = body
    assert found, (
        "no job in .github/workflows runs pytest on macOS, which is not this "
        "repo. The derivation has stopped matching, and every check below would "
        "then pass over an empty set (L98).")
    return found


def test_the_derivation_finds_the_job_that_renders_the_frames():
    """The control for the scan above.

    Named rather than implied, because a derivation that quietly found NOTHING
    would leave every check below passing over an empty set while reporting
    green (L98).

    It used to require TWO jobs, `swift.yml / reference-frames` and
    `tests.yml / macos`, because both rendered the frames. #995 removed that
    duplication: the Mac leg deselects exactly the files the shards render, so
    it takes no readings and is no longer a rendering job. The old assertion is
    replaced rather than widened, because its content was the duplication
    itself (L252).
    """
    found = set(rendering_jobs())

    assert found == {("swift.yml", "reference-frames")}, (
        f"the jobs that render the reference frames are now {sorted(found)}. If "
        "that is a deliberate change, the checks below follow it automatically; "
        "this is here so the change is noticed rather than silent.")


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


# ── the collecting is scoped to the shard that measures ──────────────────────
#
# The reference-frame job is fanned out over three matrix shards and only one of
# them runs the file that takes readings. The other two collected nothing and
# said so on every run: "no reference-frame drift readings were taken, so this
# run measured nothing" (#797, seen on job 96897833537).
#
# That sentence is right when a shard that SHOULD have measured did not, which is
# why it stays. It was wrong here only because two of the three can never take a
# reading, so it was a permanent line rather than news, and a permanent warning
# is one people learn to read past (L36).

import ci_workflow  # noqa: E402
from tools.check_tree_already_checked import ASKS_THE_GATE  # noqa: E402

TESTS_DIR = REPO_ROOT / "tests"

#: The call a comparison makes to write down what it measured.
READING_CALL = re.compile(r"\bgolden_drift\.report\(")

#: What a step's condition may test to work out whether its shard measures.
#:
#: The matrix's FILES, never its name. A condition naming the shard is a second
#: copy of the split: rebalancing the matrix would move the file to another
#: shard and leave the steps behind, collecting on a shard that measures nothing
#: and not on the one that does (L41).
SHARD_FILES = "matrix.shard.files"


def reading_files() -> set[str]:
    """Test files whose comparisons write a drift reading, by bare name.

    Derived from the call rather than named here. A list would be a third place
    the same fact lives, beside the matrix and the workflow condition, and the
    one that gets forgotten (L96).

    Comment lines stripped, because a guard satisfiable by prose about the call
    is indistinguishable from one that works (L103).
    """
    found = set()
    for path in sorted(TESTS_DIR.glob("test_*.py")):
        code = "\n".join(
            line for line in path.read_text(encoding="utf-8").splitlines()
            if not line.strip().startswith("#"))
        if READING_CALL.search(code):
            found.add(path.name)
    assert found, (
        "no test file calls golden_drift.report(), so nothing takes a reading "
        "at all and every check below would pass over an empty set (L98)")
    return found


def measuring_shards() -> list[str]:
    """The matrix shards that actually run a file which takes readings."""
    wanted = reading_files()
    return [name for name, files in ci_workflow.shards()
            if wanted & {Path(path).name for path in files}]


def step_condition(step: str) -> str:
    """One step's `if:` expression, or "" when it has none."""
    body = ci_workflow.job_block().split(step, 1)
    assert len(body) == 2, (
        f"there is no step named {step!r} in the {ci_workflow.JOB} job any "
        "more, so this check is reading nothing")
    before_run = body[1].split("run:", 1)[0]
    match = re.search(r"^\s*if:\s*(.+)$", before_run, re.M)
    return match.group(1).strip() if match else ""


def selected_by(condition: str) -> list[str]:
    """Which shards a condition is true for, evaluated over the real matrix.

    Only the one expression shape is understood, `contains(matrix.shard.files,
    '<path>')`, and anything else raises rather than being read as selecting
    everything. A parser that shrugged at an expression it did not know would
    report a correctly scoped step for a condition that does nothing.
    """
    paths = re.findall(
        rf"contains\(\s*{re.escape(SHARD_FILES)}\s*,\s*'([^']+)'\s*\)", condition)
    assert paths, (
        f"the condition {condition!r} tests no {SHARD_FILES} at all, so nothing "
        "here can say which shards it selects")
    stripped = re.sub(
        rf"contains\(\s*{re.escape(SHARD_FILES)}\s*,\s*'[^']+'\s*\)", "", condition)
    # #990's gate is subtracted by its exact text rather than shrugged at. It
    # says whether this MERGE has anything to do, which is a different question
    # from which SHARD a step belongs to, so it selects nothing here; but a
    # parser that ignored expressions it did not recognise would report a step
    # as correctly scoped whatever else had been bolted onto it.
    leftover = (stripped.replace("always()", "")
                .replace(ASKS_THE_GATE, "")
                .replace("&&", "").strip())
    assert not leftover, (
        f"the condition {condition!r} has a part this cannot evaluate: "
        f"{leftover!r}. Rather than guess, which would report a step as scoped "
        "when it is not, teach this the new shape.")
    return [name for name, files in ci_workflow.shards()
            if all(path in files for path in paths)]


DRIFT_STEPS = ("Collect reference-frame drift readings",
               "Publish the reference-frame drift readings")


def test_exactly_one_shard_takes_the_readings():
    """The premise the scoping rests on.

    Not a fixed number: what matters is that SOME shard measures, so the steps
    have somewhere to belong. If a rebalance ever spread the reading files over
    two shards the condition below has to cover both, and this is what says so
    rather than leaving it to be discovered from an empty summary.
    """
    measuring = measuring_shards()

    assert measuring, (
        f"no shard of the {ci_workflow.JOB} job runs any of {sorted(reading_files())}, "
        "so the readings the limit is chosen from are taken nowhere in CI")
    assert len(measuring) < len(ci_workflow.shards()), (
        "every shard now takes readings, so there is nothing to scope and the "
        "steps below should go back to running unconditionally")


@pytest.mark.parametrize("step", DRIFT_STEPS)
def test_the_drift_steps_run_only_on_the_shard_that_measures(step):
    """Derived from the matrix, not from the shard's name.

    The two shards that can never take a reading announced that they measured
    nothing on every single run. Keeping the sentence and scoping the steps is
    the fix: it is still the right thing to say when a shard that should have
    measured did not.
    """
    condition = step_condition(step)

    assert condition, (
        f"the {step!r} step has no `if:`, so it runs on every shard. Two of "
        "them can never take a reading and would report measuring nothing on "
        "every run (#797).")
    assert "matrix.shard.name" not in condition, (
        f"the {step!r} step selects its shard by NAME: {condition}. A rebalance "
        "that moves the reading file to another shard would leave the step "
        "behind, collecting where nothing measures (L41).")
    assert selected_by(condition) == measuring_shards(), (
        f"the {step!r} step runs on {selected_by(condition)} and the shards that "
        f"take readings are {measuring_shards()}.")


def test_the_publish_step_still_runs_on_a_failed_run():
    """Scoping must not have cost the other condition.

    `always()` is what puts the readings on a RED run, which is when they are
    most worth having. Adding a shard test beside it is the moment that is
    easiest to lose (L173).
    """
    condition = step_condition("Publish the reference-frame drift readings")

    assert "always()" in condition, (
        f"the publish step's condition is {condition!r}, which drops the "
        "readings on exactly the runs that need explaining")


def test_a_shard_that_should_have_measured_and_did_not_still_says_so():
    """The branch this deliberately keeps (L98).

    An empty list published under a heading reads as a run in which nothing
    drifted. The sentence is only noise on a shard that could never measure;
    on the one that runs the comparisons it is the whole point.
    """
    step = ci_workflow.job_block().split(DRIFT_STEPS[1], 1)[1].split("- name:", 1)[0]

    assert "measured nothing" in step, (
        "the publish step no longer says anything when it collected nothing, so "
        "a shard whose comparisons all failed to report is indistinguishable "
        "from one where nothing drifted")


def test_every_rendering_job_records_the_ffmpeg_it_ran_against():
    """The reading and the tool that produced it arrive together (#792).

    `MAX_CHANGED_FRACTION` is 0.0001 since #816, fifty times tighter than the
    0.005 it replaced, and it was chosen from what an unchanged design reads on
    the runner: 26 pixels on `clip_reel` at the worst it has ever read, 0 on
    every frame since #811 dropped the preset that caused it. That share
    exists only because of the runner's ffmpeg, and both jobs pin the runner
    IMAGE, deliberately, since the frames were recorded against its fonts, while
    neither pins ffmpeg: `brew install ffmpeg` takes whatever Homebrew has that
    day.

    So the number the limit rests on can move with nothing in the repo saying
    so. At the old limit there was 385x of headroom and it did not matter; at
    8x, an ffmpeg rendering a couple of hundred pixels differently fails every
    reference frame at once, and the first symptom reads as a design regression
    on ten templates.

    Derived from the same jobs that take the readings, so the two cannot be
    scoped apart. tests.yml has kept this record since #552; swift.yml, which is
    where the reading was actually taken, never did.
    """
    for (workflow, name), body in sorted(rendering_jobs().items()):
        records = [step for step in body.split("- name:")
                   if "ffmpeg -version" in step and "GITHUB_STEP_SUMMARY" in step]
        assert records, (
            f"{workflow}'s {name} job installs its own ffmpeg, takes the "
            "readings MAX_CHANGED_FRACTION is chosen from, and never writes "
            "down which ffmpeg produced them. A run that fails every frame then "
            "cannot be told from a redesign (#792).")


# ── the limit is held to the readings it was chosen from ─────────────────────

from test_golden_frames import (  # noqa: E402
    MAX_CHANGED_FRACTION,
    SMALLEST_REAL_MOVE,
    WORST_UNCHANGED_ON_CI,
)

#: How much clear air the limit needs either side, as a multiplier.
#:
#: Four each way, against real margins of sixteen and eighteen. Deliberately
#: looser than the margins so an ordinary wobble in either reading does not fire
#: this; what it catches is the two closing on each other far enough that the
#: limit stops separating them.
GAP = 4.0


def test_the_version_parser_reads_the_spellings_this_repo_has_actually_seen():
    """The comparison is only as good as what it can read (#792).

    Every string here has been on a runner or a machine in this repo: `8.1` on
    Dan's Mac, `8.1.2_1` from the Homebrew bottle the reading came from,
    `6.1.1-3ubuntu5` on the Linux leg, and ffmpeg's own `n`-prefixed tags. The
    last two are the ones that must answer None rather than a number, because a
    parser that guessed would compare two things it made up.
    """
    from test_golden_frames import ffmpeg_major

    assert ffmpeg_major("8.1") == 8
    assert ffmpeg_major("8.1.2_1") == 8
    assert ffmpeg_major("6.1.1-3ubuntu5") == 6
    assert ffmpeg_major("n7.0") == 7
    assert ffmpeg_major("N-12345-gabc") is None
    assert ffmpeg_major("8") is None, (
        "a bare major with no dot is not a spelling ffmpeg uses, and reading it "
        "as one would accept a truncated or invented version (L108)")


def test_the_noise_anchor_is_a_reading_and_not_a_zero():
    """The control for the check below (#816).

    `WORST_UNCHANGED_ON_CI` is multiplied to produce the floor the limit has to
    clear, and every reading taken since #811 dropped the fast preset is 0: ten
    frames, three jobs, two commits. A zero anchor multiplies to zero, which
    makes the first half of the check below true of ANY limit at all, including
    one under what the runner already produces, while still reading as an
    assertion about the noise (L182).

    So the anchor stays the worst reading there has ever been rather than the
    latest one, and this says out loud that it has to be a reading.
    """
    assert WORST_UNCHANGED_ON_CI > 0, (
        "WORST_UNCHANGED_ON_CI is zero, so the gap below it is zero and the "
        "limit is held to nothing on the noise side. A floor of zero cannot be "
        "multiplied into a limit: it would demand every future encoder agree "
        "with these frames bit for bit, and the first Homebrew bottle revision "
        "that rounded one edge differently would fail all ten at once (L36). "
        "Keep the worst reading an unchanged design has produced on the runner.")


def test_the_limit_sits_between_the_noise_and_the_defect():
    """The whole of #787 in one assertion.

    The limit has to be above what an unchanged design produces, or every
    correct run fails and the check gets switched off (L36). It has to be below
    the smallest change the frames exist to catch, or it passes on exactly that.
    It was not: at 0.005 it sat ABOVE a whole colophon moving 160 pixels.
    """
    assert WORST_UNCHANGED_ON_CI * GAP <= MAX_CHANGED_FRACTION, (
        f"the limit {MAX_CHANGED_FRACTION:.4%} is close to the worst an "
        f"unchanged design has read on the runner, {WORST_UNCHANGED_ON_CI:.4%}, "
        "so correct runs will start failing. Re-measure from a CI run's "
        "published readings and choose the limit again.")
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
    assert WORST_UNCHANGED_ON_CI * GAP * GAP <= SMALLEST_REAL_MOVE, (
        f"an unchanged design has read {WORST_UNCHANGED_ON_CI:.4%} at worst and "
        f"the smallest real change reads {SMALLEST_REAL_MOVE:.4%}. There is no "
        "longer room for a "
        "limit between them, so a share of the canvas has stopped being able to "
        "tell noise from a moved element at all.")


# ── the encoder is named on the frame that failed ────────────────────────────
#
# #792 compares MAJOR versions, which is the wrong granularity (#817). The 26
# pixel drift #811 diagnosed came from ffmpeg 8.1 against 8.1.2_1, so the size
# of upgrade demonstrably able to move these pixels is the size that check
# cannot name. It stays as it is, because a hard failure on any difference fires
# on every Homebrew bottle revision; what is added is a sentence carried by the
# comparison's OWN failure, on the full version string.

from test_golden_frames import MEASURED_AGAINST_FFMPEG, ffmpeg_note  # noqa: E402


def test_the_note_reads_a_patch_level_difference_the_major_check_cannot_see():
    """The whole of #817 in one assertion.

    `8.1` against `8.1.2_1` is the difference that really moved pixels here, and
    it is the one `ffmpeg_major` answers 8 to on both sides. So the note has to
    tell those two apart, and name both.
    """
    note = ffmpeg_note("8.1")

    assert "8.1" in note and MEASURED_AGAINST_FFMPEG in note, note
    assert note != ffmpeg_note(MEASURED_AGAINST_FFMPEG), (
        "a build one patch release away reads the same as the build the limit "
        "was measured against, which is exactly the granularity #817 is about")


def test_a_bottle_revision_apart_is_still_a_difference():
    # The commonest real case: same release, a rebuilt Homebrew bottle. It does
    # not fail anything, and it is named, because it is the cheapest candidate
    # explanation for ten frames failing at once.
    note = ffmpeg_note("8.1.2_2")

    assert "8.1.2_2" in note and MEASURED_AGAINST_FFMPEG in note, note


def test_the_same_build_says_so_rather_than_hedging():
    """The other half, and the one that has to be usable.

    Read on a failed frame, "this is the encoder the limit was measured
    against" is what rules the toolchain out and sends the reader to the
    design instead. A note that hedged both ways would say nothing (L11).
    """
    note = ffmpeg_note(MEASURED_AGAINST_FFMPEG)

    assert MEASURED_AGAINST_FFMPEG in note, note
    assert "does not explain" in note, note


def test_an_unreadable_version_claims_neither():
    # An ffmpeg that will not say what it is has to read as unknown rather than
    # as agreement: an absent answer and a matching one are different situations
    # and only one of them rules the toolchain out (L11).
    note = ffmpeg_note(None)

    assert "does not explain" not in note, note
    assert MEASURED_AGAINST_FFMPEG in note, note


def test_a_failed_frame_carries_the_note(tmp_path, monkeypatch):
    """Built is not wired (L3).

    The note is only worth having inside the failure a person actually reads,
    so the comparison itself has to carry it. Measured against what the function
    says for whatever ffmpeg is on this machine, since the point is that the
    message names the encoder that really did the comparing.
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

    from postroll.media.ffmpeg_check import ffmpeg_versions

    assert ffmpeg_note(ffmpeg_versions().get("ffmpeg")) in str(failure.value), (
        str(failure.value))


# ── the reading says how far the pixels moved, and reads back ────────────────
#
# #818. A count and a box cannot tell a render that moved by codec fidelity from
# one that moved by design, and the tool that decides between them reads the
# readings this module writes rather than measuring them again, so the format
# has to survive the round trip.

from golden_drift import (  # noqa: E402
    Reading,
    median_over_tolerance,
    parse,
    readings,
)


def test_a_reading_says_how_far_the_pixels_moved():
    written = line("clip_reel", 7189, 2073600, (0, 127, 1080, 1903), 7)

    assert "median delta 7" in written, written


def test_a_reading_reads_back_as_the_numbers_it_was_written_from():
    # One module writes the line and parses it, so the two cannot drift apart
    # (L41). Everything the verdict is computed from has to survive: the count,
    # the canvas it is out of, the box, and the amplitude.
    written = line("clip_reel", 7189, 2073600, (0, 127, 1080, 1903), 7)

    read = parse(written)

    assert read == Reading(name="clip_reel", changed=7189, total=2073600,
                           box=(0, 127, 1080, 1903), median_delta=7)
    assert read.fill == pytest.approx(7189 / (1080 * 1776))
    assert read.box_share == pytest.approx((1080 * 1776) / 2073600)


def test_a_reading_taken_before_amplitude_was_written_reads_as_unmeasured():
    # The old format, which is what a log from a run before #818 carries. None
    # rather than zero: nobody measured it, which is not the same as nothing
    # having moved (L11).
    read = parse(line("story", 26, 2073600, (308, 320, 671, 337)))

    assert read is not None and read.median_delta is None, read


def test_a_frame_that_did_not_move_reads_back_with_no_box():
    read = parse(line("story", 0, 2073600, None, None))

    assert read is not None and read.box is None and read.fill == 0.0, read


def test_a_line_that_is_not_a_reading_is_skipped_rather_than_counted(tmp_path):
    # A collected log carries whatever else was appended to it, and a heading or
    # a stray line read as a reading would be a template nobody measured (L11).
    log = tmp_path / "log.txt"
    log.write_text("### ffmpeg on macOS (ARM64), shard goldens\n"
                   + line("story", 0, 2073600, None, 0) + "\n"
                   + "some other output\n", encoding="utf-8")

    assert [r.name for r in readings(log)] == ["story"]


def test_a_log_that_was_never_written_is_no_readings(tmp_path):
    assert readings(tmp_path / "never-written.txt") == []


def test_the_median_is_taken_over_the_changed_pixels_only():
    """The whole canvas is unchanged, so a median over it is zero either way.

    Histogram of a frame where two million pixels match exactly and four moved
    by 40, 60, 80 and 100. The median that describes the change is 60 or 80;
    the median over the frame is 0 whatever happened.
    """
    histogram = [0] * 256
    histogram[0] = 2073596
    for value in (40, 60, 80, 100):
        histogram[value] = 1

    assert median_over_tolerance(histogram, 6) in (60, 80)


def test_nothing_past_the_tolerance_is_not_a_median_of_zero():
    histogram = [0] * 256
    histogram[0] = 2073600

    assert median_over_tolerance(histogram, 6) is None


def test_a_real_comparison_writes_the_amplitude(tmp_path, monkeypatch):
    """Built is not wired (L3).

    The verdict is computed from readings the comparison takes, so a comparison
    that wrote a count and a box and no amplitude would leave the tool with
    nothing to judge on every template.
    """
    log = tmp_path / "log.txt"
    monkeypatch.setenv(LOG_VARIABLE, str(log))
    goldens = tmp_path / "goldens"
    goldens.mkdir()
    monkeypatch.setattr("test_golden_frames.GOLDEN_DIR", goldens)

    reference = Image.new("RGB", (1080, 1920), (250, 248, 245))
    reference.save(goldens / "nudged.png")
    rendered = reference.copy()
    for x in range(26):
        rendered.putpixel((x, 0), (200, 198, 195))

    assert_matches_golden(rendered, "nudged", tmp_path)

    read = parse(log.read_text(encoding="utf-8").strip())
    assert read is not None and read.median_delta == 50, read


# ===================================================================
# The frame a comparison rendered, kept for the tool that may record it
# (#827).
#
# `record_codec_change` used to run each template's reference checks
# twice: once to read what the frames did, and once with the re-record
# flag set to write them. Two full renders of a reel for one decision,
# and the frame it recorded was not the frame it judged, since the second
# run rendered again. Keeping the first one settles both.
# ===================================================================

def test_no_frame_is_kept_when_nothing_asked_for_one(tmp_path, monkeypatch):
    from golden_drift import CANDIDATE_VARIABLE, candidate_for
    monkeypatch.delenv(CANDIDATE_VARIABLE, raising=False)

    assert candidate_for("cover") is None, (
        "an ordinary local run has nowhere to put a frame and must not invent "
        "one, the same reason the readings are opt in")


def test_the_frame_is_kept_where_the_tool_asked_for_it(tmp_path, monkeypatch):
    from golden_drift import CANDIDATE_VARIABLE, candidate_for
    monkeypatch.setenv(CANDIDATE_VARIABLE, str(tmp_path / "kept"))

    assert candidate_for("cover") == tmp_path / "kept" / "cover.png"


def test_a_comparison_keeps_the_bytes_a_re_record_would_have_written(tmp_path, monkeypatch):
    """The property the whole change rests on (#827).

    The tool now RECORDS the kept file rather than rendering the frame a second
    time, so it has to be what the second render would have written. Both go
    through `_write_frame`, and this is what holds them to each other: if the
    two ways of saving a frame ever produce different bytes, the door starts
    recording something subtly unlike what it says it records.

    Against a reference this test writes ITSELF, never a committed one. A
    committed frame was encoded by whichever Pillow and zlib the Mac that
    recorded it had, and PNG encoders are not byte reproducible across builds,
    so comparing against one asserts something that is not true off that
    machine. The property under test is that the two WRITERS agree, which is
    exactly what a locally written reference measures.
    """
    from golden_drift import CANDIDATE_VARIABLE
    from test_golden_frames import _write_frame

    goldens = tmp_path / "goldens"
    monkeypatch.setattr("test_golden_frames.GOLDEN_DIR", goldens)

    frame = Image.new("RGB", (1080, 1920), (250, 248, 245))
    for x in range(600):
        frame.putpixel((x, 3), (20, 18, 16))

    # The re-record path, writing the reference.
    _write_frame(frame, goldens / "kept_pair.png")

    monkeypatch.setenv(CANDIDATE_VARIABLE, str(tmp_path / "kept"))
    assert_matches_golden(frame, "kept_pair", tmp_path)

    kept = tmp_path / "kept" / "kept_pair.png"
    assert kept.is_file(), "the comparison was handed a frame and kept nothing"
    assert kept.read_bytes() == (goldens / "kept_pair.png").read_bytes(), (
        "the frame kept for the codec door is not byte for byte what a "
        "re-record writes, so recording it would record something else")


def test_the_frame_kept_is_the_one_that_was_rendered(tmp_path, monkeypatch):
    """Not merely a frame with the right name (#827).

    The whole value of keeping it is that the tool records what the run
    RENDERED. A frame copied from the committed reference instead would be
    byte-identical to it, so every check comparing the two would agree, the door
    would re-record the same bytes back, and it would then refuse every real
    codec change on the grounds that nothing moved.
    """
    from golden_drift import CANDIDATE_VARIABLE
    from test_golden_frames import _write_frame

    goldens = tmp_path / "goldens"
    monkeypatch.setattr("test_golden_frames.GOLDEN_DIR", goldens)

    reference = Image.new("RGB", (1080, 1920), (250, 248, 245))
    _write_frame(reference, goldens / "moved.png")

    rendered = reference.copy()
    # Few enough to stay well inside MAX_CHANGED_FRACTION, so what this measures
    # is what was kept rather than whether the comparison passed.
    for x in range(26):
        rendered.putpixel((x, 0), (200, 198, 195))

    monkeypatch.setenv(CANDIDATE_VARIABLE, str(tmp_path / "kept"))
    assert_matches_golden(rendered, "moved", tmp_path)

    kept = tmp_path / "kept" / "moved.png"
    assert Image.open(kept).convert("RGB").getpixel((0, 0)) == (200, 198, 195), (
        "the frame kept is not the one the comparison was handed, so the door "
        "would record something nothing measured")
    assert kept.read_bytes() != (goldens / "moved.png").read_bytes()
