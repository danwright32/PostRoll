"""The duration recorder may be run past its own guard, and past nothing else (#837).

`tools/record_test_durations.py` refuses to write from a suite that exited
non-zero, and that refusal is right in general: a file that failed did not run to
completion, so its cost is whatever it got through, and recording that sets a
threshold from a broken run.

It was too broad in exactly one case, which is the case that matters. The guards
that READ the record all live in `tests/test_fast_subset_stays_honest.py`, and
when one of them goes red it names `make record-test-durations` as the remedy.
That remedy was blocked by the failure it exists to clear, so the only way
through was a hand-written `--deselect` that appeared in no message and no
document (L111: a remedy nobody can run is the same as no remedy).

So a failure confined to that one file no longer blocks the write. Everything
else still does, and the tests below are mostly about the "everything else",
because a tolerance that is easy to widen by accident is how the refusal stops
meaning anything.

Two shapes drive that, and both were measured against a real pytest run under
`-n 2` rather than assumed, because junit reports them differently from what the
non-parallel run produces:

  * under xdist there is no `file` attribute on a testcase at all, only
    `classname` and `name`, so the file a test belongs to has to be read off the
    dotted classname;
  * a file that failed to IMPORT is reported with an EMPTY classname and the
    module path in `name` instead, which is why a collection error can never
    match the tolerated classname and refuses on the ordinary path.

That second one is not merely a parsing detail. A guard file that failed to
import did not run, so it contributed no timings, and tolerating it would drop a
file out of the record while reporting success.

Nothing here runs the real suite: every test drives the decision against a
hand-written report, so the tool's behaviour on a red run is provable in
milliseconds rather than in minutes (L2).
"""

from __future__ import annotations

import ast
import re
import subprocess
import sys
from pathlib import Path

import pytest

import json
from tools import record_test_durations
from tools.record_test_durations import (
    ADD_PASSES,
    OWN_GUARD_CLASSNAME,
    blocking_failures,
    failed_cases,
    measure,
    measure_repeatedly,
)

REPO_ROOT = Path(__file__).resolve().parent.parent

#: A duration line in the shape the tool's own regex reads, so a faked run
#: measures something and an empty record cannot be what makes a test pass.
DURATIONS = (
    "0.50s call     tests/test_something.py::test_a\n"
    "0.25s setup    tests/test_something.py::test_a\n"
    "2.00s call     tests/test_other.py::test_b\n"
)


def report(*cases: str) -> str:
    """A junit report holding exactly the given testcase elements."""
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<testsuites name="pytest tests"><testsuite name="pytest">'
        + "".join(cases)
        + "</testsuite></testsuites>"
    )


def failed(classname: str, name: str) -> str:
    """A testcase that FAILED: an assertion went red inside the test body."""
    return (f'<testcase classname="{classname}" name="{name}" time="0.1">'
            '<failure message="assert False">boom</failure></testcase>')


def errored(classname: str, name: str) -> str:
    """A testcase that ERRORED: it did not get as far as running."""
    return (f'<testcase classname="{classname}" name="{name}" time="0.0">'
            '<error message="failed on setup">boom</error></testcase>')


def passed(classname: str, name: str) -> str:
    return f'<testcase classname="{classname}" name="{name}" time="0.1" />'


#: What a file that could not be imported looks like: no classname at all, and
#: the module path in `name`. Measured from a real run, not invented.
def uncollectable(module: str) -> str:
    return (f'<testcase classname="" name="{module}" time="0.0">'
            '<error message="collection failure">boom</error></testcase>')


@pytest.fixture
def run(monkeypatch):
    """Stand in for the suite, writing whatever report the test asks for.

    The fake reads the report path out of the command the tool built, so a tool
    that stopped asking pytest for a report fails here rather than silently
    being handed one it never requested.
    """
    seen: dict[str, list[str]] = {}

    def fake(returncode: int, xml: str | None, stdout: str = DURATIONS):
        def run_it(command, **kwargs):
            seen["command"] = list(command)
            paths = [arg.split("=", 1)[1] for arg in command
                     if arg.startswith("--junit-xml=")]
            assert paths, (
                "the tool did not ask pytest for a junit report, so it has no "
                f"way to know WHICH tests failed: {command}")
            if xml is not None:
                Path(paths[0]).write_text(xml, encoding="utf-8")
            return subprocess.CompletedProcess(command, returncode, stdout, "")

        monkeypatch.setattr(subprocess, "run", run_it)
        return seen

    return fake


def test_a_clean_run_records_what_it_measured(run):
    """The ordinary path, unchanged: exit zero, timings written."""
    run(0, None)
    assert measure() == {"test_something.py": 0.75, "test_other.py": 2.0}


def test_a_failure_only_in_the_records_own_guard_still_records(run):
    """The whole point of #837.

    This is the state the tool is reached in: the record has drifted, the guard
    about the record says so, and the guard's own message names this tool.
    """
    run(1, report(failed(OWN_GUARD_CLASSNAME, "test_the_record_still_covers_the_suite"),
                  passed("tests.test_something", "test_a")))

    assert measure() == {"test_something.py": 0.75, "test_other.py": 2.0}


def test_it_says_out_loud_which_failures_it_recorded_past(run, capsys):
    """Recording past a red run is not something to do quietly (L11).

    A tolerated failure is still a failure somebody has to look at, and a tool
    that swallows it reads exactly like a tool that ran against a green suite.
    """
    run(1, report(failed(OWN_GUARD_CLASSNAME, "test_the_record_still_covers_the_suite")))
    measure()

    said = capsys.readouterr().out
    assert "test_the_record_still_covers_the_suite" in said, (
        f"the tolerated failure was not named in what the tool said: {said!r}")


def test_a_failure_anywhere_else_still_refuses_and_names_it(run):
    """The refusal that was always right, kept."""
    run(1, report(failed("tests.test_render_clip_reel", "test_the_reel_renders"),
                  passed(OWN_GUARD_CLASSNAME, "test_the_record_still_covers_the_suite")))

    with pytest.raises(SystemExit) as refusal:
        measure()

    assert "test_the_reel_renders" in str(refusal.value), (
        f"the refusal did not name what failed: {refusal.value}")


def test_a_failure_in_the_guard_file_beside_one_elsewhere_still_refuses(run):
    """The tolerance is not a licence for whatever else was red at the time.

    The guard about the record goes red on exactly the day somebody is changing
    the suite, so a real breakage sitting beside it is the likely case, not the
    exotic one.
    """
    run(1, report(failed(OWN_GUARD_CLASSNAME, "test_the_record_still_covers_the_suite"),
                  failed("tests.test_render_clip_reel", "test_the_reel_renders")))

    with pytest.raises(SystemExit) as refusal:
        measure()

    assert "test_the_reel_renders" in str(refusal.value)


def test_a_guard_file_that_failed_to_import_refuses(run):
    """A file that never imported never ran, so it measured nothing.

    Tolerating this would take the guard file out of the record entirely while
    reporting a successful write, and absent is read as unmeasured everywhere
    downstream.
    """
    run(1, report(uncollectable(OWN_GUARD_CLASSNAME),
                  passed("tests.test_something", "test_a")))

    with pytest.raises(SystemExit) as refusal:
        measure()

    assert OWN_GUARD_CLASSNAME in str(refusal.value)


def test_an_error_inside_the_guard_file_refuses(run):
    """An ERROR is not an assertion about the record going red.

    The tolerated case is a guard that ran and reported drift. A guard that blew
    up in its fixture is a broken guard, and its verdict about the record is not
    available at all.
    """
    run(1, report(errored(OWN_GUARD_CLASSNAME, "test_the_record_still_covers_the_suite")))

    with pytest.raises(SystemExit) as refusal:
        measure()

    assert "test_the_record_still_covers_the_suite" in str(refusal.value)


def test_a_non_zero_exit_naming_no_failing_test_refuses(run):
    """An empty answer is not a clean answer (L98).

    pytest exits non-zero for reasons that put nothing in the report at all: a
    usage error, an internal error, a run that collected nothing. Reading that
    as "no blocking failures" would turn every one of them into a silent write.
    """
    run(4, report(passed("tests.test_something", "test_a")))

    with pytest.raises(SystemExit) as refusal:
        measure()

    assert "4" in str(refusal.value)


def test_a_report_that_was_never_written_refuses(run):
    """The run died before pytest could write its report."""
    run(1, None)

    with pytest.raises(SystemExit) as refusal:
        measure()

    assert "report" in str(refusal.value).lower()


def test_a_report_that_is_not_readable_xml_refuses(run):
    """Truncated, half-written, or not XML at all."""
    run(1, "<testsuites><testsuite>truncated")

    with pytest.raises(SystemExit) as refusal:
        measure()

    assert "report" in str(refusal.value).lower()


def test_a_run_that_measured_nothing_still_refuses(run):
    """Unchanged, and it has to survive the new tolerance.

    A green run whose durations could not be parsed would write a record saying
    every file is free, which is the failure the check has always been about.
    """
    run(0, None, stdout="no durations here\n")

    with pytest.raises(SystemExit) as refusal:
        measure()

    assert "measured nothing" in str(refusal.value)


def test_a_tolerated_run_that_measured_nothing_refuses_too(run):
    """The tolerance may not reach the emptiness check.

    Two guards, two reasons, and the new one must not answer for the old one
    (L11).
    """
    run(1, report(failed(OWN_GUARD_CLASSNAME, "test_the_record_still_covers_the_suite")),
        stdout="no durations here\n")

    with pytest.raises(SystemExit) as refusal:
        measure()

    assert "measured nothing" in str(refusal.value)


def test_blocking_failures_reads_both_a_failure_and_an_error(tmp_path: Path):
    """The parse itself, against the two shapes junit uses for going red."""
    path = tmp_path / "report.xml"
    path.write_text(report(failed("tests.test_a", "test_one"),
                           errored("tests.test_b", "test_two"),
                           passed("tests.test_c", "test_three")), encoding="utf-8")

    assert blocking_failures(path) == ["tests.test_a::test_one",
                                       "tests.test_b::test_two"]


def test_the_tolerated_classname_names_a_file_that_reads_the_record():
    """The tolerance is scoped by a string, so it can go stale silently (L96).

    If that file is renamed the constant goes on naming nothing, the tolerance
    quietly covers no test at all, and the tool is back to refusing the one case
    it was changed to allow, with nothing reporting why.
    """
    guard = REPO_ROOT / Path(*OWN_GUARD_CLASSNAME.split(".")).with_suffix(".py")

    assert guard.is_file(), (
        f"{OWN_GUARD_CLASSNAME} does not name a test file on disk: expected "
        f"{guard.relative_to(REPO_ROOT)}. The recorder tolerates failures in "
        "that file alone, so a rename leaves the tolerance covering nothing.")
    assert "file_durations" in guard.read_text(encoding="utf-8"), (
        f"{guard.name} no longer reads the duration record, so it is not the "
        "file whose failures a re-recording is meant to clear.")


def test_the_classname_is_what_a_real_pytest_run_reports_for_that_file(tmp_path: Path):
    """Derived rather than trusted: ask pytest what it calls that file.

    The tolerance turns on a dotted name this repo assembles by hand. Nothing
    else would notice if pytest's junit writer changed how it spells it, and the
    tolerance would then match no test while every check above still passed
    against reports this file wrote itself (L52).
    """
    path = tmp_path / "report.xml"
    subprocess.run(
        [sys.executable, "-m", "pytest",
         "tests/test_fast_subset_stays_honest.py::test_the_coverage_check_is_measuring_something",
         "-p", "no:cacheprovider", f"--junit-xml={path}", "-q"],
        cwd=REPO_ROOT, capture_output=True, text=True, check=False)

    import xml.etree.ElementTree as ElementTree
    names = {case.get("classname")
             for case in ElementTree.parse(path).getroot().iter("testcase")}

    assert OWN_GUARD_CLASSNAME in names, (
        f"pytest reports that file as {names}, not as {OWN_GUARD_CLASSNAME!r}, "
        "so the recorder's tolerance matches nothing it will ever see.")


def test_every_remedy_the_record_guards_name_is_a_make_target_that_exists():
    """A remedy is only a remedy while the command it names still runs (L111).

    The guards about the record each end by telling whoever hit them what to
    run. Those sentences were written at four different times and named the tool
    three different ways, and nothing was checking any of them, so a renamed
    target would have left every one of these guards ending in an instruction
    that fails (L153).

    Read through `ast` rather than by pattern over the text, for two reasons a
    regex version got wrong when it was tried. Assertion messages are long
    enough to wrap, and a remedy split across two string literals reads to any
    regex as a remedy naming nothing. And a trigger loose enough to survive
    rewording also matches the PROSE in the docstrings, which talks about
    re-measuring without offering a command and correctly should not have to.
    """
    guard = REPO_ROOT / "tests" / "test_fast_subset_stays_honest.py"

    targets = set(re.findall(r"^([a-zA-Z0-9_-]+):",
                             (REPO_ROOT / "Makefile").read_text(encoding="utf-8"),
                             re.MULTILINE))

    # The guards whose drift is cleared by re-recording, named rather than
    # inferred. A guard that merely READS the record is not necessarily one of
    # these: `test_every_expensive_file_is_marked_slow` reads it too and its
    # remedy is to add a marker, so deriving the set from what a test touches
    # would demand the wrong command from half of them.
    #
    # A hand-kept list checks only what it lists (L96), and the gap left here is
    # a NEW drift guard added with no remedy, which nothing below would notice.
    # What it does close is the direction that actually went wrong: a name here
    # that no longer exists fails, so a guard cannot be renamed, removed, or
    # quietly stripped of its remedy without this saying so.
    MUST_OFFER_A_REMEDY = {
        "test_the_measurement_actually_found_some_expensive_files",
        "test_the_record_names_only_files_that_still_exist",
        "test_the_record_still_covers_the_suite",
        "test_the_boundary_between_expensive_and_ordinary_is_a_real_gap",
    }

    remedies: dict[str, list[str]] = {}
    for node in ast.walk(ast.parse(guard.read_text(encoding="utf-8"))):
        if not isinstance(node, ast.FunctionDef):
            continue
        for statement in ast.walk(node):
            if not isinstance(statement, ast.Assert) or statement.msg is None:
                continue
            # Every literal fragment of the message, whether it was written as
            # one string, an implicit concatenation, or an f-string.
            message = " ".join(
                part.value for part in ast.walk(statement.msg)
                if isinstance(part, ast.Constant) and isinstance(part.value, str))
            if re.search(r"re-record|re-measure", message, re.IGNORECASE):
                remedies.setdefault(node.name, []).append(message)

    missing = sorted(MUST_OFFER_A_REMEDY - set(remedies))
    assert not missing, (
        f"these guards in {guard.name} no longer tell anyone how to clear the "
        f"drift they report: {missing}. Either the guard was renamed, or its "
        "message lost the command, and both leave a person told what is wrong "
        "and not what to run (L111).")

    for owner, messages in sorted(remedies.items()):
        for message in messages:
            named = re.search(r"make ([a-z-]+)", message)
            assert named, (
                f"{guard.name}::{owner} tells somebody to re-record without "
                f"naming the command that does it: {message!r}")
            assert named.group(1) in targets, (
                f"{guard.name}::{owner} tells people to run "
                f"`make {named.group(1)}`, and the Makefile has no such "
                f"target. It has: {sorted(targets)}")


def test_the_parser_reads_a_report_a_real_pytest_run_wrote(tmp_path: Path):
    """Every check above drives the parser with XML this file wrote itself.

    That can only confirm the shape assumed here is the shape assumed here
    (L52). So this one runs a real pytest, under `-n 2` because that is what the
    recorder uses and xdist is what strips the `file` attribute the parser might
    otherwise have keyed on, and asserts the two ways of going red come back
    correctly told apart.
    """
    suite = tmp_path / "tests"
    suite.mkdir()
    (suite / "test_real.py").write_text(
        "import pytest\n\n"
        "def test_that_passes():\n    assert True\n\n"
        "def test_that_fails():\n    assert False\n\n"
        "@pytest.fixture\n"
        "def broken():\n    raise RuntimeError('no')\n\n"
        "def test_that_errors(broken):\n    assert True\n",
        encoding="utf-8")

    report = tmp_path / "report.xml"
    subprocess.run(
        [sys.executable, "-m", "pytest", str(suite), "-q", "-n", "2",
         "-p", "no:cacheprovider", f"--junit-xml={report}"],
        cwd=tmp_path, capture_output=True, text=True, check=False)

    by_name = {case.name: case for case in failed_cases(report)}

    assert set(by_name) == {"test_that_fails", "test_that_errors"}, (
        "the parser did not read a real report's failures back: "
        f"{sorted(by_name)}")
    assert by_name["test_that_fails"].kind == "failure"
    assert by_name["test_that_errors"].kind == "error", (
        "a test that blew up in its fixture came back as a plain failure, so "
        "the recorder would tolerate one in the guard file as drift being "
        "reported when the guard never ran at all")


# ── adding one file without re-reading the whole suite (#1038) ───────────────
#
# `make record-test-durations` re-reads every file and re-derives every share,
# and the shares move with the machine's load rather than with the tests. A full
# re-record on 2026-08-30 moved the total 31.7% and UNEVENLY, which carried a
# file across the expensive floor and turned a guard red on a suite nobody had
# changed. So the record cannot be re-taken casually, and until now the only
# other way to add a file was to measure it by hand and paste a number in, which
# was done three times on 2026-08-30 and 31 and is exactly the mixing of runs
# this issue is about (L224).
#
# `--add` is that hand procedure, automated and written down. It measures the
# new files BESIDE files already in the record, in one run, so the reading can
# be scaled into the record's own run instead of mixed across runs. The scale
# is the MEDIAN of the reference ratios, because the spread is wide: measured on
# 2026-08-31 over seven references it ran 0.16 to 3.57, which is the same
# contention the issue is about, and a median is what survives it.

from tools.record_test_durations import (  # noqa: E402
    Provenance,
    added,
    scale_from,
)


def test_the_scale_is_the_median_of_the_reference_ratios():
    """One reference under contention must not carry the whole scale."""
    scale = scale_from(recorded={"a.py": 1.0, "b.py": 2.0, "c.py": 3.0},
                       measured={"a.py": 1.0, "b.py": 1.0, "c.py": 1.0})
    assert scale == 2.0


def test_a_reference_missing_from_the_run_is_refused():
    """Scaling against a reference that did not run is scaling against nothing,
    and the answer would look exactly as confident (L98)."""
    with pytest.raises(SystemExit, match="did not run"):
        scale_from(recorded={"a.py": 1.0, "b.py": 2.0},
                   measured={"a.py": 1.0})


def test_a_reference_the_record_has_never_seen_is_refused():
    with pytest.raises(SystemExit, match="not in the record"):
        scale_from(recorded={"a.py": 1.0},
                   measured={"a.py": 1.0, "stranger.py": 1.0})


def test_a_reference_that_measured_as_nothing_is_refused():
    """Dividing by it gives an infinite scale, which would then be applied to
    the file being added."""
    with pytest.raises(SystemExit, match="measured 0"):
        scale_from(recorded={"a.py": 1.0, "b.py": 2.0, "c.py": 3.0},
                   measured={"a.py": 0.0, "b.py": 1.0, "c.py": 1.0})


def test_no_references_at_all_is_refused_rather_than_scaled_by_one():
    """A scale of 1.0 is a claim that this run matched the record's run, and
    that is the one thing a run with no references cannot know (L11)."""
    with pytest.raises(SystemExit, match="no reference"):
        scale_from(recorded={"a.py": 1.0}, measured={})


# ── what the record then says about itself ───────────────────────────────────

def test_an_added_file_is_scaled_and_says_so():
    """Three references with DIFFERENT ratios on purpose.

    With one reference the scale is exactly its own ratio, so re-writing it
    from this run reproduces the number it already had and a check on that
    number passes whether the record was rewritten or not. Ratios of 1, 2 and 4
    make the median 2 and leave every reference's rewritten value different
    from its recorded one, so the check can see the difference (L159).
    """
    record = {
        "seconds": {"one.py": 1.0, "two.py": 2.0, "four.py": 4.0},
        "measured": {name: {"run": "full-x", "scale": 1.0}
                     for name in ("one.py", "two.py", "four.py")},
    }
    grown = added(record,
                  measured={"new.py": 3.0,
                            "one.py": 1.0, "two.py": 1.0, "four.py": 1.0},
                  run="partial-y")

    assert grown["seconds"]["new.py"] == 6.0, "the reading was not scaled by 2.0"
    assert [grown["seconds"][name] for name in ("one.py", "two.py", "four.py")] \
        == [1.0, 2.0, 4.0], (
            "adding a file rewrote the references' recorded seconds, so every "
            "share in the record moved for files nobody changed")
    assert grown["measured"]["new.py"] == {"run": "partial-y", "scale": 2.0}


def test_the_provenance_covers_exactly_the_files_recorded():
    """A record whose two halves disagree can say a file was measured that has
    no reading, or hold a reading nothing accounts for (L225)."""
    record = {"seconds": {"ref.py": 2.0},
              "measured": {"ref.py": {"run": "full-x", "scale": 1.0}}}
    grown = added(record, measured={"new.py": 3.0, "ref.py": 1.0}, run="partial-y")

    assert set(grown["seconds"]) == set(grown["measured"])


def test_a_full_record_says_every_file_came_from_the_same_run():
    """The state the record is in after `make record-test-durations`: one run,
    no scaling, and nothing to reconcile."""
    stamped = Provenance.full("full-2026-08-31", ["a.py", "b.py"])

    assert stamped == {"a.py": {"run": "full-2026-08-31", "scale": 1.0},
                       "b.py": {"run": "full-2026-08-31", "scale": 1.0}}


def test_the_other_guard_that_reads_the_record_is_tolerated_too(run):
    """#837's exemption covered one of the TWO guards that read this record.

    `test_a_new_test_file_is_measured` goes red for exactly the same reason
    `test_fast_subset_stays_honest` does, at exactly the same moment: a test
    file exists that the record has never seen. Its message names this tool as
    the remedy, like the other one's does.

    Exempting only one of them left the remedy unreachable in the commonest
    case there is, which is adding a test file: the tool refused, naming a
    failure that nothing but the tool could clear (L111). Measured on
    2026-09-01, when three new test files deadlocked it through two full suite
    runs.

    A guard whose stand down condition is narrower than the reason for standing
    down disables the remedy in cases nobody meant to exempt (L324).
    """
    run(1, report(
        failed("tests.test_a_new_test_file_is_measured",
               "test_this_branch_measures_every_test_file_it_adds"),
        passed("tests.test_something", "test_a")))

    assert measure() == {"test_something.py": 0.75, "test_other.py": 2.0}


def test_both_record_guards_failing_together_still_records(run):
    """The real shape of adding a test file: both go red at once."""
    run(1, report(
        failed(OWN_GUARD_CLASSNAME, "test_the_record_still_covers_the_suite"),
        failed("tests.test_a_new_test_file_is_measured",
               "test_this_branch_measures_every_test_file_it_adds"),
        passed("tests.test_something", "test_a")))

    assert measure() == {"test_something.py": 0.75, "test_other.py": 2.0}


def test_the_exemption_names_every_guard_that_reads_the_record():
    """The list and the guards it exempts must not drift apart (L96).

    A guard added later that reads this record, and goes red when it is stale,
    has to be added here too, or it silently reintroduces the deadlock.
    """
    from tools.record_test_durations import RECORD_GUARD_CLASSNAMES
    assert "tests.test_fast_subset_stays_honest" in RECORD_GUARD_CLASSNAMES
    assert "tests.test_a_new_test_file_is_measured" in RECORD_GUARD_CLASSNAMES
    for name in RECORD_GUARD_CLASSNAMES:
        path = Path(__file__).resolve().parent.parent / (
            name.replace("tests.", "tests/") + ".py")
        assert path.is_file(), (
            f"{name} is exempted from the refusal and no such test file "
            f"exists, so the exemption covers nothing and a real failure in a "
            f"file of that name would be recorded past")

# --- #976: one reading under an unknown load decided the whole boundary -------

def test_the_median_of_three_passes_is_what_lands():
    """The fix #976 asked for.

    A single reading is what the expensive/ordinary boundary rested on, and it
    moves: two consecutive full re-timings on this Mac with the same tests came
    out at 1071s and 1737s, a 62% swing. The middle pass here is a burst of
    load, and the median has to ignore it rather than average it in."""
    passes = iter([
        {"a.py": 10.0, "b.py": 20.0},
        {"a.py": 90.0, "b.py": 180.0},   # the machine was busy
        {"a.py": 11.0, "b.py": 21.0},
    ])

    got = measure_repeatedly(["a.py", "b.py"], passes=3,
                             run=lambda paths: next(passes))

    assert got == {"a.py": 11.0, "b.py": 21.0}


def test_the_median_is_taken_per_file_rather_than_per_pass():
    """A pass is not a unit anybody cares about; a file's cost is. Taking the
    best PASS would let one file having a bad moment drag every other reading
    in it (L296)."""
    passes = iter([
        {"a.py": 10.0, "b.py": 99.0},
        {"a.py": 99.0, "b.py": 20.0},
        {"a.py": 11.0, "b.py": 21.0},
    ])

    got = measure_repeatedly(["a.py", "b.py"], passes=3,
                             run=lambda paths: next(passes))

    assert got == {"a.py": 11.0, "b.py": 21.0}, (
        "one file's bad pass moved another file's reading")


def test_a_file_missing_from_a_pass_refuses_rather_than_averaging_the_rest():
    """A test that ran twice out of three times measured something other than
    its cost, and a quiet median over the two it managed would read as a clean
    number (L11, L98)."""
    passes = iter([
        {"a.py": 10.0, "b.py": 20.0},
        {"a.py": 11.0},
        {"a.py": 12.0, "b.py": 21.0},
    ])

    with pytest.raises(SystemExit) as refusal:
        measure_repeatedly(["a.py", "b.py"], passes=3,
                           run=lambda paths: next(passes))

    assert "b.py" in str(refusal.value)
    assert "all 3 passes" in str(refusal.value)


def test_a_run_that_measured_nothing_at_all_refuses():
    """The other emptiness. Distinct from the one above, because a run that
    reported NOTHING and one that reported some files are different failures
    and a shared message would answer for both (L11)."""
    with pytest.raises(SystemExit) as refusal:
        measure_repeatedly(["a.py"], passes=2, run=lambda paths: {})

    assert "nothing to take a median of" in str(refusal.value)


def test_zero_passes_refuses():
    with pytest.raises(SystemExit):
        measure_repeatedly(["a.py"], passes=0, run=lambda paths: {"a.py": 1.0})


def test_the_pass_count_is_odd_so_a_median_is_a_reading():
    """An even count makes the median the average of the two middle readings,
    which is the mean this was adopted to get away from."""
    assert ADD_PASSES % 2 == 1, (
        f"{ADD_PASSES} passes makes the median an average of two readings")
    assert ADD_PASSES >= 3, (
        f"{ADD_PASSES} passes cannot survive one of them landing under a burst "
        f"of load, which is the whole reason for repeating")


def test_every_pass_measures_the_same_files():
    """A pass measuring a different set would make the medians be over
    different populations, which is the shape L220 is about."""
    asked: list[list[str]] = []

    def record_the_ask(paths):
        asked.append(list(paths))
        return {name: 1.0 for name in paths}

    measure_repeatedly(["a.py", "b.py"], passes=3, run=record_the_ask)

    assert asked == [["a.py", "b.py"]] * 3

def test_adding_a_file_actually_goes_through_the_repeated_measurement(monkeypatch,
                                                                     tmp_path):
    """Built is not wired (L3).

    Every check above drives `measure_repeatedly` directly. This is the one that
    says `--add` calls it, because a median nothing reaches is a median that
    changes nothing, and the single reading would go on deciding the boundary
    while these tests all passed."""
    import json

    import tools.record_test_durations as recorder

    record = tmp_path / "durations.json"
    record.write_text(json.dumps({
        # The record is keyed by BASENAME while REFERENCE_FILES are paths,
        # which is what the tool itself reconciles.
        "seconds": {Path(name).name: 10.0 for name in recorder.REFERENCE_FILES},
        "measured": {Path(name).name: {"run": "full-2026-01-01T00:00Z"}
                     for name in recorder.REFERENCE_FILES},
    }), encoding="utf-8")
    monkeypatch.setattr(recorder, "RECORD", record)

    passes: list[int] = []

    def counted(paths):
        passes.append(len(paths))
        return {Path(p).name: 10.0 for p in paths}

    monkeypatch.setattr(recorder, "measure", counted)
    recorder._add(["tests/test_brand_new_thing.py"])

    assert len(passes) == recorder.ADD_PASSES, (
        f"--add measured {len(passes)} time(s), so the median is over one "
        f"reading and the single sample still decides the boundary")
    assert json.loads(record.read_text())["seconds"]["test_brand_new_thing.py"]


def test_the_recorder_writes_how_many_passes_each_figure_came_from(tmp_path,
                                                                   monkeypatch):
    """The sample size comes from the WRITER, not from a hand edit (#1328).

    A hand edit does not survive: `_write` rewrites the whole record, so adding
    one test file erases anything a person put beside the durations (L379).
    """
    record = tmp_path / "test_file_durations.json"
    monkeypatch.setattr(record_test_durations, "RECORD", record)

    record_test_durations._write({"seconds": {"test_a.py": 1.0}, "measured": {}})

    written = json.loads(record.read_text())
    assert written["passes"] == record_test_durations.ADD_PASSES
    assert "MEDIAN" in written["_sample"]
    # The durations themselves are untouched by the addition.
    assert written["seconds"] == {"test_a.py": 1.0}


def test_the_recorded_sample_note_names_the_real_pass_count(monkeypatch):
    """A note saying "three passes" beside a constant of four is worse than no
    note, because it reads as a measurement (L210)."""
    monkeypatch.setattr(record_test_durations, "ADD_PASSES", 9)

    said = record_test_durations.SAMPLE_NOTE.format(
        passes=record_test_durations.ADD_PASSES)

    assert "9 measured passes" in said
