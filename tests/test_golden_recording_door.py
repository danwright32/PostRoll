"""A deliberately wrong render can never be recorded as a reference frame (#915).

`assert_matches_golden` has two behaviours, and which one it takes is decided by
an environment variable rather than by the caller. Under
`POSTROLL_UPDATE_GOLDENS` it SAVES what it was handed and skips; otherwise it
compares. That is what the re-record door needs, and it makes every check that
hands it a DELIBERATELY WRONG frame into a writer.

Measured on 2026-08-27:
`test_a_caption_line_moved_one_pixel_fails_its_reference_frame` renders a story
with one caption line moved and asserts the comparison rejects it. Under the
door it recorded that broken render over `goldens/story.png` instead, on every
run of `make record-design-change`, whatever template was being changed. The
only thing between that and a committed golden was the door then refusing for
the failure this check itself caused, having already written the file.

#898 fixed it with `may_record=False`. The flag DEFAULTS to allowing the write,
which is right for the honest majority and means the next check written this
way inherits the same trap in silence. This is the class rather than the
instance (L30): a reference frame is the expectation everything else is judged
against, so a wrong one defends a broken render for as long as it lives (L84).

The rule is that a call inside a `pytest.raises` must STATE which it means,
either way, rather than that it must refuse. Both answers are legitimate there
and the file holds one of each: the perturbation check may not record, and the
control proving the door still records must. What is not legitimate is arriving
at either by default, because that is the same as not having decided (L168).

Read through Python's own parser rather than by matching text, so a mention in
a comment or a docstring cannot satisfy it and a call spread over several lines
cannot hide from it (L103).
"""

from __future__ import annotations

import ast
from pathlib import Path

GOLDEN_TESTS = Path(__file__).resolve().parent / "test_golden_frames.py"

#: The comparison whose recording behaviour this is about.
COMPARISON = "assert_matches_golden"


def _is_pytest_raises(node: ast.expr) -> bool:
    """`pytest.raises(...)`, however the caller spells the attribute."""
    if not isinstance(node, ast.Call):
        return False
    func = node.func
    if isinstance(func, ast.Attribute) and func.attr == "raises":
        return True
    return isinstance(func, ast.Name) and func.id == "raises"


def undecided_calls_inside_raises(source: str) -> list[int]:
    """Line numbers where a call inside a `pytest.raises` has not decided.

    The caller is the only one that knows whether its render is a perturbation,
    so the caller is where the decision has to be, and inside a block asserting
    a throw it may not be left to the default.
    """
    tree = ast.parse(source)
    found: list[int] = []

    for node in ast.walk(tree):
        if not isinstance(node, (ast.With, ast.AsyncWith)):
            continue
        if not any(_is_pytest_raises(item.context_expr) for item in node.items):
            continue
        for inner in ast.walk(node):
            if not isinstance(inner, ast.Call):
                continue
            name = inner.func.attr if isinstance(inner.func, ast.Attribute) else \
                getattr(inner.func, "id", None)
            if name != COMPARISON:
                continue
            decided = any(
                kw.arg == "may_record" and isinstance(kw.value, ast.Constant)
                and isinstance(kw.value.value, bool)
                for kw in inner.keywords)
            if not decided:
                found.append(inner.lineno)
    return found


def test_the_guard_catches_a_call_that_could_record():
    """The positive control, and it is the whole of this file's honesty.

    Nothing in the real file trips this today, so without a sample that DOES
    the check below passes whether it works or not, and an empty answer is
    indistinguishable from a clean file (L98, L159).

    This sample is the shape the defect actually had.
    """
    bad = (
        "import pytest\n"
        "def test_a_moved_line_is_caught():\n"
        "    with pytest.raises(BaseException):\n"
        "        assert_matches_golden(frame, 'story', tmp_path)\n"
    )

    assert undecided_calls_inside_raises(bad) == [4]


def test_the_guard_accepts_a_call_that_has_said_it_may_not_record():
    good = (
        "import pytest\n"
        "def test_a_moved_line_is_caught():\n"
        "    with pytest.raises(BaseException):\n"
        "        assert_matches_golden(frame, 'story', tmp_path,\n"
        "                              may_record=False)\n"
    )

    assert undecided_calls_inside_raises(good) == []


def test_the_guard_accepts_a_call_that_has_said_it_MAY_record():
    """Both answers are legitimate inside a raises block. The control proving
    the door still writes has to write, and it says so."""
    control = (
        "import pytest\n"
        "def test_the_door_still_records():\n"
        "    with pytest.raises(pytest.skip.Exception):\n"
        "        assert_matches_golden(frame, 'scratch', tmp_path,\n"
        "                              may_record=True)\n"
    )

    assert undecided_calls_inside_raises(control) == []


def test_a_comment_naming_the_flag_does_not_satisfy_the_guard():
    """A guard green on prose is indistinguishable from one that works (L103)."""
    commented = (
        "import pytest\n"
        "def test_a_moved_line_is_caught():\n"
        "    with pytest.raises(BaseException):\n"
        "        # may_record=False is not passed here, only mentioned\n"
        "        assert_matches_golden(frame, 'story', tmp_path)\n"
    )

    assert undecided_calls_inside_raises(commented) == [5]


def test_the_file_this_is_about_is_still_there_and_still_compares():
    """The other half of the honesty. A path that stopped resolving, or a file
    that stopped calling the comparison, would read as a clean file (L98)."""
    source = GOLDEN_TESTS.read_text()

    assert COMPARISON in source, (
        f"{GOLDEN_TESTS} no longer calls {COMPARISON}, so the check below is "
        "reading a file that cannot contain the defect and would pass whatever "
        "it found")


def test_every_call_inside_a_raises_has_decided():
    lines = undecided_calls_inside_raises(GOLDEN_TESTS.read_text())

    assert lines == [], (
        f"{GOLDEN_TESTS.name} line(s) {lines}: a call to {COMPARISON} inside a "
        "`pytest.raises` has not said whether it may record. Under "
        "POSTROLL_UPDATE_GOLDENS the default SAVES what it was handed as the "
        "reference frame, and a frame the caller expects to be rejected is "
        "exactly the frame that must never become the expectation. Say "
        "may_record=False for a perturbation, or may_record=True for a check "
        "that is proving the door still writes.")
