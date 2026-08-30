"""A test must not time git against the product's 5 second deadline (#992).

`CheckoutRevision.deadline` is 5 seconds and that is right for the product: a
person is waiting on a generation, and losing the revision record beats losing
the run (L110). `measure(inRepo:timeout:)` spends it on THREE git subprocesses.

Since #992 the Swift suite runs in parallel on as many workers as the machine
has cores, so a test timing git is timing it against a machine the test runner
itself is loading. Measured on 2026-08-30 at twelve workers: `CheckoutRevisionTests`
failed on roughly one run in three, its reads taking 5.5s and 8.5s and coming
back `.unknown`, which the tests then correctly refused. Nothing was wrong with
the code under test. The tests were asserting about how busy the machine was
(L290, L522).

The fix is that every test reading a real checkout passes
`CheckoutRevision.deadlineForTests`, and this is what keeps it true. A guard
rather than a comment, because the next call site will be written by copying an
existing one, and the existing ones were all written before this mattered.

## What it does NOT forbid

The deadline's own behaviour still has to be tested, and is: one test passes
`timeout: 0.5` against `/bin/sleep 30` and requires no answer back. Any explicit
timeout is fine here. What is refused is INHERITING the default, because that
value was chosen for a person waiting and not for a loaded runner.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SWIFT_TESTS = REPO_ROOT / "PostRollApp" / "Tests"

#: The calls that spend the deadline. Matched by name so a third one added to
#: `CheckoutRevision` is covered the day it lands rather than the day somebody
#: remembers this file (L96).
READS = re.compile(r"CheckoutRevision\.(read|readIfStale)\(")


def _calls() -> list[tuple[Path, int, str]]:
    """Every call to one of those, with enough of its text to see its arguments.

    A call spans several lines, so this takes the balanced parenthesis run
    rather than one line: a scan reading single lines would find `inRepo:` on
    one and `timeout:` on the next and call the second a different call.
    """
    found = []
    for path in sorted(SWIFT_TESTS.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in READS.finditer(text):
            # A match inside a string literal is prose ABOUT the call, not a
            # call. CheckoutReReadTests asserts on the text
            # `"CheckoutRevision.read(inRepo"` to prove the refresh does not
            # take the unskippable read, and this reported it as an untimed
            # call: a scanner cannot tell a line that MEANS the thing from one
            # that IS it unless it is told (L208). Odd number of unescaped
            # quotes before it on its own line means inside one.
            line_start = text.rfind("\n", 0, match.start()) + 1
            before = text[line_start:match.start()]
            if (before.count('"') - before.count('\\"')) % 2 == 1:
                continue
            depth, i = 0, match.end() - 1
            while i < len(text):
                if text[i] == "(":
                    depth += 1
                elif text[i] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            line = text[:match.start()].count("\n") + 1
            found.append((path, line, text[match.start():i + 1]))
    return found


def test_the_scan_finds_the_calls_at_all():
    """The control. This asserts that something is absent from every call, and
    an absence check whose scan matches nothing passes over everything (L98)."""
    calls = _calls()
    assert len(calls) >= 8, (
        f"only {len(calls)} CheckoutRevision reads found in the Swift tests, so "
        "the check below is nearly vacuous. Either they have gone, or this scan "
        "no longer matches the shape they are written in")


def test_every_checkout_read_in_a_test_names_its_own_deadline():
    inherited = [f"{path.relative_to(REPO_ROOT)}:{line}"
                 for path, line, call in _calls() if "timeout:" not in call]
    assert not inherited, (
        "these tests read a checkout on the product's 5 second deadline: "
        + ", ".join(inherited)
        + ". That budget is for a person waiting on a generation, not for a "
          "test running on a machine the parallel suite is loading. It spends "
          "the 5s across three git subprocesses, and at twelve workers that "
          "failed about one run in three. Pass "
          "`timeout: CheckoutRevision.deadlineForTests`, or an explicit "
          "timeout of your own if the deadline is what you are testing.")


def test_the_test_deadline_is_far_above_the_products():
    """A test-only value that is merely a little larger is the same defect with
    a longer fuse: it still fires under load, just less often (L172)."""
    fixture = (SWIFT_TESTS / "RepoFixture.swift").read_text(encoding="utf-8")
    theirs = re.search(r"deadlineForTests: TimeInterval = (\d+)", fixture)
    assert theirs, "CheckoutRevision.deadlineForTests is gone, so nothing here holds"

    source = next(SWIFT_TESTS.parent.rglob("Services/CheckoutRevision.swift"))
    product = re.search(r"deadline: TimeInterval = (\d+)",
                        source.read_text(encoding="utf-8"))
    assert product, "CheckoutRevision.deadline is gone, so this has nothing to compare"

    assert int(theirs.group(1)) >= int(product.group(1)) * 10, (
        f"the test deadline is {theirs.group(1)}s against the product's "
        f"{product.group(1)}s. Nothing in these tests measures how fast git is, "
        "so a generous number costs a healthy run nothing and is the only thing "
        "stopping a loaded one reporting a defect that is not there")
