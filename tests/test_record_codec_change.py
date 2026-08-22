"""#818: the third door only opens on evidence, and never touches a version.

`tools/record_codec_change.py` re-records the reference frames of a template
whose render moved while its design stood still, which is what #811 was and
what neither existing door could take. The whole value of it is the refusals:
a door that re-recorded whatever was handed to it would be the hand written
re-record wearing a tool's name, which is the thing the fingerprint guard exists
to prevent.

So each refusal has a test that PRODUCES it (L151), driven against a throwaway
git repo and a fake reference run, so nothing here renders a reel or touches the
checkout (L2). The fake writes REAL junit XML and REAL reading lines, through
`golden_drift.line` itself rather than a second spelling of the format (L41).

The property underneath them all has its own check: nothing in this tool writes
a design version, because a version bump is what badges every cached asset of a
template as out of date, and doing that for a change nobody can see is the false
alarm the third door exists to avoid (L36).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import golden_drift
from postroll.media import design_tokens as tokens
from test_record_design_fingerprints import build_tree, git, move_fingerprint
from tools.record_codec_change import record
from tools.record_design_fingerprints import GOLDEN_DIR, RECORD_PATH, REFERENCE_TESTS

#: The template every case here moves. It is the template #818 was filed about,
#: and since #825 it carries TWO reference frames: the reel with its title card
#: and the reel as render_clip_reel hands it over, which is what ships whenever
#: the card is muted or fails.
TEMPLATE = "reel_clip"
NODES = REFERENCE_TESTS[TEMPLATE]
GOLDEN = "clip_reel"
DELIVERED_GOLDEN = "clip_reel_delivered"
GOLDENS = (GOLDEN, DELIVERED_GOLDEN)


#: Measured on this Mac on 2026-08-22 by taking `-preset veryfast` off the clip
#: reel's intermediate encodes and diffing against the committed frame. The
#: shape a codec change really has, rather than one invented to pass (L48).
def _codec(name: str) -> str:
    return golden_drift.line(name, 7189, 2073600, (0, 127, 1080, 1903), 7)


#: The story's wordmark moved one pixel, measured the same day. A design change
#: whose count is in the same territory, which is the point: the count cannot
#: tell them apart and the shape can.
def _design(name: str) -> str:
    return golden_drift.line(name, 4624, 2073600, (266, 1654, 814, 1744), 65)


def _unchanged(name: str) -> str:
    return golden_drift.line(name, 0, 2073600, None, None)


CODEC_READING = _codec(GOLDEN)
DESIGN_READING = _design(GOLDEN)
UNCHANGED_READING = _unchanged(GOLDEN)

#: One reading per frame, which is what a real run of this template now writes,
#: and what the tool refuses a run for producing fewer of.
#:
#: The second frame carries the SAME measured numbers under the other name. What
#: these cases turn on is how many readings arrived and what SHAPE each one has,
#: and a second set of numbers nobody measured would be a fixture shaped to make
#: the rule fire (L48). The real reading for that frame is whatever the encoder
#: does to it, which is the same encoder.
CODEC_READINGS = tuple(_codec(name) for name in GOLDENS)
DESIGN_READINGS = tuple(_design(name) for name in GOLDENS)
UNCHANGED_READINGS = tuple(_unchanged(name) for name in GOLDENS)


def _case(node_id: str, outcome: str) -> str:
    path, _, name = node_id.partition("::")
    classname = path[: -len(".py")].replace("/", ".")
    body = {
        "passed": "",
        "skipped": '<skipped type="pytest.skip" message="no fonts">skipped</skipped>',
        "failed": '<failure message="assert False">assert False</failure>',
    }[outcome]
    inner = f">{body}</testcase>" if body else " />"
    return f'<testcase classname="{classname}" name="{name}"{inner}'


#: What the measuring run leaves behind for a frame it rendered, standing in for
#: the PNG a real comparison keeps.
KEPT_BYTES = b"the frame this run rendered and measured"


class FakeRun:
    """A stand-in for the reference run, with a recorded verdict and readings.

    One mode, because the tool runs the checks ONCE (#827). A real comparison
    keeps the frame it rendered where `POSTROLL_GOLDEN_CANDIDATES` points, and
    the tool records that file rather than rendering the template again, so this
    writes a stand-in frame there for every name it claims to have kept.
    """

    def __init__(self, *, outcomes: dict[str, str] | None = None,
                 readings: tuple[str, ...] = CODEC_READINGS,
                 omit: tuple[str, ...] = (), report: bool = True,
                 returncode: int = 1, output: str = "one frame moved",
                 keeps: tuple[str, ...] = GOLDENS,
                 kept_bytes: bytes = KEPT_BYTES) -> None:
        self.outcomes = outcomes or {node: "failed" for node in NODES}
        self.readings = readings
        self.omit = omit
        self.report = report
        self.returncode = returncode
        self.output = output
        self.keeps = keeps
        self.kept_bytes = kept_bytes
        self.calls: list[tuple[tuple[str, ...], dict[str, str]]] = []

    def __call__(self, node_ids, report_path: Path, drift_path: Path, env,
                 repo_root: Path) -> tuple[int, str]:
        self.calls.append((tuple(node_ids), dict(env)))
        if self.report:
            cases = "".join(_case(node, self.outcomes.get(node, "failed"))
                            for node in node_ids if node not in self.omit)
            report_path.write_text(
                f'<?xml version="1.0" encoding="utf-8"?><testsuites name="pytest tests">'
                f'<testsuite name="pytest">{cases}</testsuite></testsuites>',
                encoding="utf-8")
        if self.readings:
            drift_path.write_text("\n".join(self.readings) + "\n", encoding="utf-8")
        kept = env.get(golden_drift.CANDIDATE_VARIABLE)
        if kept:
            Path(kept).mkdir(parents=True, exist_ok=True)
            for name in self.keeps:
                (Path(kept) / f"{name}.png").write_bytes(self.kept_bytes)
        return self.returncode, self.output

    @property
    def rerecorded(self) -> bool:
        """Whether any reference frame in the repo was written."""
        return any(env.get("POSTROLL_UPDATE_GOLDENS") for _, env in self.calls)


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """The media tree, its fingerprint record and stand-in reference frames."""
    build_tree(tmp_path)
    for name in ("clip_reel", "clip_reel_delivered", "cover", "reel_preview",
                 "morph_reel_closing", "slider_reel_closing"):
        (tmp_path / GOLDEN_DIR / f"{name}.png").write_bytes(b"reference frame")
    git(tmp_path, "init", "-q")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-qm", "the state everything here starts from")
    return tmp_path


def run(repo: Path, runner: FakeRun, **env) -> tuple[int, str]:
    log: list[str] = []
    code = record(repo, runner=runner, env=env, log=log.append)
    return code, "\n".join(log)


def move_the_clip_reel(repo: Path) -> None:
    move_fingerprint(repo, "render_clip_reel.py")


def goldens_untouched(repo: Path) -> bool:
    """Whether every reference frame in the repo is still what it was.

    What "re-recorded" means moved with #827: the frames are written by the TOOL
    copying what the measuring run kept, not by a second pytest run setting a
    flag. A refusal check that still asked the runner would be asking something
    that can no longer happen, and would pass in a fixture where it could not
    fail (L159).
    """
    return all((repo / GOLDEN_DIR / f"{name}.png").read_bytes() == b"reference frame"
               for name in GOLDENS)


def versions_in(repo: Path) -> dict:
    return {name: entry["version"] for name, entry
            in json.loads((repo / RECORD_PATH).read_text(encoding="utf-8")).items()}


# ── the door opens ───────────────────────────────────────────────────────────


def test_a_render_that_moved_by_the_encoder_gets_its_frame_re_recorded(repo):
    move_the_clip_reel(repo)
    runner = FakeRun()

    code, said = run(repo, runner)

    assert code == 0, said
    assert not goldens_untouched(repo), said
    # BOTH of this template's frames, named (#825). A codec change moves the
    # delivered reel and the titled one, since the second is an encode of the
    # first, and a door that re-recorded one of them would leave the template
    # half recorded and failing for the frame it skipped.
    assert f"{GOLDEN}.png" in said, said
    assert f"{DELIVERED_GOLDEN}.png" in said, said
    assert "LOOK at those frames" in said, said


def test_the_evidence_is_shown_rather_than_a_verdict_alone(repo):
    # The person is being asked to look at two frames and agree they are the
    # same. A tool that said only "allowed" would be asking them to trust it.
    move_the_clip_reel(repo)

    code, said = run(repo, FakeRun())

    assert code == 0, said
    assert "7189 of 2073600 px" in said, said
    assert "median delta 7" in said, said


def test_no_design_version_is_touched(repo):
    """The whole point of the third door (#818).

    A bump tells the app every cached asset of that template is out of date. If
    this door moved a version it would be the second door with extra steps.
    """
    move_the_clip_reel(repo)
    before = dict(tokens.MEDIA_DESIGN_VERSIONS)

    code, said = run(repo, FakeRun())

    assert code == 0, said
    assert dict(tokens.MEDIA_DESIGN_VERSIONS) == before
    assert versions_in(repo) == {name: before[name] for name in versions_in(repo)}


def test_the_fingerprint_record_is_left_for_the_other_tool(repo):
    # This re-records frames and stops. The fingerprint is recorded afterwards
    # by `make record-fingerprints`, which will only do it once the frames are
    # committed and passing, and that ordering is the guard that makes the whole
    # sequence mean anything.
    move_the_clip_reel(repo)
    before = (repo / RECORD_PATH).read_text(encoding="utf-8")

    code, said = run(repo, FakeRun())

    assert code == 0, said
    assert (repo / RECORD_PATH).read_text(encoding="utf-8") == before
    assert "record-fingerprints" in said, said


# ── the door stays shut ──────────────────────────────────────────────────────


def test_a_tree_where_nothing_moved_is_refused(repo):
    runner = FakeRun()

    code, said = run(repo, runner)

    assert code == 1
    assert "Nothing to record" in said, said
    assert not runner.calls, "it rendered before checking there was anything to do"


def test_a_bumped_version_is_sent_to_the_other_door(repo):
    move_the_clip_reel(repo)
    record_file = repo / RECORD_PATH
    existing = json.loads(record_file.read_text(encoding="utf-8"))
    existing[TEMPLATE]["version"] = tokens.MEDIA_DESIGN_VERSIONS[TEMPLATE] - 1
    record_file.write_text(json.dumps(existing, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
    runner = FakeRun()

    code, said = run(repo, runner)

    assert code == 1
    assert "record-design-change" in said, said
    assert goldens_untouched(repo), said


def test_the_re_record_flag_being_set_already_is_refused(repo):
    # It would make the measuring run re-record and skip, so the readings this
    # decides on would be of a run that measured nothing (L98).
    move_the_clip_reel(repo)
    runner = FakeRun()

    code, said = run(repo, runner, POSTROLL_UPDATE_GOLDENS="1")

    assert code == 1
    assert "POSTROLL_UPDATE_GOLDENS" in said, said
    assert not runner.calls, said


def test_reference_frames_already_modified_are_refused(repo):
    move_the_clip_reel(repo)
    (repo / GOLDEN_DIR / f"{GOLDEN}.png").write_bytes(b"already moved by hand")
    runner = FakeRun()

    code, said = run(repo, runner)

    assert code == 1
    assert "uncommitted changes" in said, said
    assert not runner.calls, said


def test_a_check_that_reported_nothing_is_refused(repo):
    # A node id pytest cannot find exits green having run zero tests, which is
    # indistinguishable from a pass (L98).
    move_the_clip_reel(repo)
    runner = FakeRun(omit=NODES)

    code, said = run(repo, runner)

    assert code == 1
    assert "reported nothing at all" in said, said
    assert goldens_untouched(repo), said


def test_a_check_that_skipped_is_refused(repo):
    move_the_clip_reel(repo)
    runner = FakeRun(outcomes={node: "skipped" for node in NODES})

    code, said = run(repo, runner)

    assert code == 1
    assert "skipped rather than ran" in said, said
    assert goldens_untouched(repo), said


def test_a_run_that_collected_nothing_says_so_rather_than_blaming_a_check(repo):
    """Two causes, one symptom, and they have different repairs (L11).

    No readings at all is either every check failing before its frame or the
    collecting variable never reaching the run, and this cannot tell them apart,
    so it says both rather than naming the one it guessed.
    """
    move_the_clip_reel(repo)
    runner = FakeRun(readings=())

    code, said = run(repo, runner)

    assert code == 1
    assert "no readings at all" in said, said
    assert "POSTROLL_GOLDEN_DRIFT_LOG" in said, said
    assert goldens_untouched(repo), said


def test_a_template_photographed_twice_needs_a_reading_from_each():
    # Built directly rather than through a run, because the templates with two
    # reference frames are the Tuesday reels and rendering one here would take
    # minutes (L2). The rule is the same: a reading missing is a frame nobody
    # measured.
    from golden_drift import parse
    from tools.record_codec_change import Run, why_it_cannot_be_rerecorded

    run_with_one = Run(
        node_ids=("tests/test_golden_frames.py::test_a",
                  "tests/test_golden_frames.py::test_b"),
        outcomes={"tests/test_golden_frames.py::test_a": "failed",
                  "tests/test_golden_frames.py::test_b": "failed"},
        readings=(parse(CODEC_READING),), output="one of them failed early")

    reason = why_it_cannot_be_rerecorded(run_with_one)

    assert reason is not None and "wrote a reading" in reason, reason


def test_a_run_whose_report_never_appeared_is_refused(repo):
    move_the_clip_reel(repo)
    runner = FakeRun(report=False)

    code, said = run(repo, runner)

    assert code == 1
    assert "wrote no report" in said, said
    assert goldens_untouched(repo), said


def test_frames_that_all_passed_are_sent_to_the_other_door(repo):
    # The source moved and no pixel did, which is `make record-fingerprints`.
    move_the_clip_reel(repo)
    runner = FakeRun(outcomes={node: "passed" for node in NODES},
                     readings=UNCHANGED_READINGS, returncode=0)

    code, said = run(repo, runner)

    assert code == 1
    assert "record-fingerprints" in said, said
    assert goldens_untouched(repo), said


def test_a_failure_with_the_frame_unchanged_is_refused(repo):
    # The legibility and content checks run in the same tests. One of them
    # failing is not a frame that moved, and re-recording would record a frame
    # nobody has read.
    move_the_clip_reel(repo)
    runner = FakeRun(readings=UNCHANGED_READINGS,
                     output="the title did not read against the footage")

    code, said = run(repo, runner)

    assert code == 1
    assert "not the comparison" in said, said
    assert goldens_untouched(repo), said


def test_a_frame_that_moved_by_design_is_refused_with_its_reading(repo):
    """The refusal the whole door rests on.

    A reading whose shape says an element moved must not be re-recorded here: it
    would silence the staleness badge for a change every cached asset is now out
    of date for.
    """
    move_the_clip_reel(repo)
    runner = FakeRun(readings=DESIGN_READINGS)

    code, said = run(repo, runner)

    assert code == 1
    assert "moved by design" in said, said
    assert "median" in said, said
    assert "MEDIA_DESIGN_VERSIONS" in said, said
    assert goldens_untouched(repo), said


def test_one_design_shaped_frame_refuses_the_whole_template(repo):
    # Both frames of a two frame template, one of each. The template is refused
    # rather than half re-recorded, because a template is one design.
    move_the_clip_reel(repo)
    runner = FakeRun(readings=(CODEC_READING, _design(DELIVERED_GOLDEN)))

    code, said = run(repo, runner)

    assert code == 1
    assert "moved by design" in said, said
    assert goldens_untouched(repo), said


def test_a_measured_frame_that_was_never_kept_is_refused(repo):
    """The frame is recorded from the run that measured it (#827).

    So a reading with no frame beside it is a frame nobody kept, and the tool
    has nothing to record. Refused by name rather than skipped: skipping would
    leave the template half recorded, still failing for the frame it passed
    over, with the run reporting success.
    """
    move_the_clip_reel(repo)
    runner = FakeRun(keeps=(GOLDEN,))

    code, said = run(repo, runner)

    assert code == 1
    assert "kept no frame" in said, said
    assert DELIVERED_GOLDEN in said, said
    assert goldens_untouched(repo), said


def test_a_kept_frame_identical_to_the_committed_one_is_refused(repo):
    # The readings said a frame moved and the frame kept is byte for byte the
    # one already committed, so the two disagree and one of them is measuring
    # something other than these frames.
    move_the_clip_reel(repo)
    runner = FakeRun(kept_bytes=b"reference frame")

    code, said = run(repo, runner)

    assert code == 1
    assert "byte for byte" in said, said


def test_the_reference_checks_run_once(repo):
    """What #827 is about: one render, not two.

    The tool used to read the frames with one run and record them with a second,
    so a step that renders reels took twice as long as it needed to.
    """
    move_the_clip_reel(repo)
    runner = FakeRun()

    code, said = run(repo, runner)

    assert code == 0, said
    assert len(runner.calls) == 1, (
        f"the reference checks ran {len(runner.calls)} times for one template")
    assert not runner.rerecorded, (
        "the checks were asked to re-record, which is the second render this "
        "change exists to remove")


def test_the_frame_recorded_is_the_frame_that_was_measured(repo):
    """Not merely one render: the SAME render (#827).

    Two runs of the same checks produce two encodes, so the readings that
    allowed the re-record described a file that was then thrown away, and the
    frame committed was one nothing had judged.
    """
    move_the_clip_reel(repo)

    code, said = run(repo, FakeRun())

    assert code == 0, said
    for name in GOLDENS:
        assert (repo / GOLDEN_DIR / f"{name}.png").read_bytes() == KEPT_BYTES, (
            f"{name} was recorded as something other than the frame the run "
            f"measured")
