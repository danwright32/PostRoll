"""What running the Swift suite in PARALLEL broke, and the rules that hold it (#992).

Two defects, one cause. #992 made the Swift suite run on as many worker
processes as the machine has cores, and both of these were latent assumptions
that only one thing was ever waiting at a time. They are kept in one file
because they were found by one investigation and the second only made sense
once the first had been ruled out.

## The reading that separated them

`CheckoutRevisionTests` began failing about one run in three at twelve workers.
The first theory was load, so the test's deadline went from 5s to 120s. **The
failures moved to 121s.** That is the whole diagnosis in one measurement: a slow
thing does not grow to fill whatever budget it is given, and a wait that never
started does. It was not contention for the CPU, it was a block with no thread.

So both rules below are here, and each is real on its own:

* `CheckoutRevision.output()` parked two BLOCKING waits on `DispatchQueue.global()`,
  a bounded pool that does not grow to order. Six test classes in this suite
  spawn processes, several share one worker and one pool, and a later block then
  never runs at all (L241). Fixed with a dedicated `Thread` each.
* The tests inherited the PRODUCT's 5 second deadline, which is a budget for a
  person waiting on a generation, not for a machine the parallel suite is
  loading. A test timing git that way is asserting about how busy the runner is
  (L290, L522).

Both are checked by scanning source, because both were written correctly for a
serial world and the next call site will be written by copying one of them.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES = REPO_ROOT / "PostRollApp" / "Sources"
SWIFT_TESTS = REPO_ROOT / "PostRollApp" / "Tests"


# ── a blocking wait must not sit on the bounded pool (L241) ───────────────────

#: Calls that park a thread until something else happens. Named by what they DO
#: rather than by the two this bug happened to use, so a third blocking call is
#: covered the day it lands (L96).
BLOCKING = re.compile(
    r"\b(waitUntilExit|readDataToEndOfFile|\.wait\(\)|DispatchSemaphore[^\n]*\.wait\(\))")

#: The bounded pool. `asyncAfter` is deliberately not matched: it schedules and
#: returns, which is not the shape that starves anything.
GLOBAL_ASYNC = re.compile(r"DispatchQueue\.global\([^)]*\)\s*\.async\s*\{")


def _blocks(text: str) -> list[tuple[int, str]]:
    """Each `DispatchQueue.global().async { ... }` body, with its line number."""
    found = []
    for match in GLOBAL_ASYNC.finditer(text):
        depth, i = 0, match.end() - 1
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        found.append((text[:match.start()].count("\n") + 1, text[match.end():i]))
    return found


def test_no_blocking_wait_is_parked_on_the_global_queue():
    offenders = []
    for path in sorted(SOURCES.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for line, body in _blocks(text):
            hit = BLOCKING.search(body)
            if hit:
                offenders.append(
                    f"{path.relative_to(REPO_ROOT)}:{line} blocks on {hit.group(1)!r}")
    assert not offenders, (
        "these park a blocking wait on the bounded global pool: "
        + ", ".join(offenders)
        + ". Give each its own Thread. The pool does not grow to order, so once "
          "enough blocking work sits on it a later block never gets a thread at "
          "all, and that reads as the thing it was waiting for having hung. "
          "Measured on 2026-08-30: CheckoutRevisionTests failed about one run in "
          "three under the parallel suite, and raising its deadline from 5s to "
          "120s moved the failure to 121s rather than fixing it (L241).")


def test_the_scan_can_see_a_blocking_wait_on_the_pool():
    """The guard's own mechanism, on a fixture (L1). This asserts an absence, and
    an absence check whose scan stopped matching passes over everything."""
    bad = ("DispatchQueue.global().async {\n"
           "    process.waitUntilExit()\n"
           "    done.signal()\n"
           "}\n")
    blocks = _blocks(bad)
    assert len(blocks) == 1, f"the block scan found {len(blocks)}, not 1"
    assert BLOCKING.search(blocks[0][1]), "a plain waitUntilExit was not matched"


def test_a_timer_on_the_pool_is_not_flagged():
    """`asyncAfter` schedules and returns. Flagging it would refuse the
    deliberate use in ProcessRunner.tearDown, and a guard that fires on correct
    code is one people learn to bypass (L36)."""
    timer = ("DispatchQueue.global().asyncAfter(deadline: .now() + grace) {\n"
             "    process.terminate()\n"
             "}\n")
    assert not _blocks(timer), "an asyncAfter timer was read as a blocking dispatch"


# ── a test must not inherit the product's deadline (L290, L522) ───────────────

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
