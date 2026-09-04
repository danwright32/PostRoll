"""#1033: nothing re-measured the numbers an issue was written on.

#991 recorded 58 cache entries holding 16 GB; measured on 2026-08-29 it was 76
entries holding 20.9 GB, 30 percent out after roughly a day. A previous session
found three of six premises in one issue did not survive checking. A number with
a date on it reads as MORE trustworthy, not less (L316, L244, L210), so the
remedy is to re-take the reading rather than to date it harder.

Nothing here reaches GitHub. Every test drives the tool with a fake `gh` (L2).
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from check_issue_figures import (  # noqa: E402
    MARKER, MEASUREMENTS, CannotMeasure, check, drifted, guard_entries,
    markers, swift_tests)


def fake_gh(issues, fail=False):
    def run(args):
        if fail:
            return subprocess.CompletedProcess(args, 1, "", "no token")
        return subprocess.CompletedProcess(args, 0, json.dumps(issues), "")
    return run


def issue(number, body, title="An issue"):
    return {"number": number, "title": title, "body": body}


# --- the marker ---------------------------------------------------------------

def test_a_marker_is_read_off_an_issue_body():
    found = markers("Some prose.\n\n<!-- remeasure: guard-entries = 495 +/- 10% -->")

    assert found == [("guard-entries", 495.0, 10.0)]


def test_prose_naming_a_number_is_not_a_marker():
    """A guard that matched loose prose would compare against a figure nobody
    recorded as re-measurable, and then warn about it forever (L104)."""
    assert markers("we measured 495 guard entries, plus or minus 10 percent") == []
    assert markers("<!-- remeasure: guard-entries = about 495 +/- 10% -->") == []


def test_a_thousands_separator_is_not_matched():
    """A marker that half parsed would compare against something nobody wrote:
    `1,495` read as `1` is a figure off by a factor of a thousand."""
    assert markers("<!-- remeasure: guard-entries = 1,495 +/- 10% -->") == []


def test_several_figures_on_one_issue_are_all_read():
    body = ("<!-- remeasure: cache-entries = 58 +/- 20% -->\n"
            "<!-- remeasure: cache-gb = 16 +/- 20% -->")

    assert [name for name, _, _ in markers(body)] == ["cache-entries", "cache-gb"]


# --- the comparison -----------------------------------------------------------

def test_a_figure_inside_its_tolerance_has_not_moved():
    assert not drifted(recorded=100, now=105, tolerance=10)


def test_a_figure_past_its_tolerance_has_moved():
    assert drifted(recorded=100, now=112, tolerance=10)


def test_it_moves_in_both_directions():
    """A figure that COLLAPSED is as much a changed premise as one that grew,
    and a one-sided comparison would miss the half that usually means something
    broke (L159)."""
    assert drifted(recorded=100, now=80, tolerance=10)


def test_a_recorded_zero_moves_the_moment_anything_appears():
    """Nothing divides by zero, and zero to one is an infinite proportional
    change: a plan resting on "there are none of these" is wrong as soon as
    there is one (L182)."""
    assert drifted(recorded=0, now=1, tolerance=50)
    assert not drifted(recorded=0, now=0, tolerance=50)


# --- what it reports ----------------------------------------------------------

def test_a_figure_that_still_holds_produces_no_warning():
    real = guard_entries()
    gh = fake_gh([issue(1, f"<!-- remeasure: guard-entries = {real:g} +/- 10% -->")])

    moved, unreadable, checked = check(run=gh)

    assert (moved, unreadable) == ([], [])
    assert checked == 1


def test_a_figure_that_has_moved_names_the_issue_and_both_values():
    """The whole point is that somebody can act on it, and a warning that says a
    number moved without saying which number, from what, to what, leaves them to
    go and find it (L80)."""
    real = guard_entries()
    gh = fake_gh([issue(7, "<!-- remeasure: guard-entries = 1 +/- 10% -->",
                        title="A plan resting on one entry")])

    moved, unreadable, checked = check(run=gh)

    assert unreadable == []
    assert len(moved) == 1
    assert "#7" in moved[0]
    assert "guard-entries" in moved[0]
    assert "= 1" in moved[0]
    assert f"{real:g}" in moved[0]
    assert "A plan resting on one entry" in moved[0]


def test_one_figure_that_cannot_be_taken_is_reported_and_the_rest_still_are():
    """The case this whole tool is about (L98).

    A measurement that FAILS says nothing about whether the figure still holds,
    and swallowing it would report that figure as unmoved. The other figure on
    the same issue still gets checked, because one broken reading is not a
    reason to stop taking the others (L73)."""
    real = guard_entries()

    def run(args):
        if args[1] == "issue":
            return subprocess.CompletedProcess(
                args, 0,
                json.dumps([issue(5,
                                  f"<!-- remeasure: guard-entries = {real:g} +/- 10% -->\n"
                                  "<!-- remeasure: cache-entries = 58 +/- 20% -->")]),
                "")
        # Only the GitHub-backed reading fails.
        return subprocess.CompletedProcess(args, 1, "", "the API said no")

    moved, unreadable, checked = check(run=run)

    assert moved == [], "a reading that could not be taken was reported as drift"
    assert len(unreadable) == 1
    assert "#5" in unreadable[0] and "cache-entries" in unreadable[0], (
        "it does not say WHICH figure on WHICH issue could not be read")
    assert checked == 1, (
        "the figure that could be taken was not checked, so one broken reading "
        "stopped the others")


def test_a_measurement_that_fails_is_its_own_outcome():
    """Distinct from one that ran and found no drift (L98). A silently failing
    re-measure reports every figure as still true."""
    gh = fake_gh([issue(3, "<!-- remeasure: cache-entries = 58 +/- 20% -->")],
                 fail=True)

    moved, unreadable, checked = check(run=gh)

    assert moved == []
    assert unreadable and "#3" not in unreadable[0], (
        "a failure to list the issues at all is reported as that, not as a "
        "figure that could not be read")
    assert checked == 0


def test_a_figure_nothing_knows_how_to_take_is_reported_rather_than_skipped():
    """A marker nobody can act on and a marker that agrees are otherwise the
    same silence (L98). It also names what IS known, so the reader can fix the
    marker rather than go looking."""
    gh = fake_gh([issue(9, "<!-- remeasure: phase-of-the-moon = 3 +/- 10% -->")])

    moved, unreadable, checked = check(run=gh)

    assert moved == []
    assert len(unreadable) == 1
    assert "phase-of-the-moon" in unreadable[0]
    assert "guard-entries" in unreadable[0], "it does not say what it can measure"
    assert checked == 0


def test_an_issue_with_no_marker_is_not_a_subject():
    gh = fake_gh([issue(4, "A perfectly ordinary issue with the number 495 in it")])

    moved, unreadable, checked = check(run=gh)

    assert (moved, unreadable, checked) == ([], [], 0)


# --- the measurements themselves ----------------------------------------------

def test_every_named_measurement_can_actually_be_taken_or_says_why():
    """A registry entry that raises on every call is a name an issue can cite
    and nothing can ever answer (L109). The two that read the repository are
    taken for real; the ones that ask GitHub are not, because a test that
    reaches the network is not a test (L2)."""
    for name in ("guard-entries", "swift-tests"):
        value = MEASUREMENTS[name]()
        assert value > 0, f"{name} measured {value}, which is not a reading"


def test_a_measurement_refuses_rather_than_answering_zero(monkeypatch, tmp_path):
    """Zero entries is not a reading, it is a directory this tool is not looking
    at, and reporting it would announce a collapse that has not happened."""
    import check_issue_figures as tool

    monkeypatch.setattr(tool, "REPO_ROOT", tmp_path)
    (tmp_path / "tests" / "fixtures" / "guard_mutations").mkdir(parents=True)

    with pytest.raises(CannotMeasure):
        tool.guard_entries()


def test_a_missing_record_refuses_rather_than_answering_zero(monkeypatch, tmp_path):
    import check_issue_figures as tool

    monkeypatch.setattr(tool, "REPO_ROOT", tmp_path)

    with pytest.raises(CannotMeasure):
        swift_tests()


def test_no_measurement_runs_a_command_from_an_issue_body():
    """The design decision, asserted rather than left in the docstring.

    The issue proposed recording the command beside the number and re-running
    it. An issue body is text anybody with write access can edit, so that would
    make it something this tool executes while holding a token. A figure being
    checkable is not worth that."""
    source = (REPO_ROOT / "tools" / "check_issue_figures.py").read_text(
        encoding="utf-8")

    assert "shell=True" not in source
    assert "eval(" not in source
    assert "os.system" not in source
    for name, take in MEASUREMENTS.items():
        assert callable(take), f"{name} is not a function this file defines"


def test_the_marker_pattern_is_the_one_the_docstring_teaches():
    """The example in the docstring is what somebody will copy, so it has to
    parse. A worked example that contradicts the rule teaches the inverse and
    is defended with the rule's own authority (L562)."""
    from check_issue_figures import __doc__ as doc

    example = next(line.strip() for line in doc.splitlines()
                   if line.strip().startswith("<!-- remeasure:"))

    assert MARKER.findall(example), (
        f"the example this file gives, {example!r}, is not a marker it reads")


def test_the_empty_case_speaks_but_does_not_cry_wolf(capsys):
    """No open issue carrying a marker is the LEGITIMATE state today, so it is a
    notice rather than a warning.

    It still speaks: a feature whose data is empty ships inert and nothing
    distinguishes it from one that is working (L543). It just does not warn
    about a correct state on every scheduled run, which is what teaches a person
    to skip the whole list (L36)."""
    import check_issue_figures as tool

    tool.subprocess = _NoIssues()
    try:
        tool.main([])
    finally:
        import subprocess as real
        tool.subprocess = real

    out = capsys.readouterr().out
    assert "::notice::" in out
    assert "::warning::" not in out, (
        "an empty subject list warns on every run about a state that is correct")
    assert "remeasure:" in out, "it does not show what a marker looks like"


class _NoIssues:
    @staticmethod
    def run(args, **kwargs):
        import subprocess
        return subprocess.CompletedProcess(args, 0, "[]", "")
