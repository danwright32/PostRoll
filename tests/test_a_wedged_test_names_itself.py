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


def test_the_job_deadline_is_still_the_longer_of_the_two():
    """The job deadline is the backstop, so it has to outlast what it backs up.

    A per-test deadline longer than the job that runs it can never fire: the job
    is killed first, reporting only that it ran out of time, and the diagnostic
    added here goes quietly inert while still reading as configured (L170).
    """
    deadlines = []
    for workflow in sorted(WORKFLOWS.glob("*.yml")):
        text = workflow.read_text(encoding="utf-8")
        if "pytest" not in text:
            continue
        deadlines += [(workflow.name, int(minutes) * 60)
                      for minutes in re.findall(r"timeout-minutes: (\d+)", text)]

    assert deadlines, (
        "no workflow that runs pytest declares a timeout-minutes, so #832's job "
        "deadlines have gone and there is no backstop behind the per-test one.")

    too_short = [(name, seconds) for name, seconds in deadlines
                 if seconds <= configured_deadline()]
    assert not too_short, (
        f"the per-test deadline is {configured_deadline():.0f}s and these jobs "
        f"are killed sooner, so it could never fire in them: {too_short}")


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
