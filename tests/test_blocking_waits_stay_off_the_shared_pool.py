"""A blocking wait must not be parked on `DispatchQueue.global()` (L241, #992).

`DispatchQueue.global()` is a bounded pool. It does not grow to order, so work
that BLOCKS on it, rather than doing something and returning, can leave later
blocks with no thread to run on at all. The symptom is not slowness. It is a
block that never starts, which reads as the thing it was waiting for having
hung.

## Measured, because this was shipped and then found

`CheckoutRevision.output()` dispatched two blocking waits onto the global queue,
one `readDataToEndOfFile()` and one `waitUntilExit()`. It was fine for years,
because the app runs one of these at a time from the window.

Then #992 made the Swift suite run in parallel. Six test classes here spawn
processes, several land in one worker process sharing one pool, and on
2026-08-30 `CheckoutRevisionTests` began failing about one run in three.

The reading that identified it: raising the test's deadline from 5s to 120s did
NOT fix it. The failures moved from 5.5s to 121.5s. A slow thing does not grow
to fill whatever budget it is given; a wait that never started does. That is the
difference between "the machine is loaded" and "the block has no thread", and it
is the only cheap way to tell them apart from the outside.

Fixed by giving each blocking wait its own `Thread`, which cannot be starved by
a saturated pool.

## What this refuses, and what it does not

Only a BLOCKING call inside a `DispatchQueue.global()` block. `asyncAfter` used
as a timer is fine and is left alone: it schedules and returns.
`ProcessRunner.tearDown` uses one, deliberately, and this must not drag it in.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES = REPO_ROOT / "PostRollApp" / "Sources"

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
