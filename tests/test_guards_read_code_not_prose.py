"""#1074: guards that checked a name by appearance rather than by matching it.

`test_the_suite_runs_on_a_mac_as_well_as_linux` asserted `"macos" in
tests.yml`. That word appears ten times in the file, at least five of them
inside comments, so deleting the entire `macos:` job left the guard green on
prose alone. It is L103 and L135 inside a guard whose whole subject is that a
skipped Mac leg reads exactly like a passing one (L98).

Not hypothetical: `test_the_confirming_step_still_runs_when_the_job_goes_red`
SURVIVED its registry mutation in #990 because it matched `!cancelled()` in the
step's explanatory comment rather than in the step's `if:`.

#436 swept the Python-to-Swift parity guards for this and left
`swift_without_comments` behind. The workflow and source-scanning guards had
never been swept, and this file is what stops the shape coming back.

## The rule

A test that asserts a literal is IN a file it read must read that file through
`source_text.without_prose`, which blanks the comments of whatever language the
file is in.

Only positive assertions. `assert "x" not in raw_text` is stricter than the
same assertion over stripped text, never weaker: raw text is a superset, so a
`not in` that passes on it would pass on anything. Over-strictness is the safe
direction, and sweeping it in would double the size of this check for no defect
caught (L36).

Per FUNCTION, not per file. A file where one test reads raw and another reads
stripped is ordinary, and a whole-file analysis reports the second as the first.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

TESTS = Path(__file__).resolve().parent

#: Calls that hand back a file's text exactly as written.
RAW_READS = {"read_text", "getsource"}

#: Where a raw read is the RIGHT answer, and why (L233).
#:
#: An entry says which function, because the exemption belongs to one claim and
#: not to a whole file. Every one of these asserts something ABOUT the prose, so
#: reading the file as code would look for the claim everywhere except where it
#: can be.
PROSE_IS_THE_SUBJECT = {
    "test_swift_suite_cost_names_its_machine.py::"
    "test_the_workflow_sends_the_reader_to_the_record":
        "a workflow can only cite a record in a comment, so the citation this "
        "asks for lives in the prose by construction",
}


def _functions(tree: ast.AST):
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            yield node


def _raw_names(function: ast.AST) -> set[str]:
    """Names bound inside `function` straight from a raw read."""
    bound: set[str] = set()
    for node in ast.walk(function):
        if not (isinstance(node, ast.Assign) and isinstance(node.value, ast.Call)):
            continue
        called = node.value.func
        name = (called.attr if isinstance(called, ast.Attribute)
                else getattr(called, "id", ""))
        if name in RAW_READS:
            bound |= {t.id for t in node.targets if isinstance(t, ast.Name)}
    return bound


def _prose_matches(function: ast.AST) -> list[tuple[int, str]]:
    """Every `assert "literal" in <raw text>` inside `function`."""
    raw = _raw_names(function)
    found: list[tuple[int, str]] = []
    for node in ast.walk(function):
        if not (isinstance(node, ast.Assert)
                and isinstance(node.test, ast.Compare)
                and len(node.test.ops) == 1
                and isinstance(node.test.ops[0], ast.In)):
            continue
        left, right = node.test.left, node.test.comparators[0]
        if not (isinstance(left, ast.Constant) and isinstance(left.value, str)):
            continue
        # Unwrap `.lower()`, `.strip()` and friends to reach the name.
        target = right
        while isinstance(target, ast.Call) and isinstance(target.func, ast.Attribute):
            target = target.func.value
        if isinstance(target, ast.Name) and target.id in raw:
            found.append((node.lineno, left.value))
    return found


def sites() -> list[tuple[str, int, str]]:
    """Every positive literal match against raw file text, across the suite."""
    found: list[tuple[str, int, str]] = []
    for path in sorted(TESTS.glob("test_*.py")):
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"))
        except SyntaxError:
            continue
        for function in _functions(tree):
            for line, literal in _prose_matches(function):
                found.append((f"{path.name}::{function.name}", line, literal))
    return found


def test_the_sweep_can_still_find_this_shape():
    """The positive control. A walker that found nothing would report the whole
    suite as clean, which is what this file exists to stop being possible
    (L100, L98)."""
    source = ast.parse(
        'def t():\n'
        '    text = P.read_text()\n'
        '    assert "macos" in text.lower()\n')
    function = next(_functions(source))

    assert _prose_matches(function) == [(3, "macos")]


def test_a_stripped_read_is_not_reported():
    """The other direction: the remedy has to actually clear the state the
    message names, or nobody can satisfy it (L109, L111)."""
    source = ast.parse(
        'def t():\n'
        '    text = without_prose(P)\n'
        '    assert "macos" in text\n')

    assert _prose_matches(next(_functions(source))) == []


def test_a_negative_assertion_is_not_reported():
    """Raw text is a superset of stripped text, so `not in` over it is stricter
    rather than weaker. Sweeping those in would double this check for no defect
    caught, and a check that fires on everything stops being read (L36)."""
    source = ast.parse(
        'def t():\n'
        '    text = P.read_text()\n'
        '    assert "macos" not in text\n')

    assert _prose_matches(next(_functions(source))) == []


@pytest.mark.parametrize("site", sites(), ids=lambda s: s[0] if s else "none")
def test_no_guard_matches_a_literal_against_prose(site):
    where, line, literal = site

    if where in PROSE_IS_THE_SUBJECT:
        pytest.skip(f"the prose IS the subject: {PROSE_IS_THE_SUBJECT[where]}")

    pytest.fail(
        f"{where} (line {line}) asserts {literal!r} is in a file it read RAW, "
        f"so a comment mentioning it answers the check as readily as the code "
        f"does, and the thing being checked for can be deleted with the guard "
        f"still green (#1074, L103, L135). Read it through "
        f"`source_text.without_prose`, or add it to PROSE_IS_THE_SUBJECT with "
        f"the reason its claim really is about the prose.")


def test_the_exemptions_all_name_a_function_that_exists():
    """A stale entry excuses a real failure silently, which is the one way an
    exemption list can be worse than no exemption list (L233, L217)."""
    named = {site[0] for site in sites()}
    stale = sorted(set(PROSE_IS_THE_SUBJECT) - named)

    assert not stale, (
        f"these exemptions name no site the sweep finds any more: {stale}. "
        f"Either the guard was fixed and the entry should go, or it was "
        f"renamed and the entry now excuses nothing while looking like it does")
