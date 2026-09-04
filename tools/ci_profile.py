"""Where a macOS CI job's time goes, measured rather than reasoned about (#1247).

Answering #1103 meant a throwaway branch that added `-showBuildTimingSummary`
to each xcodebuild, printed what each scheme resolves to, and read the test
run's duration out of the result bundle. It produced the figures this milestone
is planned on and was then deleted, as a measuring instrument should be, so the
next person asking the same question builds it again.

This is that instrument, kept. Three things it insists on:

* Every report states the MACHINE. Every recorded figure that turned out to be
  wrong was wrong because it did not (#1243), and the reading nobody expected to
  need was `Swift suite on 3 workers, 3 cores`.

* A probe that fails is REPORTED, never fatal. The first dispatch died in the
  probe rather than in the work: `-showBuildSettings` for the `PostRollTests`
  scheme exits 64, because that scheme lists its target for the test action
  only, and the step ran under `bash -e`. The thing being measured is the work,
  so a tool that dies describing the machine has measured nothing.

* An absent reading raises rather than reading as zero. A build that printed no
  timing summary and a build that compiled nothing are different events, and the
  second one reads as a wonderful result (L98).
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from typing import Callable, Mapping


class ProbeFailed(Exception):
    """A reading could not be taken. Carried into the report, not raised at the
    person, wherever the work itself can still be measured."""


@dataclass(frozen=True)
class TaskTotal:
    """One row of a build timing summary."""
    tasks: int
    seconds: float


@dataclass(frozen=True)
class Machine:
    cores: int
    model: str
    memory_gb: int
    xcode: str
    os: str

    def line(self) -> str:
        return (f"{self.model}, {self.cores} cores, {self.memory_gb} GB, "
                f"macOS {self.os}, Xcode {self.xcode}")


#: A row of `-showBuildTimingSummary`. The name can carry spaces: `SwiftDriver
#: Compilation Requirements` is a real row, and a pattern written for one word
#: drops it silently, which under-reports the total this exists to attribute.
_ROW = re.compile(r"^([A-Za-z][\w ]*?) \((\d+) tasks?\) \| ([\d.]+) seconds$")

#: Which rows are COMPILING. Signing, copying and plist writing are not, and
#: folding them in would inflate the one number a decision gets made on.
COMPILE_TASKS = ("SwiftCompile", "SwiftDriver", "SwiftEmitModule", "CompileC",
                 "SwiftMergeGeneratedHeaders")


def task_totals(output: str) -> dict[str, TaskTotal]:
    """Every row of the build timing summary in `output`."""
    if "Build Timing Summary" not in output:
        raise ProbeFailed(
            "no build timing summary in this invocation's output, so nothing "
            "can be attributed to a task. Was -showBuildTimingSummary passed?")
    totals: dict[str, TaskTotal] = {}
    for line in output.split("Build Timing Summary", 1)[1].splitlines():
        row = _ROW.match(line.strip())
        if row:
            totals[row.group(1)] = TaskTotal(int(row.group(2)),
                                             float(row.group(3)))
    if not totals:
        raise ProbeFailed(
            "the build timing summary held no rows this could read, so the "
            "format has moved and every total below would be zero")
    return totals


def compile_seconds(totals: Mapping[str, TaskTotal]) -> float:
    return sum(total.seconds for name, total in totals.items()
               if name.split(" ")[0] in COMPILE_TASKS)


#: The project every scheme here lives in. Spelled once: a probe pointed at a
#: different project would report settings for something else entirely.
PROJECT = "PostRollApp/PostRoll.xcodeproj"

Runner = Callable[[list[str]], tuple[int, str]]


def run_command(args: list[str]) -> tuple[int, str]:
    """The real runner: exit code and combined output, never raising.

    Injected everywhere below so a test sets it once rather than reaching a
    real xcodebuild (L284).
    """
    done = subprocess.run(args, capture_output=True, text=True)
    return done.returncode, done.stdout + done.stderr


#: The settings worth reporting, and the reason each is here. Named rather than
#: dumped: `-showBuildSettings` prints hundreds of lines and a reader looking
#: for the two that explain a 152 second single task will not find them. That
#: 152s is a reading off the macos-26 runner's own build log, not a local one
#: (#1245): the whole point of this tool is that the two differ.
#:
#: A setting that is ABSENT is reported as absent rather than as unknown. The
#: two are different: SWIFT_COMPILATION_MODE is not emitted at all when nothing
#: sets it, which means the configuration's own default is in force, and that
#: is the answer to "why is this one SwiftCompile task".
REPORTED_SETTINGS = ("CONFIGURATION", "SWIFT_COMPILATION_MODE",
                     "SWIFT_OPTIMIZATION_LEVEL", "ONLY_ACTIVE_ARCH")


def scheme_settings(scheme: str, configuration: str | None = None,
                    run: Runner | None = None) -> dict[str, str]:
    """What one scheme resolves to, asking the build action first.

    The build action first because that is the one most schemes use, and a
    scheme that answers it must not be reported under an action it does not
    use. `PostRollTests` answers only the test action, and the exit 64 it gives
    the build action is what killed the first dispatch of this probe.

    `configuration` because a scheme resolves DIFFERENTLY per configuration and
    the job builds the app in Release: probing the scheme's default would report
    a Debug reading for a Release build, which is #1243's mistake in another
    costume.
    """
    if run is None:
        run = run_command
    pinned = ["-configuration", configuration] if configuration else []
    attempts: list[str] = []
    for action in ("build", "test"):
        code, output = run(["xcodebuild", "-project", PROJECT,
                            "-showBuildSettings", "-scheme", scheme,
                            *pinned, action])
        if code == 0:
            return _settings(output)
        attempts.append(f"{action} exited {code}")
    raise ProbeFailed(
        f"could not read the build settings for {scheme}"
        + (f" in {configuration}" if configuration else "") + ": "
        + ", then ".join(attempts)
        + ". The scheme resolves for neither action, so what it compiles with "
          "is unrecorded for this run")


def _settings(output: str) -> dict[str, str]:
    settings: dict[str, str] = {}
    for line in output.splitlines():
        if " = " in line:
            key, _, value = line.strip().partition(" = ")
            settings[key] = value
    return settings


def machine(run: Runner | None = None) -> Machine:
    """The machine this ran on, read off the machine."""
    if run is None:
        run = run_command
    def ask(args: list[str]) -> str:
        code, output = run(args)
        if code != 0:
            raise ProbeFailed(f"{' '.join(args)} exited {code}: {output.strip()}")
        return output.strip()

    banner = ask(["xcodebuild", "-version"])
    version = banner.splitlines()[0].replace("Xcode", "").strip()
    return Machine(
        cores=int(ask(["sysctl", "-n", "hw.ncpu"])),
        model=ask(["sysctl", "-n", "machdep.cpu.brand_string"]),
        memory_gb=int(int(ask(["sysctl", "-n", "hw.memsize"])) / (1024 ** 3)),
        xcode=version,
        os=ask(["sw_vers", "-productVersion"]),
    )


def suite_run_seconds(summary: Mapping[str, object]) -> tuple[float, int]:
    """How long the tests RAN, out of the result bundle's own summary.

    Not the step's wall clock minus the compile: a subtraction hides whatever
    else the step spent time on inside whichever half it is attributed to.
    """
    try:
        started = float(summary["startTime"])  # type: ignore[arg-type]
        finished = float(summary["finishTime"])  # type: ignore[arg-type]
    except (KeyError, TypeError, ValueError) as error:
        raise ProbeFailed(
            "the result bundle summary carries no start and finish time, so "
            f"the run's duration is unknown rather than zero: {error}") from error
    return finished - started, int(summary.get("totalTestCount", 0))


def report(machine: Machine,
           schemes: Mapping[str, dict[str, str] | ProbeFailed],
           builds: Mapping[str, Mapping[str, TaskTotal]],
           test_seconds: float | None,
           tests: int | None) -> str:
    """The whole reading, as Markdown for a job summary."""
    lines = ["## Where this job's time went",
             "",
             f"**Machine:** {machine.line()}",
             ""]

    if schemes:
        lines += ["### What each scheme resolves to", ""]
        for name, settings in schemes.items():
            if isinstance(settings, ProbeFailed):
                lines.append(f"* `{name}`: NOT READ, {settings}")
            else:
                shown = ", ".join(
                    f"{key}={settings[key]}" if key in settings
                    else f"{key} not set"
                    for key in REPORTED_SETTINGS)
                lines.append(f"* `{name}`: {shown}")
        lines.append("")

    for step, totals in builds.items():
        compiling = compile_seconds(totals)
        lines += [f"### {step}", "",
                  f"{compiling:.1f}s compiling, across "
                  f"{sum(t.tasks for name, t in totals.items() if name.split(' ')[0] in COMPILE_TASKS)}"
                  " tasks", "",
                  "| task | tasks | seconds |", "| --- | ---: | ---: |"]
        for name, total in sorted(totals.items(),
                                  key=lambda item: -item[1].seconds)[:12]:
            lines.append(f"| {name} | {total.tasks} | {total.seconds:.3f} |")
        lines.append("")

    if test_seconds is not None:
        counted = f"{tests:,} tests" if tests else "an unrecorded number of tests"
        lines += ["### The test run itself", "",
                  f"{test_seconds:.1f}s running {counted} on "
                  f"{machine.cores} workers, read out of the result bundle "
                  "rather than by subtracting the compile from the step", ""]

    return "\n".join(lines)


# ── the command line the workflow drives ─────────────────────────────────────

USAGE = ("usage: ci_profile.py [--build NAME=PATH]... [--scheme NAME[=CONFIGURATION]]... "
         "[--result-bundle PATH]")


def bundle_summary(bundle: str, run: Runner | None = None) -> Mapping[str, object]:
    if run is None:
        run = run_command
    import json

    code, output = run(["xcrun", "xcresulttool", "get", "test-results",
                        "summary", "--path", bundle, "--format", "json"])
    if code != 0:
        raise ProbeFailed(f"xcresulttool exited {code} reading {bundle}: "
                          f"{output.strip()[:200]}")
    try:
        return json.loads(output)
    except ValueError as error:
        raise ProbeFailed(
            f"xcresulttool printed something that is not JSON for {bundle}"
        ) from error


def main(argv: list[str], run: Runner | None = None) -> int:
    if run is None:
        run = run_command
    from pathlib import Path

    builds: dict[str, str] = {}
    schemes: list[tuple[str, str | None]] = []
    bundle: str | None = None
    rest = list(argv)
    while rest:
        word = rest.pop(0)
        if word == "--build" and rest:
            name, _, path = rest.pop(0).partition("=")
            builds[name] = path
        elif word == "--scheme" and rest:
            name, _, configuration = rest.pop(0).partition("=")
            schemes.append((name, configuration or None))
        elif word == "--result-bundle" and rest:
            bundle = rest.pop(0)
        else:
            print(USAGE)
            return 2

    read_machine = machine(run=run)

    resolved: dict[str, dict[str, str] | ProbeFailed] = {}
    for scheme, configuration in schemes:
        label = f"{scheme} ({configuration})" if configuration else scheme
        try:
            resolved[label] = scheme_settings(scheme, configuration, run=run)
        except ProbeFailed as failure:
            resolved[label] = failure

    # A log that is missing is a NAMED gap. Skipping it silently would leave a
    # report that reads as a complete account of a job with a step in it that
    # nobody measured (L98).
    totals: dict[str, Mapping[str, TaskTotal]] = {}
    missing: list[str] = []
    for name, path in builds.items():
        try:
            totals[name] = task_totals(Path(path).read_text())
        except (OSError, ProbeFailed) as failure:
            missing.append(f"{name}: {failure}")

    seconds: float | None = None
    tests: int | None = None
    if bundle is not None:
        try:
            seconds, tests = suite_run_seconds(bundle_summary(bundle, run=run))
        except ProbeFailed as failure:
            missing.append(f"the test run: {failure}")

    text = report(read_machine, resolved, totals, seconds, tests)
    if missing:
        text += "\n### Not measured\n\n" + "\n".join(f"* {line}" for line in missing)
    print(text)
    return 0


if __name__ == "__main__":  # pragma: no cover
    import sys

    sys.exit(main(sys.argv[1:]))
