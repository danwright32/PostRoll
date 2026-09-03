"""#1247: keep the instrument that answered "where does the time go".

Answering #1103 meant building a throwaway branch that added
`-showBuildTimingSummary` to each xcodebuild, printed what each scheme resolves
to, and read the test run's duration out of the result bundle. It produced the
numbers this milestone is planned on, and it was deleted, as a measuring
instrument should be. The next person asking builds it again.

It also took two dispatches to get right, and the first one died in the PROBE
rather than in the work: `-showBuildSettings` for the `PostRollTests` scheme
exits 64, because that scheme lists its target for the test action only and the
build action therefore has no destinations, and the step ran under `bash -e`.

The reading that mattered most was the one nobody expected to need: `Swift suite
on 3 workers, 3 cores`. Every recorded figure that turned out to be wrong was
wrong because it did not say which machine it came from (#1243), so everything
here states the machine.

The samples are real: both timing summaries are the ones dispatch run
33760431737 printed, kept verbatim under tests/fixtures/ci_profile.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools.ci_profile import (
    PROJECT,
    main,
    ProbeFailed,
    Machine,
    compile_seconds,
    machine,
    report,
    scheme_settings,
    task_totals,
    suite_run_seconds,
)


FIXTURES = Path(__file__).resolve().parent / "fixtures" / "ci_profile"
APP_BUILD = (FIXTURES / "build_timing_summary_build_the_app.txt").read_text()
GUI_BUILD = (FIXTURES / "build_timing_summary_gui_tests.txt").read_text()


# ── reading the per task attribution ─────────────────────────────────────────

def test_it_reads_the_real_summary_the_app_build_printed() -> None:
    totals = task_totals(APP_BUILD)

    # The finding #1246 rests on: one whole module SwiftCompile task, which no
    # number of cores can split.
    assert totals["SwiftCompile"].tasks == 1
    assert totals["SwiftCompile"].seconds == pytest.approx(152.417)
    assert totals["Ld"].seconds == pytest.approx(1.820)


def test_a_task_name_with_spaces_in_it_is_not_dropped() -> None:
    """`SwiftDriver Compilation Requirements` is a real row in that summary, and
    a pattern written for one word silently loses it. A parser that drops rows
    under-reports the total it exists to attribute (L215)."""
    assert "SwiftDriver Compilation Requirements" in task_totals(APP_BUILD)


def test_the_plural_form_is_read_too() -> None:
    """One task says `(1 task)` and several say `(4 tasks)`. Both appear in the
    same real summary."""
    totals = task_totals(GUI_BUILD)
    assert totals["SwiftCompile"].tasks == 13
    assert totals["SwiftCompile"].seconds == pytest.approx(105.380)


def test_output_with_no_summary_in_it_raises_rather_than_reporting_zero() -> None:
    """A build that printed no summary and a build that compiled nothing are
    different things, and the second reads as a wonderful result (L98)."""
    with pytest.raises(ProbeFailed) as raised:
        task_totals("** BUILD SUCCEEDED **\n")
    assert "no build timing summary" in str(raised.value).lower()


def test_the_compile_total_is_the_compiling_rows_not_every_row() -> None:
    """Signing, copying and plist writing are not compiling, and folding them in
    would inflate the one number the next decision is made on."""
    assert compile_seconds(task_totals(APP_BUILD)) == pytest.approx(
        152.417 + 4.844 + 0.007 + 0.002, abs=0.01)


# ── the probe that killed the first dispatch ─────────────────────────────────

def _runner(replies: dict[tuple[str, ...], tuple[int, str]]):
    """A stand-in xcodebuild that answers recorded (exit code, output) pairs."""
    seen: list[tuple[str, ...]] = []

    def run(args: list[str]) -> tuple[int, str]:
        seen.append(tuple(args))
        return replies.get(tuple(args), (127, "no reply recorded for this call"))

    run.seen = seen  # type: ignore[attr-defined]
    return run


def _probe(action: str) -> tuple[str, ...]:
    """The real command, spelled from the tool's own constant rather than
    retyped here: a fixture that agrees only with itself proves the parse, not
    the call (L52)."""
    return ("xcodebuild", "-project", PROJECT, "-showBuildSettings",
            "-scheme", "PostRollTests", action)


BUILD_PROBE = _probe("build")
TEST_PROBE = _probe("test")
SETTINGS = (
    "Build settings for action test and target PostRollTests:\n"
    "    CONFIGURATION = Debug\n"
    "    SWIFT_COMPILATION_MODE = wholemodule\n"
)


def test_a_test_only_scheme_is_probed_for_its_test_action() -> None:
    """The first dispatch died here. `PostRollTests` lists its target for the
    test action only, so the build action has no destinations and xcodebuild
    exits 64. Under `bash -e` that ended the run before any work started."""
    run = _runner({BUILD_PROBE: (64, "does not contain any buildable targets"),
                   TEST_PROBE: (0, SETTINGS)})

    settings = scheme_settings("PostRollTests", run=run)

    assert settings["CONFIGURATION"] == "Debug"
    assert settings["SWIFT_COMPILATION_MODE"] == "wholemodule"
    assert run.seen == [BUILD_PROBE, TEST_PROBE], (
        "the build action has to be asked FIRST, or a scheme that answers it "
        "is reported under an action it does not use")


def test_a_scheme_that_answers_the_build_action_is_not_asked_twice() -> None:
    run = _runner({BUILD_PROBE: (0, SETTINGS)})
    scheme_settings("PostRollTests", run=run)
    assert len(run.seen) == 1


def test_a_scheme_that_answers_neither_action_is_a_named_failure() -> None:
    """Not a silent empty dict. A probe that failed and a scheme with no
    settings look identical to every caller downstream (L98), and the whole
    point of this tool is to report what a machine actually resolved."""
    run = _runner({BUILD_PROBE: (64, "no buildable targets"),
                   TEST_PROBE: (70, "the destination is not valid")})

    with pytest.raises(ProbeFailed) as raised:
        scheme_settings("PostRollTests", run=run)

    detail = str(raised.value)
    assert "PostRollTests" in detail
    # Both attempts, because a message naming only the second sends the reader
    # to the wrong action (L11).
    assert "64" in detail and "70" in detail


def test_a_probe_failure_does_not_end_the_run() -> None:
    """It is a PROBE. The work it precedes is the thing being measured, and a
    tool that dies describing the machine has measured nothing at all."""
    lines = report(machine=Machine(cores=3, model="Apple M1 (Virtual)",
                                  memory_gb=7, xcode="26.6", os="26.0"),
                   schemes={"PostRollTests": ProbeFailed("exit 64, then 70")},
                   builds={}, test_seconds=None, tests=None)

    assert "exit 64, then 70" in lines
    assert "PostRollTests" in lines


# ── the machine, which is the reading that mattered ──────────────────────────

def test_the_machine_is_read_from_the_machine() -> None:
    replies = {
        ("sysctl", "-n", "hw.ncpu"): (0, "3\n"),
        ("sysctl", "-n", "hw.memsize"): (0, "7516192768\n"),
        ("sysctl", "-n", "machdep.cpu.brand_string"): (0, "Apple M1 (Virtual)\n"),
        ("sw_vers", "-productVersion"): (0, "26.0\n"),
        ("xcodebuild", "-version"): (0, "Xcode 26.6\nBuild version 17F113\n"),
    }

    def run(args: list[str]) -> tuple[int, str]:
        return replies[tuple(args)]

    read = machine(run=run)

    assert read.cores == 3
    assert read.memory_gb == 7
    assert read.xcode == "26.6"
    assert read.model == "Apple M1 (Virtual)"


def test_every_report_states_the_machine() -> None:
    """#1243 in one line: a figure without the machine it came from is what
    aimed a whole milestone at the wrong half of a job."""
    lines = report(machine=Machine(cores=3, model="Apple M1 (Virtual)",
                                   memory_gb=7, xcode="26.6", os="26.0"),
                   schemes={}, builds={"Build the app": task_totals(APP_BUILD)},
                   test_seconds=212.162, tests=2895)

    assert "3 cores" in lines
    assert "Apple M1 (Virtual)" in lines
    assert "152.4" in lines, "the whole module compile is not attributed"


def test_the_test_step_is_split_rather_than_subtracted() -> None:
    """#1250 asks how much of the test step is compiling. The compile side comes
    from that invocation's OWN timing summary and the run side from the result
    bundle, so neither is one number minus another and a step that spends time
    somewhere else shows up as the difference rather than hiding in it."""
    lines = report(machine=Machine(cores=3, model="Apple M1 (Virtual)",
                                   memory_gb=7, xcode="26.6", os="26.0"),
                   schemes={},
                   builds={"Run the Swift unit tests": task_totals(GUI_BUILD)},
                   test_seconds=212.162, tests=2895)

    assert "212.2" in lines
    assert "2,895" in lines


def test_the_run_duration_comes_out_of_the_result_bundle() -> None:
    summary = {"startTime": 1788452218.257, "finishTime": 1788452341.614,
               "totalTestCount": 2892}
    seconds, tests = suite_run_seconds(summary)
    assert seconds == pytest.approx(123.357, abs=0.001)
    assert tests == 2892


def test_a_bundle_summary_missing_its_times_is_not_a_zero_second_run() -> None:
    with pytest.raises(ProbeFailed):
        suite_run_seconds({"totalTestCount": 2892})


# ── the command line the workflow drives ─────────────────────────────────────

MACHINE_REPLIES = {
    ("sysctl", "-n", "hw.ncpu"): (0, "3\n"),
    ("sysctl", "-n", "hw.memsize"): (0, "7516192768\n"),
    ("sysctl", "-n", "machdep.cpu.brand_string"): (0, "Apple M1 (Virtual)\n"),
    ("sw_vers", "-productVersion"): (0, "26.0\n"),
    ("xcodebuild", "-version"): (0, "Xcode 26.6\nBuild version 17F113\n"),
}


def test_a_missing_build_log_is_named_rather_than_skipped(tmp_path, capsys) -> None:
    """A step nobody measured must not be indistinguishable from a step that
    cost nothing. The report is an ACCOUNT of a job, and a silently dropped
    section reads as a complete one (L98)."""
    def run(args: list[str]) -> tuple[int, str]:
        return MACHINE_REPLIES[tuple(args)]

    code = main(["--build", f"Build the app={tmp_path / 'never-written.log'}"],
                run=run)

    printed = capsys.readouterr().out
    assert code == 0, "a missing reading must not stop the rest being reported"
    assert "Not measured" in printed
    assert "Build the app" in printed


def test_it_reports_the_real_summary_end_to_end(tmp_path, capsys) -> None:
    log = tmp_path / "build.log"
    log.write_text(APP_BUILD)

    def run(args: list[str]) -> tuple[int, str]:
        return MACHINE_REPLIES[tuple(args)]

    assert main(["--build", f"Build the app={log}"], run=run) == 0

    printed = capsys.readouterr().out
    assert "3 cores" in printed
    assert "152.417" in printed


# ── the configuration a scheme is probed IN ──────────────────────────────────

def test_the_probe_asks_about_the_configuration_the_job_builds() -> None:
    """A scheme resolves differently per configuration, and the job builds the
    app in Release. Probing the scheme's default would report a Debug reading
    for a Release build, which is #1243's mistake in another costume."""
    probe = ("xcodebuild", "-project", PROJECT, "-showBuildSettings",
             "-scheme", "PostRoll", "-configuration", "Release", "build")
    run = _runner({probe: (0, "    CONFIGURATION = Release\n")})

    assert scheme_settings("PostRoll", "Release", run=run)["CONFIGURATION"] == "Release"


def test_a_setting_nothing_sets_is_reported_as_absent_not_unknown() -> None:
    """Absent is an ANSWER here. `SWIFT_COMPILATION_MODE` is not emitted at all
    when nothing sets it, which means the configuration's own default is in
    force, and that is what explains a single whole-module SwiftCompile task.
    Rendering it as "unknown" would read as a failed probe (L11)."""
    lines = report(machine=Machine(cores=3, model="Apple M1 (Virtual)",
                                   memory_gb=7, xcode="26.6", os="26.0"),
                   schemes={"PostRoll (Release)": {"CONFIGURATION": "Release"}},
                   builds={}, test_seconds=None, tests=None)

    assert "SWIFT_COMPILATION_MODE not set" in lines
    assert "unknown" not in lines


def test_the_report_says_which_configuration_a_scheme_was_probed_in(capsys) -> None:
    probe = ("xcodebuild", "-project", PROJECT, "-showBuildSettings",
             "-scheme", "PostRoll", "-configuration", "Release", "build")
    replies = dict(MACHINE_REPLIES)
    replies[probe] = (0, "    CONFIGURATION = Release\n")

    def run(args: list[str]) -> tuple[int, str]:
        return replies[tuple(args)]

    assert main(["--scheme", "PostRoll=Release"], run=run) == 0
    assert "PostRoll (Release)" in capsys.readouterr().out
