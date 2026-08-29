"""`make test` runs both suites and says how many tests each one ran (#932).

The target ran the Swift suite alone. Nothing in its name said so and it printed
no summary distinguishing the two, so a green `make test` read as the whole
suite passing while roughly 4000 Python tests had not been run. It misled twice,
once badly enough to be written into this project's own notes.

The remedy is a count, not a comment. A run that executed nothing exits green
from both runners, so the only thing that tells a full run from a half one is
what it reports having done (L98). Both legs therefore refuse a transcript with
no total in it, and refuse one whose total is zero, and neither refusal can be
answered by an exit code: `pytest -k nothing-matches` was measured here on
2026-08-28 printing "no tests ran in 2.10s", and xcodebuild reports TEST
SUCCEEDED for a spec that matched nothing (#644, and `classify_swift` already
refuses it for the guard sweep).

The transcript fragments below are the shapes the two runners actually emit,
measured rather than imagined (L48). The pytest lines are from real runs on
2026-08-28; the xcodebuild lines are the wording `tests/test_check_guards.py`
records from xcodebuild 16 and 26.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import pytest

from tools.suite_counts import (
    SuiteCountError,
    python_tests_run,
    swift_tests_run,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
MAKEFILE = REPO_ROOT / "Makefile"
TOOL = REPO_ROOT / "tools" / "suite_counts.py"


# ── The Swift leg ─────────────────────────────────────────────────────────────


#: What xcodebuild prints for a healthy run: a line per class, then the bundle,
#: then the grand total. The total is the LAST of them, which is the reading
#: `tools/check_guards.py` already relies on and this reuses rather than
#: spelling a second time (L41).
SWIFT_GREEN = (
    "Test Suite 'SentenceListTests' passed at 2026-08-28 20:11:04.001.\n"
    "\t Executed 12 tests, with 0 failures (0 unexpected) in 0.031 (0.033) seconds\n"
    "Test Suite 'PostRollTests.xctest' passed at 2026-08-28 20:11:04.002.\n"
    "\t Executed 927 tests, with 0 failures (0 unexpected) in 118.4 (118.9) seconds\n"
    "Test Suite 'All tests' passed at 2026-08-28 20:11:04.003.\n"
    "\t Executed 927 tests, with 0 failures (0 unexpected) in 118.4 (119.0) seconds\n"
    "** TEST SUCCEEDED **\n"
)


def test_the_swift_leg_reports_the_grand_total():
    assert swift_tests_run(SWIFT_GREEN) == 927


def test_a_swift_run_that_executed_nothing_is_refused():
    """The defect this closes on the Swift side: a spec matching nothing still
    exits green, so a leg that ran no tests looks exactly like one that ran
    them all (#644, L98)."""
    transcript = (
        "Test Suite 'All tests' passed at 2026-08-28 20:11:04.003.\n"
        "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\n"
        "** TEST SUCCEEDED **\n"
    )

    with pytest.raises(SuiteCountError, match="0 tests"):
        swift_tests_run(transcript)


def test_a_swift_transcript_with_no_total_at_all_is_refused():
    """Distinct from zero, and it has to be: this is the build failing before
    any test ran, and an absent total must not read as a count of nothing that
    somebody could then argue about (L11)."""
    with pytest.raises(SuiteCountError, match="never reported"):
        swift_tests_run("** BUILD FAILED **\n")


# ── The Python leg ────────────────────────────────────────────────────────────


def test_the_python_leg_counts_every_test_that_ran():
    """Measured on 2026-08-28: `pytest tests/test_phone_safe_area.py -q -n auto
    -m "not slow"` ended on exactly this line.

    A skip is a test that ran and reported. It is counted because the number
    exists to say the suite was reached, not to say everything passed."""
    assert python_tests_run("49 passed, 2 skipped in 3.93s\n") == 51


def test_a_failing_python_run_still_reports_what_it_ran():
    """The count is not a pass mark. `make test` fails on the runner's exit
    code; this number answers the separate question of whether the suite was
    reached at all, and it is most worth having on a red run."""
    assert python_tests_run("1 failed, 4011 passed in 130.02s (0:02:10)\n") == 4012


def test_a_python_run_where_nothing_ran_is_refused():
    """Measured on 2026-08-28: `pytest tests/ -q -n auto -k <no match>` printed
    this and exited 0. It is the whole shape of the defect."""
    with pytest.raises(SuiteCountError, match="no tests"):
        python_tests_run("bringing up nodes...\n\n\nno tests ran in 2.10s\n")


def test_deselected_tests_are_not_counted_as_run():
    """The fast subset deselects files by marker, and a deselected test is one
    that did NOT run. Counting it would let `make test-python-fast`'s number
    stand in for the full suite's, which is this issue in miniature."""
    assert python_tests_run("3168 passed, 40 deselected in 34.70s\n") == 3168


def test_warnings_are_not_counted_as_tests():
    assert python_tests_run("52 passed, 3 warnings in 1.64s\n") == 52


def test_the_total_is_read_from_the_summary_and_not_from_a_test_that_printed_one():
    """`-ra` prints a short summary section above the final line, and a test's
    own captured output can say anything at all. A scan over the whole
    transcript would be answered by either (L178), so the last summary line is
    what decides."""
    transcript = (
        "tests/test_reporting.py::test_wording\n"
        "    the report said '900 passed in 3.0s' which is not this run\n"
        "=========================== short test summary info ============================\n"
        "SKIPPED [1] tests/test_phone_safe_area.py:589: no template is exempt\n"
        "49 passed, 2 skipped in 3.93s\n"
    )

    assert python_tests_run(transcript) == 51


def test_a_python_transcript_with_no_summary_at_all_is_refused():
    with pytest.raises(SuiteCountError, match="never reported"):
        python_tests_run("Traceback (most recent call last):\nImportError\n")


# ── The tool refuses out loud, from the command line ──────────────────────────


def _run_tool(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(TOOL), *args],
                          capture_output=True, text=True, cwd=REPO_ROOT)


def test_the_tool_names_the_leg_and_the_count_it_read(tmp_path):
    log = tmp_path / "swift.log"
    log.write_text(SWIFT_GREEN, encoding="utf-8")

    result = _run_tool("swift", str(log))

    assert result.returncode == 0, result.stderr
    assert "927" in result.stdout, result.stdout
    assert "Swift" in result.stdout, result.stdout


def test_the_tool_exits_non_zero_when_a_leg_ran_nothing(tmp_path):
    """A guard is only real once it has been seen to refuse (L1), and the
    Makefile judges this by its exit code rather than by a line of its output
    (L184)."""
    log = tmp_path / "python.log"
    log.write_text("no tests ran in 2.10s\n", encoding="utf-8")

    result = _run_tool("python", str(log))

    assert result.returncode != 0, result.stdout
    assert "no tests" in (result.stdout + result.stderr)


def test_a_missing_log_is_refused_rather_than_read_as_an_empty_run(tmp_path):
    """The leg writes the transcript and then reads it back. If the write went
    somewhere else, an empty answer must not be reported as a suite that ran
    nothing: those need different fixes and only one of them is in the code
    (L11, L100)."""
    result = _run_tool("swift", str(tmp_path / "was-never-written.log"))

    assert result.returncode != 0
    assert "was-never-written.log" in (result.stdout + result.stderr)


# ── Running a leg: the count decides the verdict alongside the exit code ──────


def _run_leg(leg: str, *command: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(TOOL), "run", leg, "--", *command],
                          capture_output=True, text=True, cwd=REPO_ROOT)


def test_a_green_leg_reports_what_it_ran():
    result = _run_leg("python", "/bin/echo", "49 passed, 2 skipped in 3.93s")

    assert result.returncode == 0, result.stderr
    assert "Python: 51 tests" in result.stdout, result.stdout


def test_a_leg_that_ran_nothing_fails_even_though_the_command_exited_green():
    """The whole point, seen to refuse rather than described (L1).

    `/bin/echo` exits 0, exactly as `pytest -k <no match>` does. Judging the leg
    by that alone is what let a run of nothing report as a full suite."""
    result = _run_leg("python", "/bin/echo", "no tests ran in 2.10s")

    assert result.returncode != 0, (
        "the leg passed on a transcript saying nothing ran: "
        + result.stdout + result.stderr)
    assert "no tests" in (result.stdout + result.stderr)


def test_a_failing_leg_stays_failed_and_still_says_what_it_ran():
    """A count is not a pass mark. The runner's exit code decides whether the
    suite was green; the count decides whether it was reached at all, and the
    two must not be able to answer for each other (L53)."""
    result = _run_leg("python", "sh", "-c",
                      "echo '1 failed, 4011 passed in 130.02s'; exit 1")

    assert result.returncode != 0, result.stdout
    assert "Python: 4012 tests" in result.stdout, result.stdout


def test_the_commands_own_output_still_reaches_the_operator():
    """Counting the transcript must not swallow it. A suite run is two minutes
    of progress, and capturing it to read a number at the end would leave the
    operator watching a blank screen with no way to tell a slow run from a
    wedged one."""
    result = _run_leg("python", "sh", "-c",
                      "echo 'tests/test_thing.py ....'; echo '4 passed in 1.0s'")

    assert "tests/test_thing.py ...." in result.stdout, result.stdout


def test_a_command_that_cannot_start_is_named_as_that():
    """Distinct from a suite that ran nothing: one is a broken invocation and
    the other is a broken selection, and they need different fixes (L11)."""
    result = _run_leg("swift", "/nonexistent/xcodebuild-that-is-not-here")

    assert result.returncode != 0
    assert "xcodebuild-that-is-not-here" in (result.stdout + result.stderr)


# ── The Makefile actually wires the legs together ─────────────────────────────


def _target(name: str) -> str:
    """A make target's recipe, as one string.

    Raises rather than returning nothing, because a scan that has stopped
    matching would report a Makefile wiring every leg at the moment it can see
    no target at all (L98, L100)."""
    text = MAKEFILE.read_text(encoding="utf-8")
    header = re.search(rf"^{re.escape(name)}:(?!=)(.*)$", text, re.M)
    assert header, f"there is no {name} target in the Makefile"

    recipe: list[str] = []
    for line in text[header.end():].splitlines()[1:]:
        if line.startswith("\t"):
            recipe.append(line.strip())
        elif not line.strip() or line.lstrip().startswith("#"):
            continue
        else:
            break
    return header.group(1) + "\n" + "\n".join(recipe)


def test_make_test_runs_both_suites():
    """The whole issue: the name says every test, so it has to run every test."""
    recipe = _target("test")

    assert "test-swift" in recipe, (
        "`make test` does not run the Swift leg")
    assert "test-python" in recipe, (
        "`make test` does not run the Python leg, which is the state that made "
        "a green run read as a full suite while 4000 tests had not been run")


def test_the_swift_leg_still_skips_the_renderings():
    """Moved out of `test:` when it was split, and it has to move WITH the
    skip: the dumps clear the sheet folder and keep what was there as the
    baseline, so running them here consumes the comparison (#644)."""
    assert "$(REVIEW_TESTS)" in _target("test-swift")


@pytest.mark.parametrize("leg,kind", [("test-swift", "swift"), ("test-python", "python")])
def test_each_leg_reports_how_many_tests_it_ran(leg, kind):
    """A count is the only thing that tells a full run from a half one, so a
    leg that does not produce one is not finished (L98)."""
    recipe = _target(leg)

    assert "suite_counts.py" in recipe, (
        f"the {leg} leg never counts what it ran, so a run of nothing reports "
        "exactly like a full one")
    assert kind in recipe, f"the {leg} leg does not ask for the {kind} count"


def test_the_fast_python_loop_is_still_a_single_unfiltered_command():
    """The loop between edits stays as it was. `make test` getting slower is
    the point; the fast subset getting slower would be the cost (#413, #766)."""
    recipe = _target("test-python-fast")

    assert "not slow" in recipe, "the fast loop no longer deselects anything"
    assert "-n auto" in recipe, "the fast loop is serial again"
