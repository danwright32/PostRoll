"""#233: the Swift suite must be able to block a bad pull request.

On 2026-08-09 a compile error in test setup sat red on main across eight
merges. Only the older Xcode in CI rejects it, and both signals available at
merge time were structurally unable to show it: pull requests skipped the Swift
job entirely, and running the suite locally passes because the local Xcode is
the one that ACCEPTS the code CI rejects. There was nowhere to look that would
have caught it before merging.

These assert the trigger rules that close that hole, so re-adding the blanket
pull-request skip goes red instead of going unnoticed for another eight merges.

The rule is now the strongest available: every pull request runs both jobs,
whatever it touched (#431). The paths filter that used to narrow it is gone, and
the tests that checked its coverage went with it, because a filter that runs
everything has no coverage to check. Two of those tests were themselves written
after a filter skipped precisely the change that broke the suite (#246), which is
the argument for not having one.

They read the workflow as text rather than parsing YAML, which is a real
limitation: a rule expressed in a shape these strings do not match would pass
here. Adding a YAML parser to the runtime dependencies for one test is not
worth it, and the strings below are the exact ones that were wrong.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
SWIFT = WORKFLOWS / "swift.yml"
TESTS = WORKFLOWS / "tests.yml"
SWIFT_TESTS = REPO_ROOT / "PostRollApp" / "Tests"


@pytest.fixture
def swift() -> str:
    return SWIFT.read_text()


def _jobs(swift: str) -> dict[str, str]:
    """Each job's name and body, so a claim about one job cannot be satisfied by
    something sitting in the other.

    Comment lines are dropped first. Every job here is introduced by prose that
    explains it, and prose about one job routinely names what the other one runs,
    so a scan that read the comments would report the two jobs as one the moment
    somebody documented them properly (L103). That is not hypothetical: the
    comment describing #507's shard balance names the reference-frame test files,
    and it sat above the job rather than inside it.
    """
    after = swift.split("\njobs:", 1)[1]
    jobs: dict[str, str] = {}
    current = None
    for line in after.splitlines():
        if line.strip().startswith("#"):
            continue
        header = re.match(r"^  ([A-Za-z][\w-]*):\s*$", line)
        if header:
            current = header.group(1)
            jobs[current] = ""
        elif current:
            jobs[current] += line + "\n"
    return jobs


# ── the hole that let a red main through ──────────────────────────────────────

def test_the_swift_suite_runs_on_pull_requests(swift):
    assert "pull_request:" in swift, (
        "the Swift suite must be able to block a bad PR; skipping it there is "
        "how a compile error reached main eight times")


def test_the_blanket_pull_request_skip_is_gone(swift):
    # The exact condition that caused it.
    assert "github.event_name != 'pull_request'" not in swift


def test_it_is_not_hiding_back_in_the_python_workflow():
    """Moving the job to its own file is only a fix while the old one stays
    gone. Two Swift jobs would run twice and cost double.

    Comment lines are dropped before matching. What this forbids is a Swift
    JOB in this file, and it used to forbid the WORD, so a comment explaining
    where the Swift half lives failed it. That is the mirror of L103: there a
    guard passes on prose about the thing, here it fails on prose about the
    thing, and both come from matching raw source instead of settings.
    """
    settings = "\n".join(line for line in TESTS.read_text().splitlines()
                         if not line.strip().startswith("#"))

    assert "swift" not in settings.lower(), (
        "the Swift half is back in the Python workflow, so it runs twice")


# ── every pull request runs it, whatever it touched (#431) ────────────────────


def test_no_paths_filter_narrows_what_a_pull_request_runs(swift):
    """The decision this replaces two years of tuning with.

    A filter has to be maintained against everything the suite reads, and the
    failure mode of getting it wrong is silent: the job is skipped, and a skipped
    job is indistinguishable from a passing one. That happened twice, once by
    skipping pull requests entirely (#233) and once by filtering to the app folder
    while two tests read fixtures living beside the Python suite (#246).

    Re-adding a filter is therefore a deliberate reopening of that hole, and it
    fails here rather than being noticed eight merges later.
    """
    assert "paths:" not in swift, (
        "a paths filter is back on the macOS workflow, so some pull requests will "
        "skip these checks, and a skipped check reads exactly like a passing one")


def test_the_two_halves_run_as_separate_jobs(swift):
    """Otherwise a Swift compile error is reported only after the reels render.

    They are independent: one compiles and tests the app, the other renders
    templates through Python. In one job they ran in sequence and the wall clock
    was their sum, so the fast signal arrived last.
    """
    jobs = _jobs(swift)

    assert len(jobs) >= 2, f"the macOS work is back in one job: {list(jobs)}"
    running_swift = [name for name, body in jobs.items()
                     if "-scheme PostRollTests" in body]
    running_frames = [name for name, body in jobs.items()
                      if "test_golden_frames.py" in body]

    assert running_swift and running_frames, (
        f"could not find both halves: swift in {running_swift}, "
        f"reference frames in {running_frames}")
    assert set(running_swift).isdisjoint(running_frames), (
        "the Swift tests and the reference frames are in the same job again, so "
        "the quick signal waits on the slow one")


def test_the_reference_frame_job_does_not_pay_for_a_build(swift):
    """It needs this runner's FONTS, not a compiler.

    Left in, an Xcode build would put two and a half minutes back onto the job
    that is already the slow half, for nothing it uses.
    """
    frames = next(body for name, body in _jobs(swift).items()
                  if "test_golden_frames.py" in body)

    assert "xcodebuild" not in frames, (
        "the reference-frame job builds the app, which it never uses")
    assert "xcodegen" not in frames, (
        "the reference-frame job generates the Xcode project, which it never uses")


def test_pull_requests_still_run_the_app_checks(swift):
    # The pull_request trigger has to be there at all: this whole file exists
    # because it once was not.
    assert "pull_request:" in swift
    assert "branches: [main]" in swift


def test_pushes_to_main_run_it_regardless_of_what_changed(swift):
    # The paths filter narrows what a PR pays for. It must not narrow what main
    # is verified against, or a merge could still land on an unverified main.
    push_block = swift.split("pull_request:")[0]

    assert "push:" in push_block
    assert "branches: [main]" in push_block
    assert "paths:" not in push_block, (
        "a paths filter on the push trigger would leave main unverified for "
        "any merge that did not touch the filtered paths")


def test_it_can_still_be_run_by_hand(swift):
    # How the fix in #244 was verified under CI's own Xcode before merging,
    # which is the only way to check this class of failure ahead of time.
    assert "workflow_dispatch:" in swift


# ── what it actually runs ─────────────────────────────────────────────────────

def test_it_runs_the_unit_test_scheme_not_the_gui_one(swift):
    """The job every pull request waits on must not carry the GUI suite.

    The reason used to be that a headless runner cannot drive XCUIApplication.
    That was measured on macos-26 on 2026-08-23 and is false: the runner has an
    Aqua session, the app launches, and the GUI suite passes there. It runs from
    .github/workflows/ui.yml instead, on merges and on demand.

    The rule survives on two reasons that were always the stronger ones. A UI
    test is slow and flaky by nature and must not be able to fail the fast suite
    every pull request blocks on. And a new check name on a pull request cannot
    be made green without a fixture recorded from a green run carrying it, so
    adding one takes a knowingly red merge, which is a cost to choose
    deliberately rather than to acquire by adding a test.

    What is forbidden is TESTING a scheme that pulls in PostRollUITests, not
    naming the app scheme at all. Asserting the absence of the name was a proxy
    for the rule (L63), and it also forbade the one thing that had to happen:
    compiling the app, which no CI job did until a file that would not build
    reached main with every check green.
    """
    import re

    runs = re.findall(r"-scheme\s+(\S+)(.*?)(?=-scheme|\Z)", swift, re.S)
    assert any(scheme == "PostRollTests" for scheme, _ in runs), \
        "the unit test scheme is not run at all"

    gui_tested = [
        scheme for scheme, rest in runs
        if scheme in {"PostRoll", "PostRollUITests"}
        and re.search(r"^\s+test\s*$", rest, re.M)
    ]
    assert not gui_tested, (
        f"{gui_tested} is TESTED in the job every pull request waits on, which "
        "drags in PostRollUITests: slow, flaky by nature, and a new required "
        "check name nothing can make green. It belongs in ui.yml")


def test_it_regenerates_the_project_rather_than_trusting_the_checked_in_copy(swift):
    # project.yml is the manifest; the .xcodeproj is generated from it, so a
    # stale checked-in copy would test a different set of files than the repo
    # describes.
    assert "xcodegen generate" in swift


# ── the reference frames have somewhere to run (#163) ─────────────────────────

def test_the_reference_frames_run_on_a_mac(swift):
    # They render the real templates, which draw with macOS system fonts the
    # Linux runner in tests.yml does not have. A recorded frame can only be
    # compared where it can be reproduced.
    assert "runs-on: macos" in swift
    assert "tests/test_golden_frames.py" in swift, (
        "the reference-frame checks are not run by any job, so they only ever "
        "guard a template on whoever remembers to run them locally")


def test_a_missing_font_or_encoder_fails_the_job_rather_than_skipping(swift):
    # Both of these turn a skip into a hard error. A reference check that
    # quietly skips for want of a system font reports green having compared
    # nothing, which is the exact failure mode it exists to close.
    assert "POSTROLL_REQUIRE_GOLDENS" in swift
    assert "POSTROLL_REQUIRE_FFMPEG" in swift


# ── #105: nothing floats ──────────────────────────────────────────────────────

REQUIREMENTS = REPO_ROOT / "requirements.txt"


def test_every_dependency_is_pinned_exactly():
    """requirements.txt states this rule at the top and then had to keep it.

    A ">=" line means every CI run installs whatever shipped that morning, so
    an upstream release breaks the build with no change on our side, which has
    already happened once (#105). `ruff>=0.6` sat one line below the comment
    saying not to do that, which is how a stated rule quietly stops being one.

    Derived from the file rather than a list here, so the next floored line is
    caught on the day it lands.
    """
    floated = []
    for line in REQUIREMENTS.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "==" not in stripped:
            floated.append(stripped)
    assert not floated, (
        "these dependencies are not pinned exactly, so CI installs whatever "
        f"shipped that morning: {floated}")


def test_the_requirements_file_is_not_empty():
    # A gutted file would make the check above pass by having nothing to check.
    lines = [ln for ln in REQUIREMENTS.read_text().splitlines()
             if ln.strip() and not ln.strip().startswith("#")]
    assert len(lines) >= 4, f"only {len(lines)} dependencies listed, so the scan proves little"


# ── the suite also runs on the platform the app runs on (#510) ────────────────


def test_the_suite_runs_on_a_mac_as_well_as_linux():
    """Everything but four font-dependent files ran on Linux only, while the app
    that calls this pipeline runs on Dan's Mac. Path handling, the ffmpeg build
    and its codecs, font fallbacks and filesystem case all differ, and every one
    of those stayed invisible until it was hit locally."""
    text = TESTS.read_text()
    assert "macos" in text.lower(), "the Mac leg is gone, so the suite is Linux only again"


def test_the_mac_leg_runs_the_same_command_as_the_linux_one():
    """A narrower command here would make this a different check wearing the
    same name, and a platform difference is exactly what a subset drops. This is
    the no-silent-caps rule: if the Mac leg ever runs less, it has to say so
    here rather than quietly cover less."""
    runs = re.findall(r"run: (pytest[^\n]*)", TESTS.read_text())
    assert len(runs) >= 2, f"expected a pytest command per leg, found {runs}"
    assert len(set(runs)) == 1, (
        f"the legs run different commands, so one of them covers less than its "
        f"name suggests: {sorted(set(runs))}")


def test_both_legs_report_where_their_time_went():
    """#562: the Mac leg takes four times the Linux one, and until this landed
    neither leg said where any of it went.

    `-v` prints a line per test and no timings, so answering "why is the Mac
    slow" meant guessing at causes or pushing a throwaway commit to measure.
    Both legs carry `--durations` so the comparison can be made off any run,
    and it stays on for the same reason the ffmpeg version is recorded: a
    number nobody can reproduce is not evidence.
    """
    runs = re.findall(r"run: (pytest[^\n]*)", TESTS.read_text())
    assert runs, "no pytest command in the workflow at all"
    for command in runs:
        assert "--durations" in command, (
            f"this leg reports no per-test timings, so the next person asking "
            f"where its time goes has to push a commit to find out: {command}")


def test_ci_builds_the_configuration_that_ships(swift):
    """`make install` builds Release, so Release is what reaches Dan's machine.

    CI used to build without naming a configuration, which means Debug, and the
    two compile differently: a data race error Release refuses and Debug accepts
    sat on main for three merges with every check green (#485).
    """
    build_step = swift.split("Build the app", 1)[1].split("- name:", 1)[0]
    assert "-configuration Release" in build_step, (
        "the app build does not name Release, so the configuration Dan actually "
        "installs is never compiled by CI")


# ── the guard proofs are re-run rather than only recorded (#541) ──────────────

GUARDS = REPO_ROOT / ".github" / "workflows" / "guards.yml"


@pytest.fixture
def guards() -> str:
    return GUARDS.read_text(encoding="utf-8")


def test_the_guard_proofs_have_a_workflow_at_all(guards):
    assert "check_guards.py" in guards, (
        "nothing re-runs the recorded proofs, so they decay into a claim while "
        "the registry keeps reporting itself consistent (L1)")


def test_every_pull_request_reproves_the_entries_it_touches(guards):
    """The half that catches a guard edited into uselessness by the same change
    that edits it."""
    assert "pull_request:" in guards
    assert "--changed" in guards, (
        "no leg scopes the proof to the diff, so a pull request re-proves "
        "nothing of its own")


def test_the_whole_registry_is_reproved_on_every_merge(guards):
    """The half that catches a guard broken by something UNDERNEATH it.

    The diff-scoped leg re-proves an entry when the code it guards, its record,
    or its own test file changes. It cannot know about the shared conftest
    nearly every test imports, or a shared fixture module: a change there can
    stop a guard failing on broken code while touching none of the three, so no
    pull request would re-prove it (L88).
    """
    assert re.search(r"push:\s*\n\s*branches:\s*\[main\]", guards), (
        "nothing runs the full sweep, so the expensive half only happens when "
        "somebody remembers to type it")

    # It has to be the FULL sweep. Scoping this one to a diff would report green
    # on every merge while proving nothing, because a merge commit's diff
    # against main is empty (L98).
    full = guards.split("  full:", 1)[1]
    assert "--changed" not in full, (
        "the merge run is scoped to a diff, and a merge has no diff against "
        "main, so it would prove nothing while reporting green")

    # A backstop, not an expectation: measured at roughly 15 minutes of proving
    # plus one build. An hour-plus timeout on a job this size hides a hang.
    timeout = re.search(r"  full:.*?timeout-minutes:\s*(\d+)", guards, re.S)
    assert timeout and int(timeout.group(1)) <= 120, (
        "the timeout is far above the measured runtime, so a wedged run bills "
        "for hours before anything says so")


def test_it_can_be_run_by_hand(guards):
    assert "workflow_dispatch:" in guards


def test_the_changed_leg_can_find_a_merge_base(guards):
    """`--changed` diffs against the merge base with origin/main, and a shallow
    checkout has none, which the tool reports as an error rather than as an
    empty result."""
    changed = guards.split("changed:", 1)[1].split("nightly:", 1)[0]
    assert "fetch-depth: 0" in changed, (
        "the diff-scoped leg checks out shallow, so it cannot find a merge base")


# ── the failure paths of the thing that workflow runs ─────────────────────────
#
# The config assertions above prove the workflow says the right words. These
# prove the command behind those words fails loudly on the two ways a scoped
# run can come up empty, because "0 entries affected" is a legitimate answer
# here and has to be distinguishable from a run that found nothing because it
# was broken (L98).


def _scratch_repo(tmp_path: Path) -> Path:
    import subprocess
    repo = tmp_path / "repo"
    repo.mkdir()
    for args in (["init", "-q", "-b", "main"],
                 ["config", "user.email", "t@example.com"],
                 ["config", "user.name", "T"]):
        subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)
    (repo / "a.txt").write_text("x\n")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-qm", "first"], cwd=repo, check=True, capture_output=True)
    return repo


def test_a_scoped_run_with_nothing_to_diff_against_refuses(tmp_path):
    """A checkout with no origin/main and no upstream, which is what a shallow
    clone in CI looks like. It must refuse rather than report that no guard
    needed proving: those two look identical from the outside, and only one of
    them means the guards were checked."""
    import shutil
    import subprocess

    repo = _scratch_repo(tmp_path)
    (repo / "tools").mkdir()
    shutil.copy(REPO_ROOT / "tools" / "check_guards.py", repo / "tools")
    # check_guards imports this at module level since #920. Without it the run
    # dies on the import, and this test then passes or fails for a reason it is
    # not about.
    shutil.copy(REPO_ROOT / "tools" / "perturbation_lock.py", repo / "tools")
    (repo / "tests" / "fixtures" / "guard_mutations").mkdir(parents=True)
    shutil.copy(
        next((REPO_ROOT / "tests" / "fixtures" / "guard_mutations").glob("*.json")),
        repo / "tests" / "fixtures" / "guard_mutations")

    result = subprocess.run(
        ["python3", "tools/check_guards.py", "--changed"],
        cwd=repo, capture_output=True, text=True)

    assert result.returncode != 0, (
        "a scoped run with no base to diff against exited 0, so a shallow "
        f"checkout in CI would report green having proven nothing:\n{result.stdout}")
    assert "base" in (result.stdout + result.stderr).lower(), (
        "it failed without saying that the missing base is why")


def test_an_empty_registry_refuses_rather_than_passing(tmp_path):
    """The other empty: a registry with no entries at all. Every assertion a
    sweep makes would pass vacuously."""
    import shutil
    import subprocess

    repo = _scratch_repo(tmp_path)
    (repo / "tools").mkdir()
    shutil.copy(REPO_ROOT / "tools" / "check_guards.py", repo / "tools")
    # check_guards imports this at module level since #920. Without it the run
    # dies on the import, and this test then passes or fails for a reason it is
    # not about.
    shutil.copy(REPO_ROOT / "tools" / "perturbation_lock.py", repo / "tools")
    (repo / "tests" / "fixtures" / "guard_mutations").mkdir(parents=True)

    result = subprocess.run(
        ["python3", "tools/check_guards.py"],
        cwd=repo, capture_output=True, text=True)

    assert result.returncode != 0, (
        f"an empty registry proved nothing and said it passed:\n{result.stdout}")


def test_the_guard_job_runs_on_the_image_that_has_the_pinned_xcode(guards):
    """Half the entries are proved by xcodebuild, and the step that selects the
    recorded Xcode refuses rather than falling back to whatever the image
    ships. On the wrong image that is a job that can never pass."""
    swift_runner = re.search(r"runs-on:\s*(macos-\S+)", SWIFT.read_text(encoding="utf-8"))
    assert swift_runner, "the Swift workflow names no macOS image"

    images = set(re.findall(r"runs-on:\s*(macos-\S+)", guards))
    assert images, "the guard workflow names no macOS image"
    assert images == {swift_runner.group(1)}, (
        f"the guard jobs run on {sorted(images)} while the Xcode pin is only on "
        f"{swift_runner.group(1)}")


def test_the_guard_runner_does_not_insist_on_a_venv(tmp_path):
    """The failure path that took the whole guard job down the first time it ran
    off Dan's Mac.

    Every Python entry reported "the runner failed: no such file" because the
    interpreter was a hardcoded `venv/bin/python`, which a CI runner does not
    have. The job went red rather than reporting the guards proven, which is the
    tool being honest, but it could never pass.

    Driven through the CLI in a checkout with no venv, which is exactly the
    shape CI checks out, rather than by importing the tool: what has to be true
    is what the runner gets.
    """
    import json as _json
    import shutil
    import subprocess

    repo = _scratch_repo(tmp_path)
    (repo / "tools").mkdir()
    shutil.copy(REPO_ROOT / "tools" / "check_guards.py", repo / "tools")
    # check_guards imports this at module level since #920. Without it the run
    # dies on the import, and this test then passes or fails for a reason it is
    # not about.
    shutil.copy(REPO_ROOT / "tools" / "perturbation_lock.py", repo / "tools")
    registry = repo / "tests" / "fixtures" / "guard_mutations"
    registry.mkdir(parents=True)

    # One entry whose test passes on unbroken code and fails on broken code, so
    # the run has something real to do without needing this repo's suite.
    (repo / "guarded.py").write_text("VALUE = 1\n")
    (repo / "tests").mkdir(exist_ok=True)
    (repo / "tests" / "test_guarded.py").write_text(
        "import sys\nsys.path.insert(0, '.')\n"
        "from guarded import VALUE\n\ndef test_value():\n    assert VALUE == 1\n")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-qm", "guarded"], cwd=repo,
                   check=True, capture_output=True)
    (registry / "value-is-one.json").write_text(_json.dumps({
        "name": "value-is-one",
        "file": "guarded.py",
        "find": "VALUE = 1",
        "replace": "VALUE = 2",
        "test": "tests/test_guarded.py::test_value",
        "breaks": "the value changes and nothing notices",
    }))

    result = subprocess.run(
        [sys.executable, "tools/check_guards.py", "--only", "value-is-one"],
        cwd=repo, capture_output=True, text=True, timeout=300)

    combined = result.stdout + result.stderr
    assert "venv/bin/python" not in combined, (
        f"the runner still insists on a venv this checkout does not have:\n{combined}")
    assert "KILLED" in combined, (
        f"the guard was not proven, so the run did not actually happen:\n{combined}")
    assert result.returncode == 0, combined


# ── the Mac leg blocks a pull request (#550) ──────────────────────────────────
#
# Decided on evidence rather than on principle. On 2026-08-14 the Mac leg found
# a real platform difference on its first run, and the pull request carrying it
# reported 5 passed / 0 failed while that was happening, because a job gated off
# pull requests is not in the rollup a merge is judged by. It merged, and main
# went red. A check that cannot run before the merge cannot stop the merge, and
# a skipped job reads exactly like a passing one (L98).


def test_the_mac_leg_is_not_gated_off_pull_requests():
    """The whole point of the promotion: it has to be able to block."""
    text = TESTS.read_text(encoding="utf-8")
    assert "github.event_name != 'pull_request'" not in text, (
        "the Mac leg is skipped on pull requests again, so a Mac-only break "
        "cannot be caught until after it has merged, and the pull request "
        "reports green while it happens")


def test_both_test_legs_run_on_a_pull_request():
    """Neither leg may carry a condition that quietly removes it from the set a
    merge is judged by."""
    text = TESTS.read_text(encoding="utf-8")
    assert re.search(r"pull_request:\s*\n\s*branches:\s*\[main\]", text), (
        "the suite does not run on pull requests at all")
    # `if:` on a job is how a leg gets removed from the rollup while still
    # appearing in the file, which is the shape this exists to catch.
    job_conditions = re.findall(r"^    if: (.+)$", text, re.MULTILINE)
    assert not job_conditions, (
        f"a test leg is conditional, so it may not run on a pull request while "
        f"still reading as present: {job_conditions}")


# ── the guards are re-proved on a schedule too (#551) ─────────────────────────


def test_the_full_sweep_also_runs_on_a_schedule(guards):
    """The proofs depend on things no commit here touches: the runner image, the
    Xcode the pin selects, and Homebrew packages. Any of those can move without
    a commit, and with proofs that only run on a merge the first sign is a red
    merge on whatever unrelated change happens to land next, which is the worst
    moment to meet it and the hardest to attribute (L1).
    """
    assert re.search(r"schedule:\s*\n\s*- cron:", guards), (
        "the full sweep runs only when something merges, so through a quiet "
        "period nothing re-proves the guards at all")


def test_the_scheduled_sweep_is_admitted_by_the_full_job(guards):
    """A schedule trigger the job's own condition excludes is a trigger that
    fires and runs nothing, which reports success (L98)."""
    assert "if: github.event_name != 'pull_request'" in guards, (
        "the full job's condition changed; re-check that a scheduled run still "
        "reaches it")


# ── what the legs actually ran against is recorded (#552) ─────────────────────


def _jobs(text: str) -> dict[str, str]:
    """Each job in a workflow, by name, so a claim about one cannot be met by
    another (L135)."""
    found = {m.group(1): m.group(2) for m in re.finditer(
        r"^  ([a-z0-9-]+):[ \t]*$(.*?)(?=^  \S|\Z)", text, re.M | re.S)}
    assert found, "no jobs found at all, so every check over them is vacuous"
    return found


def test_both_legs_record_the_ffmpeg_version_they_ran_against():
    """Both legs install whatever ffmpeg is current on the day. The Mac leg
    exists to catch differences in ffmpeg builds and codecs between platforms,
    so an unrecorded version on either side makes its result ambiguous: when it
    goes red there is no way to tell our own change from ffmpeg having moved,
    and the reflex is to read the diff, which is where the answer is not.

    Asked per JOB, and asked for the ffmpeg version specifically. This used to
    count occurrences of GITHUB_STEP_SUMMARY across the whole file and want two
    of them, which is a proxy rather than the thing it protects (L63). #787 then
    added two unrelated steps writing to that summary, and deleting the ffmpeg
    recording outright left the count at two: the registered mutation SURVIVED,
    on a guard that had passed every day since #552.

    Which jobs have to record it is derived from which jobs install it, so a
    third leg is covered the day it lands rather than the day somebody
    remembers this file (L96).
    """
    jobs = _jobs(TESTS.read_text(encoding="utf-8"))
    installing = {name: body for name, body in jobs.items()
                  if re.search(r"install ffmpeg", body, re.I)}
    assert len(installing) >= 2, (
        f"expected both test legs to install ffmpeg, found {sorted(installing)}")

    unrecorded = [
        name for name, body in sorted(installing.items())
        if not any("ffmpeg -version" in step and "GITHUB_STEP_SUMMARY" in step
                   for step in body.split("- name:"))
    ]
    assert not unrecorded, (
        f"these legs install ffmpeg and never write the version they got into "
        f"the job summary: {unrecorded}. A red run on that leg then cannot be "
        "attributed: our own change and ffmpeg having moved underneath us look "
        "identical.")


def test_the_guard_job_says_whether_the_schedule_is_still_alive(guards):
    """The weekly trigger's failure mode is silence, so something has to ask the
    question out loud (#554, L13)."""
    assert "check_guard_sweep_freshness.py" in guards, (
        "nothing reports whether the scheduled sweep is still happening, so it "
        "could stop with nothing saying so")
    assert "if: always()" in guards, (
        "the freshness check is skipped when the sweep above it goes red, so "
        "two failures would hide each other (L73)")


def test_the_freshness_question_is_asked_once_not_once_per_shard(guards):
    """The sweep is a matrix; the question is about the workflow.

    Asked on every shard it is answered four times, which is noise on a check
    whose only value is being noticed. Scoping it to one shard keeps it a single
    answer.

    It was briefly its own job instead, which is tidier and wrong: a new job is
    a new CHECK NAME, and tests/test_wait_for_checks.py calibrates the checks it
    waits for against a RECORDED reply from a real pull request. A name added to
    the workflows with no new recording would have meant hand-editing that
    fixture, and a fixture edited to match the thing it is meant to verify is no
    longer evidence of anything (L48, L58).
    """
    assert "matrix.shard == 1" in guards, (
        "the freshness question is asked on every shard of the sweep, so it is "
        "answered once per runner")


# ── every job has a deadline (#832) ──────────────────────────────────────────
#
# Here rather than in a file of its own because it is the same subject: what the
# workflows have to guarantee before a pull request can be trusted, read the
# same way, out of the same files.
#
# On 2026-08-22 the Linux test job wedged twice on one commit. It carries no
# `timeout-minutes`, so it ran until it was cancelled by hand, 45 minutes the
# first time. A job with no deadline cannot fail, it can only hang, and a hang
# is worse than a failure because it is indistinguishable from a slow queue
# (L110): that job normally takes about three minutes, and nothing on the checks
# list said which of the two was happening.
#
# The deadline VALUES are a judgement that will drift as the suite grows, so
# this asserts only that each job has one. What it is really protecting against
# is a job added tomorrow inheriting the rule instead of somebody having to
# remember it (L96).

WORKFLOW_FILES = ("tests.yml", "swift.yml", "guards.yml")


def jobs_without_a_deadline(text: str) -> list[str]:
    """Every job in one workflow that declares no `timeout-minutes`.

    Read as text, for the reason this whole file gives. Only what follows the
    `jobs:` key is scanned, because `concurrency:` carries two-space keys of its
    own above it and they are not jobs. Comment lines are dropped: a line
    MENTIONING the deadline is not a deadline, and a guard answered by prose
    about the thing is indistinguishable from one that works (L103).
    """
    lines = [line for line in text.splitlines() if not line.strip().startswith("#")]
    try:
        start = next(i for i, line in enumerate(lines) if line.rstrip() == "jobs:")
    except StopIteration:
        raise AssertionError(
            "this workflow declares no `jobs:` at all, so nothing here read a "
            "job. That is a failure rather than an empty answer: a guard that "
            "cannot find its subject has measured nothing (L98).") from None

    jobs: dict[str, list[str]] = {}
    current: str | None = None
    for line in lines[start + 1:]:
        if re.match(r"^[^\s#]", line):        # back out to the top level
            break
        named = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if named:
            current = named.group(1)
            jobs[current] = []
        elif current is not None:
            jobs[current].append(line)

    assert jobs, ("no jobs were read out of this workflow, so this check passed "
                  "over an empty set")
    return sorted(name for name, body in jobs.items()
                  if not any(re.match(r"^    timeout-minutes:\s*\d+", line)
                             for line in body))


def test_every_ci_job_carries_a_deadline():
    missing: list[str] = []
    for name in WORKFLOW_FILES:
        text = (WORKFLOWS / name).read_text()
        missing += [f"{name}: {job}" for job in jobs_without_a_deadline(text)]

    assert not missing, (
        "these CI jobs have no timeout-minutes, so a run that stops making "
        "progress in one of them sits until the platform's own default rather "
        "than failing: " + ", ".join(missing))


def test_the_deadline_reader_can_see_a_job_that_lacks_one():
    """The guard's own mechanism, seen working (L1).

    Without this the check above passes whenever the reader stops matching,
    which is the same green as a workflow where every job is covered.
    """
    text = "jobs:\n  covered:\n    timeout-minutes: 45\n    runs-on: x\n  bare:\n    runs-on: y\n"

    assert jobs_without_a_deadline(text) == ["bare"]
