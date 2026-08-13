"""The suite cannot silently delete one of its own tests.

Python binds a module's names in order, so a second `def test_x` replaces the
first with no error and no warning. Pytest then collects one test, the file
still reads as though it holds two, and the check that was overwritten never
runs again.

That is not hypothetical here. `test_slider_labels_are_dark_enough_to_read_on_cream`
was defined twice in `tests/test_gallery_alignment.py`. The surviving one
compared two constants; the one it replaced measured the darkest pixel inside
the rendered label box, and was the only pixel-level check the slider's labels
had. It ran zero times. #163 exists because white labels on the cream mat once
shipped invisibly, and a constant compared against a constant cannot catch that
happening again.

Fixing that one occurrence would leave the class alone (L30), and the class is
invisible by construction: both definitions look correct in isolation and the
file passes. So this asks the question of every test module instead.
"""

from __future__ import annotations

import ast
from collections import Counter
from pathlib import Path

import pytest


TESTS_DIR = Path(__file__).resolve().parent


def _test_files() -> list[Path]:
    return sorted(TESTS_DIR.glob("test_*.py"))


def duplicate_test_names(source: str) -> list[str]:
    """Test function names defined more than once at a module's top level.

    Top level only. Two methods of the same name in different classes are
    distinct tests and shadow nothing, so flagging them would be noise, and a
    guard that fires on things that are fine is one people learn to ignore.
    """
    tree = ast.parse(source)
    names = [
        node.name for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name.startswith("test_")
    ]
    return sorted(name for name, count in Counter(names).items() if count > 1)


def test_the_scan_finds_test_files_at_all():
    # A glob matching nothing would make the guard below pass with total
    # confidence while checking no file (L98).
    found = _test_files()

    assert len(found) > 50, f"the scan found almost no test files: {len(found)}"


def test_no_module_defines_the_same_test_twice():
    offenders: dict[str, list[str]] = {}
    for path in _test_files():
        try:
            duplicates = duplicate_test_names(path.read_text(encoding="utf-8"))
        except SyntaxError as exc:
            pytest.fail(f"{path.name} could not be parsed: {exc}")
        if duplicates:
            offenders[path.name] = duplicates

    assert not offenders, (
        "these modules define a test name more than once, so the later "
        "definition silently replaces the earlier one and pytest collects only "
        f"the last: {offenders}. Whatever the earlier one checked has stopped "
        "running, and nothing else will say so. Rename or merge them.")


# ── the guard's own reading, on sources this test owns ───────────────────────


def test_a_repeated_name_is_reported():
    source = "def test_a():\n    pass\n\n\ndef test_a():\n    pass\n"

    assert duplicate_test_names(source) == ["test_a"]


def test_distinct_names_are_not_reported():
    source = "def test_a():\n    pass\n\n\ndef test_b():\n    pass\n"

    assert duplicate_test_names(source) == []


def test_a_helper_sharing_a_name_with_nothing_is_ignored():
    # Only names pytest would collect. A repeated helper is a different problem
    # and not this guard's business.
    source = "def _make():\n    pass\n\n\ndef _make():\n    pass\n"

    assert duplicate_test_names(source) == []


def test_the_same_method_name_in_two_classes_is_not_a_duplicate():
    source = (
        "class TestOne:\n    def test_x(self):\n        pass\n\n\n"
        "class TestTwo:\n    def test_x(self):\n        pass\n"
    )

    assert duplicate_test_names(source) == []


# ── an assertion that cannot fail (#435) ─────────────────────────────────────
#
# `tests/test_top_anchored_crop.py` carried an assertion ending in `or True`.
# Both of its disjuncts were false for the fixture it ran against, so somebody
# had silenced a wrong assertion instead of deleting it. It sat permanently
# green, and it told every later reader the opposite of what the code under it
# actually does.
#
# Deleting that line would leave the class alone (L30), and the class is exactly
# the kind that hides: the file passes, the line reads like a check, and a guard
# is only real once it has been seen to fail (L1). So the question gets asked of
# every assertion in the suite instead.


def _statically_true(node: ast.expr) -> bool:
    """Whether this expression is true no matter what the code does."""
    if isinstance(node, ast.Constant):
        return bool(node.value)
    if isinstance(node, (ast.Tuple, ast.List)):
        # `assert (a, b)` is the classic one: a non-empty tuple is always true,
        # so the comparison inside it is never made.
        return len(node.elts) > 0
    if isinstance(node, ast.BoolOp) and isinstance(node.op, ast.Or):
        return any(_statically_true(value) for value in node.values)
    if isinstance(node, ast.BoolOp) and isinstance(node.op, ast.And):
        return all(_statically_true(value) for value in node.values)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        return isinstance(node.operand, ast.Constant) and not node.operand.value
    return False


def vacuous_assertions(source: str) -> list[int]:
    """Line numbers of assertions in `source` that cannot fail."""
    return sorted(
        node.lineno
        for node in ast.walk(ast.parse(source))
        if isinstance(node, ast.Assert) and _statically_true(node.test)
    )


def test_no_test_module_holds_an_assertion_that_cannot_fail():
    offenders: list[str] = []
    scanned = 0
    for path in _test_files():
        scanned += 1
        for line in vacuous_assertions(path.read_text(encoding="utf-8")):
            offenders.append(f"{path.name}:{line}")

    assert scanned > 50, "the scan read almost no files, so it proves nothing"
    assert not offenders, (
        "These assertions are true whatever the code does, so they are green "
        "forever while reading like checks:\n  " + "\n  ".join(offenders)
    )


def test_the_or_true_shape_is_caught():
    assert vacuous_assertions("def t():\n    assert a == b or True\n") == [2]


def test_a_bare_true_is_caught():
    assert vacuous_assertions("def t():\n    assert True\n") == [2]


def test_an_always_true_tuple_is_caught():
    # `assert (x == y, "message")` reads as an assertion with a message and is
    # a non-empty tuple, so it passes for any x and y.
    assert vacuous_assertions('def t():\n    assert (a == b, "why")\n') == [2]


def test_a_real_assertion_is_left_alone():
    source = (
        "def t():\n"
        "    assert a == b\n"
        "    assert a or b\n"
        '    assert value in ("x", "y")\n'
        "    assert not found\n"
    )

    assert vacuous_assertions(source) == []
