"""#660: the fingerprint guard's re-record path only records what was proven.

`tests/test_media_design_fingerprint.py` fails when a template's source moves
and offers two ways out, one of which is safe. Until #660 the unsafe one was
the only one implemented: there was no supported way to record a fingerprint
alone, so it was done with a script written on the spot, which cannot tell a
template whose rendering is unchanged from one that genuinely was redesigned.
That is the single thing the guard exists to prevent.

`tools/record_design_fingerprints.py` records a fingerprint only after the
reference frames that photograph that template have been seen to pass. These
drive it against a throwaway git repo and a fake test runner, so nothing here
renders a reel or touches the checkout (L2). The fake writes REAL junit XML,
measured from a live `pytest --junit-xml` run rather than imagined (L52); the
shapes it reproduces are a pass, a `<skipped>` child, a `<failure>` child, and
a case that reported nothing at all.

The refusals are the point, so each has a test that PRODUCES it (L151) rather
than one that merely passes.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from postroll.media import design_fingerprint as fp
from postroll.media import design_tokens as tokens
from tools.record_design_fingerprints import (
    GOLDEN_DIR,
    RECORD_PATH,
    REFERENCE_TESTS,
    UNPHOTOGRAPHED,
    record,
)

REPO_ROOT = Path(__file__).resolve().parent.parent


# ── the registry is held to the real test file, in both directions ────────────


def test_every_named_reference_check_really_exists():
    # Node ids written by hand. A renamed test would leave the tool asking for
    # a check that matches nothing, and pytest reports that as a clean run of
    # zero tests (L98). The tool refuses on the count too; this says so at
    # suite time, against pytest's own collection rather than a guess at it.
    collected = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/test_golden_frames.py",
         "--collect-only", "-q", "--no-header", "-p", "no:cacheprovider"],
        cwd=REPO_ROOT, capture_output=True, text=True)
    assert collected.returncode == 0, collected.stdout + collected.stderr
    on_disk = set(collected.stdout.splitlines())

    named = {node for nodes in REFERENCE_TESTS.values() for node in nodes}
    missing = sorted(named - on_disk)

    assert not missing, (
        f"these reference checks are named in REFERENCE_TESTS and do not exist: "
        f"{missing}. The tool would ask pytest for them and be handed a run of "
        f"nothing.")


def test_every_template_is_either_photographed_or_named_as_not():
    # The direction a hand kept registry gets wrong (L96): a template nobody
    # added is exempt from the very gate meant to cover it. A new template must
    # be put in one list or the other, deliberately.
    unaccounted = sorted(set(fp.TEMPLATE_MODULES) - set(REFERENCE_TESTS)
                         - set(UNPHOTOGRAPHED))

    assert not unaccounted, (
        f"these templates are in neither REFERENCE_TESTS nor UNPHOTOGRAPHED: "
        f"{unaccounted}. Name the reference checks that photograph each one, or "
        f"record why nothing does.")


def test_no_template_is_in_both_lists():
    both = sorted(set(REFERENCE_TESTS) & set(UNPHOTOGRAPHED))
    assert not both, f"claimed as both photographed and not: {both}"


def test_a_template_named_as_unphotographed_says_why():
    for template, reason in UNPHOTOGRAPHED.items():
        assert len(reason.split()) >= 5, (
            f"{template} is exempt from the gate with no reason anyone can "
            f"read; an unexplained exemption is indistinguishable from an "
            f"oversight")


# ── a throwaway repo the tool can be driven against ──────────────────────────


def git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.email=t@example.com", "-c", "user.name=t", *args],
        cwd=repo, check=True, capture_output=True)


def build_tree(root: Path) -> Path:
    """A copy of the media tree, its fingerprint record and its reference frames.

    A copy, because the fingerprint has to be MOVED to exercise anything here
    and the checkout is off limits (#497).
    """
    shutil.copytree(REPO_ROOT / "postroll" / "media", root / "postroll" / "media")

    record_file = root / RECORD_PATH
    record_file.parent.mkdir(parents=True, exist_ok=True)
    record_file.write_text(
        json.dumps({name: {"fingerprint": value,
                           "version": tokens.MEDIA_DESIGN_VERSIONS[name]}
                    for name, value in fp.fingerprints(root).items()},
                   indent=2, sort_keys=True) + "\n", encoding="utf-8")

    goldens = root / GOLDEN_DIR
    goldens.mkdir(parents=True, exist_ok=True)
    for name in ("collage", "story", "before_after", "slider_reel",
                 "morph_reel", "scroll_reel", "screen_reel"):
        # Stand-ins: nothing here reads a pixel, only git's opinion of them.
        (goldens / f"{name}.png").write_bytes(b"reference frame")
    return root


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """`build_tree` under real git, so the dirty check is the one that ships."""
    build_tree(tmp_path)
    git(tmp_path, "init", "-q")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-qm", "the state everything here starts from")
    return tmp_path


def move_fingerprint(repo: Path, module: str) -> None:
    """Change what a module renders, in the copy, without changing prose."""
    source = repo / "postroll" / "media" / module
    source.write_text(source.read_text(encoding="utf-8") + "\n_MOVED = 1\n",
                      encoding="utf-8")


def recorded(repo: Path) -> dict:
    return json.loads((repo / RECORD_PATH).read_text(encoding="utf-8"))


#: Junit XML as pytest 8 writes it, measured from a real run on 2026-08-17:
#: `<testcase classname="tests.test_golden_frames" name="test_x" />`, with a
#: `<skipped>` or `<failure>` child when it did not pass.
def _case(node_id: str, outcome: str = "passed") -> str:
    path, _, name = node_id.partition("::")
    classname = path[: -len(".py")].replace("/", ".")
    body = {
        "passed": "",
        "skipped": '<skipped type="pytest.skip" message="no fonts">skipped</skipped>',
        "failed": '<failure message="assert False">assert False</failure>',
    }[outcome]
    inner = f">{body}</testcase>" if body else " />"
    return f'<testcase classname="{classname}" name="{name}"{inner}'


class FakeRunner:
    """A stand-in for the reference-frame run, with a recorded verdict."""

    def __init__(self, *, outcomes: dict[str, str] | None = None,
                 omit: tuple[str, ...] = (), report: bool = True,
                 returncode: int = 0, output: str = "") -> None:
        self.outcomes = outcomes or {}
        self.omit = omit
        self.report = report
        self.returncode = returncode
        self.output = output
        self.calls: list[tuple[tuple[str, ...], dict[str, str]]] = []

    def __call__(self, node_ids, report_path: Path, env,
                 repo_root: Path) -> tuple[int, str]:
        self.calls.append((tuple(node_ids), dict(env)))
        if self.report:
            cases = "".join(_case(node, self.outcomes.get(node, "passed"))
                            for node in node_ids if node not in self.omit)
            report_path.write_text(
                f'<?xml version="1.0" encoding="utf-8"?><testsuites name="pytest tests">'
                f'<testsuite name="pytest">{cases}</testsuite></testsuites>',
                encoding="utf-8")
        return self.returncode, self.output


def run(repo: Path, runner: FakeRunner, **env) -> tuple[int, str]:
    log: list[str] = []
    code = record(repo, runner=runner, env=env, log=log.append)
    return code, "\n".join(log)


# ── the safe path ────────────────────────────────────────────────────────────


def test_a_proven_template_is_recorded_and_the_rest_are_left_alone(repo: Path):
    before = recorded(repo)
    move_fingerprint(repo, "generate_reel_screen.py")
    runner = FakeRunner()

    code, said = run(repo, runner)

    after = recorded(repo)
    assert code == 0, said
    assert after["reel_screen"]["fingerprint"] == fp.fingerprint("reel_screen", repo)
    assert after["reel_screen"]["fingerprint"] != before["reel_screen"]["fingerprint"]
    assert {k: v for k, v in after.items() if k != "reel_screen"} == \
           {k: v for k, v in before.items() if k != "reel_screen"}
    assert "reel_screen" in said


def test_only_the_checks_that_photograph_the_moved_template_are_run(repo: Path):
    # A re-record that ran the whole reference suite would cost ten minutes and,
    # worse, would report a template as proven on evidence about another one.
    move_fingerprint(repo, "generate_reel_screen.py")
    runner = FakeRunner()

    run(repo, runner)

    assert [nodes for nodes, _ in runner.calls] == [REFERENCE_TESTS["reel_screen"]]


def test_the_reference_run_is_not_allowed_to_skip_anything(repo: Path):
    # A skipped reference check is indistinguishable from a passing one (L98),
    # and both externals it needs are absent on some machines. The run is asked
    # for in the mode where a missing font or a missing ffmpeg fails loudly.
    move_fingerprint(repo, "generate_reel_screen.py")
    runner = FakeRunner()

    run(repo, runner, POSTROLL_REQUIRE_GOLDENS="", HOME="/somewhere")

    _, env = runner.calls[0]
    assert env["POSTROLL_REQUIRE_GOLDENS"] == "1"
    assert env["POSTROLL_REQUIRE_FFMPEG"] == "1"
    assert env["HOME"] == "/somewhere", "the run needs the rest of the environment"


def test_a_deliberate_redesign_records_the_version_it_was_taken_at(repo: Path,
                                                                  monkeypatch):
    # The other half of the workflow: the goldens were re-recorded, LOOKED at
    # and committed, and the version bumped by hand. The record then has to
    # carry the new version, or the guard that holds the two together fails.
    monkeypatch.setitem(tokens.MEDIA_DESIGN_VERSIONS, "reel_screen", 2)
    move_fingerprint(repo, "generate_reel_screen.py")

    code, said = run(repo, FakeRunner())

    assert code == 0, said
    assert recorded(repo)["reel_screen"]["version"] == 2


# ── the refusals ─────────────────────────────────────────────────────────────


def test_nothing_to_record_is_not_a_success(repo: Path):
    # Reached only by someone whose guard just failed, so finding no moved
    # template means the tool is looking at a different tree from the one that
    # failed. Reporting that as a clean run would send them away satisfied.
    before = (repo / RECORD_PATH).read_bytes()
    runner = FakeRunner()

    code, said = run(repo, runner)

    assert code != 0
    assert "no template" in said.lower() or "nothing" in said.lower()
    assert not runner.calls
    assert (repo / RECORD_PATH).read_bytes() == before


def test_a_template_nothing_photographs_is_refused(repo: Path):
    # reel_clip has no reference frame, so no run here can show its rendering
    # is unchanged. Recording it would be the hand written re-record wearing a
    # tool's name.
    before = (repo / RECORD_PATH).read_bytes()
    move_fingerprint(repo, "render_clip_reel.py")

    code, said = run(repo, FakeRunner())

    assert code != 0
    assert "reel_clip" in said
    assert (repo / RECORD_PATH).read_bytes() == before


def test_a_skipped_reference_check_is_not_a_passing_one(repo: Path):
    before = (repo / RECORD_PATH).read_bytes()
    move_fingerprint(repo, "generate_reel_screen.py")
    skipped = {node: "skipped" for node in REFERENCE_TESTS["reel_screen"]}

    code, said = run(repo, FakeRunner(outcomes=skipped))

    assert code != 0
    assert "skip" in said.lower()
    # Named as a skip, not folded into the catch-all below it. Refusing is not
    # enough on its own: a skip means the check never ran, and reporting it as
    # a changed rendering sends the reader to bump a version for a change
    # nobody made (L11). The mutation sweep found this test passing on both.
    assert "rendering changed" not in said, said
    assert (repo / RECORD_PATH).read_bytes() == before


def test_a_failed_reference_check_is_refused(repo: Path):
    before = (repo / RECORD_PATH).read_bytes()
    move_fingerprint(repo, "generate_reel_screen.py")
    failed = {REFERENCE_TESTS["reel_screen"][0]: "failed"}

    code, said = run(repo, FakeRunner(outcomes=failed, returncode=1))

    assert code != 0
    assert REFERENCE_TESTS["reel_screen"][0] in said
    assert (repo / RECORD_PATH).read_bytes() == before


def test_a_check_that_reported_nothing_at_all_is_refused(repo: Path):
    # The shape a renamed or deselected test takes: pytest exits 0 having run
    # what it could find, and the missing one leaves no case in the report.
    before = (repo / RECORD_PATH).read_bytes()
    move_fingerprint(repo, "generate_reel_screen.py")

    code, said = run(repo, FakeRunner(omit=(REFERENCE_TESTS["reel_screen"][0],)))

    assert code != 0
    assert REFERENCE_TESTS["reel_screen"][0] in said
    assert (repo / RECORD_PATH).read_bytes() == before


def test_a_run_that_wrote_no_report_is_refused_and_quotes_it(repo: Path):
    # What a refused run looks like: conftest raises before collection when
    # POSTROLL_REQUIRE_GOLDENS is set on a machine without the fonts, so there
    # is no report at all. An unreadable answer is not an empty one (L105), and
    # the reason lives in the run's own output, which has to be shown (L158).
    before = (repo / RECORD_PATH).read_bytes()
    move_fingerprint(repo, "generate_reel_screen.py")
    runner = FakeRunner(report=False, returncode=4,
                        output="UsageError: the macOS system fonts are missing")

    code, said = run(repo, runner)

    assert code != 0
    assert "macOS system fonts are missing" in said
    assert (repo / RECORD_PATH).read_bytes() == before


def test_a_reference_frame_with_uncommitted_changes_cannot_vouch_for_anything(
        repo: Path):
    # The hole this tool is built to close. Re-recording the goldens and then
    # recording the fingerprint would pass every check in here while blessing a
    # template that really did change: the reference was regenerated from the
    # very code in question. It has to be committed, which is where the golden
    # path's own rule (LOOK at it first) lives.
    #
    # The whole reference folder, not this template's frames: an uncommitted
    # golden anywhere means a re-record is in flight, and one path nobody can
    # spell two ways cannot drift from the templates it is supposed to cover
    # (L41). Which is why a moved reel_screen is refused over a dirty collage.
    before = (repo / RECORD_PATH).read_bytes()
    move_fingerprint(repo, "generate_reel_screen.py")
    (repo / GOLDEN_DIR / "collage.png").write_bytes(b"a freshly recorded frame")
    runner = FakeRunner()

    code, said = run(repo, runner)

    assert code != 0
    assert "collage.png" in said
    assert not runner.calls, "nothing should be rendered on evidence this weak"
    assert (repo / RECORD_PATH).read_bytes() == before


def test_a_git_that_cannot_answer_is_refused_rather_than_read_as_clean(
        tmp_path_factory):
    # `git status` prints nothing on a clean tree and nothing when it fails, so
    # the two are one empty string and only one of them is safe (L11). Produced
    # here rather than assumed: this outcome is enumerated in the tool and would
    # otherwise be a branch nobody ever built (L151).
    #
    # Its own root, NOT a copy inside the fixture repo. The first version of
    # this test put it there, so git answered perfectly well about a tree it
    # owned, called the untracked copy dirty, and the test passed on the wrong
    # refusal entirely. The mutation sweep is what found it.
    outside = build_tree(tmp_path_factory.mktemp("outside-any-repo"))
    before = (outside / RECORD_PATH).read_bytes()
    move_fingerprint(outside, "generate_reel_screen.py")
    runner = FakeRunner()

    code, said = run(outside, runner)

    assert code != 0
    assert "uncommitted" in said.lower()
    assert not runner.calls
    assert (outside / RECORD_PATH).read_bytes() == before


def test_recording_while_the_goldens_are_being_rewritten_is_refused(repo: Path):
    # POSTROLL_UPDATE_GOLDENS makes every reference check re-record and skip,
    # so the gate would be answered by a run that checked nothing. Refused by
    # name rather than left to the skip check, so the reason is the real one.
    before = (repo / RECORD_PATH).read_bytes()
    move_fingerprint(repo, "generate_reel_screen.py")
    runner = FakeRunner()

    code, said = run(repo, runner, POSTROLL_UPDATE_GOLDENS="1")

    assert code != 0
    assert "POSTROLL_UPDATE_GOLDENS" in said
    assert not runner.calls
    assert (repo / RECORD_PATH).read_bytes() == before


def test_a_proven_template_beside_an_unprovable_one_records_only_the_proven(
        repo: Path):
    # What #656 actually looked like: one change moved every template at once.
    # The ones with a reference frame are recorded, the rest are named, and the
    # run reports failure so the unproven ones cannot be missed.
    move_fingerprint(repo, "generate_reel_screen.py")
    move_fingerprint(repo, "render_clip_reel.py")

    code, said = run(repo, FakeRunner())

    after = recorded(repo)
    assert code != 0
    assert after["reel_screen"]["fingerprint"] == fp.fingerprint("reel_screen", repo)
    assert after["reel_clip"]["fingerprint"] != fp.fingerprint("reel_clip", repo)
    assert "reel_clip" in said
