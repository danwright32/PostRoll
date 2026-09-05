"""A test that wedges says which test it was (#836).

#832 gave every CI job a deadline, which stops a wedged run burning the
platform's default. What it cannot do is say what wedged: a job killed by
`timeout-minutes` reports only that the job ran out of time. On 2026-08-22
finding that out took cancelling two runs and pairing each `pytest -v` start
line against its verdict by hand.

`pytest-timeout` turns that into one red line naming the test, with the stack it
was stuck in. The job deadline stays as the backstop for a run that wedges
OUTSIDE a test, in a fixture at collection time or in the runner itself, which is
the part no per-test limit can see.

Two choices here were measured rather than assumed.

THE METHOD IS `signal`, NOT `thread`. Both were run against a wedged test under
`-n 2 --dist worksteal` on 2026-08-22, and both named it. They differ in what
survives:

* `signal` schedules SIGALRM, calls `pytest.fail()` in the handler, and the run
  CONTINUES. The failure carries the test's own stack, the rest of that worker's
  queue still runs, and the junit report is written normally.
* `thread` terminates the whole worker process. xdist notices and reports
  `worker 'gw2' crashed while running <test>`, so the test is still named, but
  everything else that worker had left is lost.

The junit report is the deciding half. `tools/record_test_durations.py` reads it
to decide whether a red run may still be recorded (#837), and pytest-timeout's
own documentation says junit XML output does not function normally under the
thread method. Nothing in this repo uses SIGALRM itself, which is the documented
way the signal method breaks, so the safer method is also the available one.

THE LIMIT IS SIZED FROM A REAL READING, and deliberately not from
`tests/fixtures/test_file_durations.json`. That record stores summed seconds per
FILE, which is an upper bound on any single test rather than a measurement of
one, and re-recording it to add a per-test figure is not free: measured on
2026-08-22 a fresh recording puts `test_slider_program_plate.py` at 3.45% and
`test_record_codec_change.py` at 3.98% of the run, both inside the band
`EXPENSIVE_SHARE` is required to keep clear, so it would turn the fast-subset
floor red and drag re-choosing that floor into an unrelated change.
"""

from __future__ import annotations

import re
import subprocess
import sys
import textwrap
from pathlib import Path

from tests.source_text import python_without_comments, yaml_without_comments
from tools.wait_for_checks import _job_blocks

REPO_ROOT = Path(__file__).resolve().parent.parent
PYPROJECT = REPO_ROOT / "pyproject.toml"
REQUIREMENTS = REPO_ROOT / "requirements.txt"
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

#: The slowest SINGLE test measured anywhere, in seconds.
#:
#: Hand recorded, and that is worth saying plainly: a hand-kept number checks
#: only what somebody remembered to update (L96). It is here rather than derived
#: because the only recorded measurement in the repo is per FILE, for the reason
#: the module docstring gives.
#:
#: It is refreshable off an ordinary run rather than a special one, which is what
#: keeps it from going quietly stale: both CI legs run `pytest --durations=25`,
#: so any green run prints this. Re-read it with
#:
#:     gh run view --job <the macos job> --log | grep -E "[0-9]+\\.[0-9]+s call"
#:
#: The readings behind the number, all of the SAME test,
#: `test_thursday_reel_legibility.py::test_the_thursday_reel_colophon_reads_wherever_it_scrolls_to`:
#:
#:     macos runner, run 32600776569, 2026-08-22    94.84s
#:     macos runner, run 32597907398, 2026-08-22    76.65s
#:     macos runner, run 32599388550, 2026-08-22    75.34s
#:     this Mac, full suite under -n auto           91.23s
#:
#: The Linux leg's slowest test is a different one and peaks at 31.3s, so the
#: Mac is the machine this has to be sized for.
SLOWEST_TEST_SECONDS = 94.84

#: How much room the deadline needs above that, as a multiplier.
#:
#: The point of a per-test deadline is a wedge, which is unbounded: a hung
#: subprocess or a deadlock never finishes, so any finite limit catches it. The
#: only thing the size buys is the cost of being WRONG, and being wrong here
#: turns a green suite red on a slow morning. So the multiplier is set by how far
#: the readings above already spread, which is 1.26x between the fastest and
#: slowest reading of one test on one machine class, and then given room well
#: past that.
#:
#: 4x also leaves the deadline comfortably inside the shortest job deadline that
#: runs pytest, which is what the check below holds it to. There is nothing in
#: the real distribution between 95s and the limit: the next slowest test is 68s,
#: so the limit sits in clear air rather than in the dense part of it (L172).
DEADLINE_HEADROOM = 4


def addopts() -> str:
    """The pytest options every run in this repo gets, read from pyproject."""
    found = re.search(r'^addopts = "([^"]*)"', PYPROJECT.read_text(encoding="utf-8"),
                      re.MULTILINE)
    assert found, (
        "pyproject.toml declares no addopts line any more, so every option this "
        "file checks is being read off nothing and the checks below would pass "
        "over an empty string (L98).")
    return found.group(1)


def configured_deadline() -> float:
    """The per-test deadline in seconds, or a failure saying there is none."""
    found = re.search(r"--timeout=([\d.]+)", addopts())
    assert found, (
        "pyproject.toml's addopts carries no --timeout, so a wedged test runs "
        f"until the JOB deadline kills the run and says only that the job ran "
        f"out of time, naming nothing: {addopts()!r}")
    return float(found.group(1))


def run_pytest(directory: Path, *arguments: str) -> subprocess.CompletedProcess:
    """A real pytest, on a throwaway suite, isolated from this repo's config.

    `-p no:cacheprovider` and an explicit rootdir keep it from reading or writing
    anything here, and the options under test are passed explicitly rather than
    inherited, so what these tests prove is the plugin's behaviour rather than
    this repo's configuration (which the checks above cover separately).
    """
    return subprocess.run(
        [sys.executable, "-m", "pytest", str(directory), "-p", "no:cacheprovider",
         "-c", str(directory / "pytest.ini"), *arguments],
        cwd=directory, capture_output=True, text=True, check=False)


def wedged_suite(tmp_path: Path, body: str) -> Path:
    """A suite with one ordinary test and one that never finishes."""
    (tmp_path / "pytest.ini").write_text("[pytest]\n", encoding="utf-8")
    (tmp_path / "test_wedge.py").write_text(textwrap.dedent(f"""
        import subprocess
        import time

        def test_that_finishes():
            assert True

        def test_that_wedges():
        {textwrap.indent(body, ' ' * 12)}
    """), encoding="utf-8")
    return tmp_path


# ── the deadline is configured, and configured sanely ─────────────────────────


def test_every_run_carries_a_per_test_deadline():
    """Set in addopts rather than on each command, for the reason the parallel
    runner is: the local targets, the CI legs and the reference-frame shards
    cannot disagree about it if there is only one place to say it (L41)."""
    assert configured_deadline() > 0, (
        "the per-test deadline is set to 0, which is how pytest-timeout is "
        "switched OFF, so the option is present and doing nothing.")


def test_the_deadline_sits_well_above_the_slowest_test_ever_measured():
    """A deadline under a real test's honest running time is worse than none.

    It converts a green suite into a red one on a slow morning, and the failure
    it prints is the same sentence a genuine wedge produces, so the two become
    indistinguishable exactly when it matters.
    """
    floor = SLOWEST_TEST_SECONDS * DEADLINE_HEADROOM

    assert configured_deadline() >= floor, (
        f"the per-test deadline is {configured_deadline():.0f}s and the slowest "
        f"test measured is {SLOWEST_TEST_SECONDS:.0f}s, which leaves only "
        f"{configured_deadline() / SLOWEST_TEST_SECONDS:.1f}x rather than the "
        f"{DEADLINE_HEADROOM}x this asks for. Either raise the deadline or, if "
        "a test really has become that slow, re-read the figure off a green "
        "run's --durations output and say so here.")


def test_the_deadline_is_the_method_that_lets_the_run_finish():
    """`thread` kills the worker, and takes the junit report with it.

    That report is not incidental: `tools/record_test_durations.py` reads it to
    decide whether a red run may still be recorded (#837), and pytest-timeout
    documents junit output as not functioning normally under the thread method.
    A silent switch to `thread` would leave that tool refusing every run it was
    changed to allow.
    """
    assert "--timeout-method=signal" in addopts(), (
        "the per-test deadline does not pin the signal method. It is the "
        "default on any platform with SIGALRM, which is both of ours, so this "
        "is pinning a default on purpose rather than changing behaviour: "
        f"nothing else would report a change to it. addopts: {addopts()!r}")


def test_the_plugin_the_deadline_needs_is_pinned():
    """`--timeout` is not a pytest option: without the plugin every single
    pytest invocation dies with `unrecognized arguments`, everywhere at once."""
    assert "--timeout" not in addopts() or re.search(
        r"^pytest-timeout==", REQUIREMENTS.read_text(encoding="utf-8"),
        re.MULTILINE), (
        "pyproject.toml's addopts uses --timeout and requirements.txt does not "
        "pin pytest-timeout, so every pytest run in every job fails to start.")


#: A repository script a job runs, which may run pytest without saying so.
SCRIPT = re.compile(r"\b((?:tools|tests)/[\w./-]+\.py)")


def runs_python_tests(body: str) -> bool:
    """Whether this job can reach pytest, directly or through a script it runs.

    Derived rather than listed (L41, L96). `guards.yml`'s `full` job runs the
    whole Python suite through `check_guards.py` and never writes the word
    pytest, so a filter on that word alone would silently exempt the job the
    rule most exists for; `record-durations` reaches it through
    `record_test_durations.py` the same way. So a script the job runs is read,
    and a script that mentions pytest at all counts.

    The script is read as CODE, not as text. `check_job_durations.py` parses
    pytest node ids out of a CI log and says so in three comments while running
    none, so a match on the raw file put the `due` gate back in exactly the set
    this change is removing it from: a guard satisfied by prose is
    indistinguishable from one that works (L103).
    """
    if "pytest" in body:
        return True
    for name in SCRIPT.findall(body):
        script = REPO_ROOT / name
        if not script.is_file():
            continue
        if "pytest" in python_without_comments(script.read_text(encoding="utf-8")):
            return True
    return False


def jobs_that_run_python_tests() -> list[tuple[str, str, int | None]]:
    """(workflow, job, deadline in seconds) for every job that reaches pytest."""
    found = []
    for workflow in sorted(WORKFLOWS.glob("*.yml")):
        text = yaml_without_comments(workflow.read_text(encoding="utf-8"))
        for job, body in _job_blocks(text):
            if not runs_python_tests(body):
                continue
            declared = re.search(r"timeout-minutes: (\d+)", body)
            found.append((workflow.name, job,
                          int(declared.group(1)) * 60 if declared else None))
    return found


def test_the_job_deadline_is_still_the_longer_of_the_two():
    """The job deadline is the backstop, so it has to outlast what it backs up.

    A per-test deadline longer than the job that runs it can never fire: the job
    is killed first, reporting only that it ran out of time, and the diagnostic
    added here goes quietly inert while still reading as configured (L170).

    Judged per JOB since #1345. It used to scan a whole workflow FILE and demand
    the rule of every deadline in it, including jobs that run no tests at all,
    so a Linux gate job reading one page of run history had to carry a fifteen
    minute deadline it will never use. The rule was right and its scope was not
    (L135).
    """
    deadlines = jobs_that_run_python_tests()

    assert deadlines, (
        "no job in any workflow reaches pytest, so #832's job deadlines have "
        "gone and there is no backstop behind the per-test one.")

    missing = [(name, job) for name, job, seconds in deadlines if seconds is None]
    assert not missing, (
        f"these jobs run tests and declare no timeout-minutes at all, so a "
        f"wedged run burns the platform default (L313): {missing}")

    too_short = [(name, job, seconds) for name, job, seconds in deadlines
                 if seconds is not None and seconds <= configured_deadline()]
    assert not too_short, (
        f"the per-test deadline is {configured_deadline():.0f}s and these jobs "
        f"are killed sooner, so it could never fire in them: {too_short}")


def test_the_job_that_runs_the_suite_without_naming_pytest_is_judged():
    """The positive control the scope change needs (#1345).

    `guards.yml`'s `full` job runs the whole Python suite through
    `check_guards.py` and the word pytest appears nowhere in it. A per-job
    filter on that word would exempt the job this rule most exists for, and
    nothing else here would notice.
    """
    judged = {(name, job) for name, job, _ in jobs_that_run_python_tests()}

    assert ("guards.yml", "full") in judged, (
        "the full guard sweep is no longer judged, so the job that runs every "
        f"registered guard's pytest invocation is exempt: {sorted(judged)}")
    assert ("record-durations.yml", "record") in judged, (
        "the durations recorder is no longer judged, and it runs the whole "
        "suite through record_test_durations.py")


def test_a_job_that_runs_no_tests_is_not_judged():
    """The other direction. A rule that judges every job in the file is what
    put a fifteen minute deadline on a job that reads one page of run history
    (#1259, #1345), and a scope that never says no is not a scope."""
    judged = {(name, job) for name, job, _ in jobs_that_run_python_tests()}

    assert ("guards.yml", "due") not in judged, (
        "the `due` gate is judged as a test job. It decides whether the sweep "
        "has anything to prove by reading run history, and it runs no tests.")
    assert ("ui.yml", "hand-check-reminder") not in judged, (
        "the hand check reminder is judged as a test job, and it posts a "
        "comment")


def test_a_job_reaching_pytest_only_through_a_script_is_still_judged():
    """The predicate itself, on text this test controls, so the positive
    controls above cannot be the only thing standing between this and a filter
    that reads the word alone."""
    assert runs_python_tests("      run: python tools/check_guards.py --changed")
    assert not runs_python_tests("      run: gh pr comment 1 --body hello")


def test_no_job_reaches_the_suite_through_make():
    """The hole this derivation would have. A job running `make test` reaches
    pytest through the Makefile, which is not a script this reads, so it would
    be judged as running none. No job does that today; the day one does, this
    says so rather than exempting it silently (L96).
    """
    using_make = []
    for workflow in sorted(WORKFLOWS.glob("*.yml")):
        text = yaml_without_comments(workflow.read_text(encoding="utf-8"))
        for job, body in _job_blocks(text):
            if re.search(r"^\s*(run:\s*)?make\s+\S", body, re.M):
                using_make.append((workflow.name, job))

    assert not using_make, (
        f"these jobs run make, and this file decides whether a job runs tests "
        f"by reading the scripts it names: {using_make}. Teach it to read the "
        f"Makefile recipe, or the job is judged as running no tests.")


# ── and it actually does what it is configured to do ──────────────────────────


def test_a_wedged_test_is_named_instead_of_taking_the_run_down(tmp_path: Path):
    """The whole point: the red line says WHICH test, and the run finishes.

    Run against a real pytest rather than asserted about the configuration,
    because everything above proves the option is written down and none of it
    proves the option does anything (L3).
    """
    finished = run_pytest(wedged_suite(tmp_path, "time.sleep(300)"),
                          "--timeout=2", "--timeout-method=signal", "-q")

    assert "test_that_wedges" in finished.stdout, (
        "the wedged test was not named in the output, which is the entire "
        f"reason for the deadline:\n{finished.stdout[-2000:]}")
    assert "Timeout" in finished.stdout, (
        f"nothing said the test was cut off by a deadline:\n{finished.stdout[-2000:]}")
    assert "1 passed" in finished.stdout, (
        "the run did not finish the other test, so the deadline took the whole "
        f"run down rather than one test:\n{finished.stdout[-2000:]}")


def test_a_test_wedged_inside_a_subprocess_is_cut_off_too(tmp_path: Path):
    """The case this suite actually has.

    The expensive tests here wedge inside ffmpeg, not inside `time.sleep`, and a
    deadline that cannot interrupt a blocking wait on a child process would be
    absent from every failure it was added for. SIGALRM does reach it, because
    the wait returns EINTR and Python runs the handler, but that is a claim
    worth a test rather than a paragraph.
    """
    finished = run_pytest(
        wedged_suite(tmp_path, 'subprocess.run(["sleep", "300"], check=False)'),
        "--timeout=2", "--timeout-method=signal", "-q")

    assert "test_that_wedges" in finished.stdout, (
        "a test blocked on a child process was not cut off or not named:\n"
        f"{finished.stdout[-2000:]}")
    assert "1 passed" in finished.stdout, (
        f"the run did not carry on past it:\n{finished.stdout[-2000:]}")


def test_the_deadline_still_fires_under_the_parallel_runner(tmp_path: Path):
    """Everything here runs under `-n auto`, which is a different process model.

    Each test runs in a worker rather than in the process pytest was started in,
    so a deadline that worked only in a single-process run would be absent from
    every real run this repo does.
    """
    finished = run_pytest(wedged_suite(tmp_path, "time.sleep(300)"),
                          "--timeout=2", "--timeout-method=signal",
                          "-n", "2", "--dist", "worksteal", "-q")

    assert "test_that_wedges" in finished.stdout, (
        "the deadline did not name the wedged test under xdist:\n"
        f"{finished.stdout[-2000:]}")
    assert "1 passed" in finished.stdout, (
        f"the other worker's test did not finish:\n{finished.stdout[-2000:]}")


def test_a_suite_with_no_deadline_really_does_hang_past_it(tmp_path: Path):
    """The positive control for every check above (L159).

    Each of those asserts that a deadline CUT something off. A fixture in which
    the test finished quickly on its own would satisfy all of them while proving
    nothing, so this runs the same wedged suite with the deadline switched off
    and requires it to still be running when a generous window has passed.
    """
    suite = wedged_suite(tmp_path, "time.sleep(300)")
    started = subprocess.Popen(
        [sys.executable, "-m", "pytest", str(suite), "-p", "no:cacheprovider",
         "-c", str(suite / "pytest.ini"), "--timeout=0", "-q"],
        cwd=suite, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        with_no_deadline = started.wait(timeout=15)
    except subprocess.TimeoutExpired:
        with_no_deadline = None
    finally:
        started.kill()
        started.wait()

    assert with_no_deadline is None, (
        "the wedged suite finished on its own within 15s with the deadline "
        "switched off, so it does not wedge and every check above could pass "
        "without a deadline doing anything.")
