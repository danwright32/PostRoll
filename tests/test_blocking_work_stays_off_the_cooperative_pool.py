"""#1143: blocking work was being detached onto Swift's cooperative pool.

`Task.detached` does not give work a thread of its own. It puts it on the
cooperative pool, which is sized to the machine's cores and does not grow. A
blocked item there occupies a pool thread doing nothing, and enough of them
starve every other piece of concurrent work in the process (L241).

The tell is what makes this expensive to diagnose rather than expensive to
suffer: the failure is far larger than its cause and points everywhere at once.
It does not present as the blocked operation complaining, it presents as
everything else stopping. downbeat#406 was the same fix in a sibling app, where
a suite whose fixtures blocked a handful of cooperative threads killed the test
process partway through and reported 1,835 failures that were one starved
runtime.

## What this file checks

That no `Task.detached` closure in the app reaches work that WAITS on something
outside the process. The subjects are enumerated from the source rather than
listed here, because a guard is only as wide as its hand-written registry (L96)
and the fix for that is deriving the subjects from the state that makes them
subjects (L247): a function is blocking if it waits for a subprocess to exit or
on a semaphore, or if anything it calls does.

Deliberately NOT every slow thing. Decoding an image, walking a directory and
scanning a store are CPU and local disk. They always finish, and the cooperative
pool is exactly where they belong; sweeping them in would make this fire on
almost every screen and stop being read (L36).

## What it cannot check

That the fix works. Reading `Blocking.run` proves nothing about whether it runs
somewhere else (L3), so `BlockingWorkTests` in the Swift suite saturates the
cooperative pool and requires the work to finish anyway.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES = REPO_ROOT / "PostRollApp" / "Sources"

#: What it means to block, as the primitives it is written with.
#:
#: Both are waits on something this process does not control: a child that has
#: to exit, and a signal something else has to send. That is the whole class,
#: and it is why local file reads are not in it however slow a disk is.
BLOCKING_PRIMITIVES = ("waitUntilExit()", "DispatchSemaphore")

#: Functions that are blocking for a reason no primitive spells out.
#:
#: `Data(contentsOf:)` is a local file read at almost every call site in this
#: app and a NETWORK read at this one, which is what `bytes` exists for, so the
#: primitives cannot tell them apart and the distinction is recorded here with
#: its reason rather than left out (L233).
BLOCKING_BY_JUDGEMENT = {
    "ImageLoad.bytes": "Data(contentsOf:) against a URL that may be remote, "
                       "which blocks the thread for as long as the far end "
                       "takes and has no bound this side can set",
}

DECLARATION = re.compile(
    r"^(\s*)(?:@\w+\s+)*(?:public |private |internal |fileprivate |nonisolated "
    r"|static |class |final |override )*func\s+(\w+)")


def functions() -> dict[str, str]:
    """Every function in the app's sources, as `File.name`, with its body."""
    bodies: dict[str, list[str]] = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        current: str | None = None
        for line in path.read_text(encoding="utf-8").splitlines():
            found = DECLARATION.match(line)
            if found:
                current = f"{path.stem}.{found.group(2)}"
                bodies.setdefault(current, [])
            elif current is not None:
                bodies[current].append(line)
    return {name: "\n".join(body) for name, body in bodies.items()}


def blocking_functions() -> dict[str, str]:
    """Every function that waits on something outside the process, and why.

    Closed over calls, so a function that merely CALLS a blocking one is
    blocking too. That transitive step is the whole point: the site this issue
    came from called `BuildFreshness.check`, and it is `commitTime` underneath
    that runs git, so a one hop check would have reported the call site as fine.

    A call counts the way Swift writes it: bare inside the same file, because a
    type calls its own members by name, and qualified from anywhere else. A
    first version matched bare names everywhere and reported eleven call sites,
    because `read(`, `scan(` and `reclaim(` are names half the app uses, and a
    check that fires on everything is one nobody reads (L36). A second matched
    qualified names everywhere and found neither `CheckoutRevision.read` nor
    `BuildFreshness.check`, which are the two the issue is about, because each
    calls its own blocking helper unqualified.

    What the pair still cannot see is a blocking method reached through an
    INSTANCE of another type. Recorded rather than hidden: every member of this
    class today is an enum of static functions, and the Swift test beside this
    one is what proves the fix itself rather than its spelling.
    """
    bodies = functions()
    why: dict[str, str] = dict(BLOCKING_BY_JUDGEMENT)
    for name, body in bodies.items():
        for primitive in BLOCKING_PRIMITIVES:
            if primitive in body:
                why.setdefault(name, f"waits on {primitive}")

    changed = True
    while changed:
        changed = False
        for name, body in bodies.items():
            if name in why:
                continue
            reached = sorted(call for call in why
                             if calls(body, call, fromFile=name.split(".")[0]))
            if reached:
                why[name] = f"calls {reached[0]}, which blocks"
                changed = True
    return why


def calls(body: str, target: str, fromFile: str) -> bool:
    """Whether `body`, which lives in `fromFile`, calls `target`."""
    owner, method = target.split(".", 1)
    return f"{method}(" in body if owner == fromFile else f"{target}(" in body


def outside_the_helper(text: str) -> str:
    """`text` with every `Blocking.run { ... }` region removed.

    A detached task that hands the blocking part to the helper is the shape
    this whole file is asking for, so it must not read as the defect. The
    remedy has to be reachable from the message that names it (L109, L111), and
    without this the only way to satisfy the check would be to stop detaching
    the non-blocking half too.

    Braces are counted rather than matched properly, which is enough for the
    shape these are written in and fails in the SAFE direction: an unbalanced
    region swallows the rest of the closure and the check goes quiet, so the
    test below asserts the removal leaves something behind.
    """
    out: list[str] = []
    depth = 0
    for line in text.splitlines():
        if depth == 0 and "Blocking.run" in line:
            depth = 1 + line.count("{") - line.count("}") - 1
            if depth <= 0:
                depth = 0
                continue
            continue
        if depth > 0:
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                depth = 0
            continue
        out.append(line)
    return "\n".join(out)


def detached_closures() -> list[tuple[str, str, str]]:
    """Every `Task.detached` in the app, as (file, enclosing function, text).

    The text is the rest of the statement rather than a parsed closure: the
    bodies here are one to five lines, and a brace matcher would be a second
    thing to get wrong for no more coverage.
    """
    found: list[tuple[str, str, str]] = []
    for path in sorted(SOURCES.rglob("*.swift")):
        lines = path.read_text(encoding="utf-8").splitlines()
        current = "(top level)"
        for n, line in enumerate(lines):
            declared = DECLARATION.match(line)
            if declared:
                current = declared.group(2)
            if "Task.detached" in line:
                found.append((path.name, current,
                              "\n".join(lines[n:n + 6])))
    return found


def test_the_enumeration_finds_the_blocking_work_it_is_supposed_to():
    """The positive control. A matcher that found nothing would report every
    detached closure as safe and this file would guard nothing (L100, L98)."""
    blocking = blocking_functions()

    assert "CheckoutRevision.read" in blocking, sorted(blocking)[:20]
    assert "BuildFreshness.check" in blocking, (
        "the transitive step is not working: `check` does not run git itself, "
        "`commitTime` does, and the call site this issue came from called "
        "`check`")
    assert "ImageLoad.bytes" in blocking


def test_the_enumeration_leaves_ordinary_slow_work_alone():
    """The other direction, and the one that decides whether this gets read.

    Decoding an image and scanning a folder are CPU and local disk. Sweeping
    them in would fire on almost every screen, and an alert that cries wolf gets
    ignored (L36).
    """
    blocking = blocking_functions()

    for ordinary in ("DesignStaleScan.scan", "MissingMediaScan.scan"):
        assert ordinary not in blocking, (
            f"{ordinary} is being treated as blocking. It is local disk work "
            f"that always finishes, and the cooperative pool is where it "
            f"belongs: {blocking.get(ordinary)}")


@pytest.mark.parametrize(
    "site", detached_closures(),
    ids=lambda s: f"{s[0]}:{s[1]}" if isinstance(s, tuple) else str(s))
def test_no_detached_task_reaches_work_that_waits_on_the_outside(site):
    file, function, text = site
    blocking = blocking_functions()

    body = outside_the_helper(text)
    reached = sorted(name for name in blocking
                     if calls(body, name, fromFile=Path(file).stem))

    assert not reached, (
        f"{file}.{function} detaches work that reaches {reached}, which waits "
        f"on something outside this process ({blocking[reached[0]]}). "
        f"`Task.detached` puts it on the cooperative pool, which is sized to "
        f"the cores and does not grow, so enough of these starve every other "
        f"piece of concurrent work in the app and the failure presents as "
        f"everything else stopping rather than as this complaining (#1143, "
        f"L241). Use `Blocking.run` instead.")


def test_handing_the_blocking_part_to_the_helper_is_not_the_defect():
    """The remedy the message names has to actually clear the state it names
    (L111), and it has to leave the rest of the closure visible: a region
    remover that swallowed everything would silence this check entirely (L98)."""
    closure = "\n".join([
        "        Task.detached {",
        "            try? await Task.sleep(for: .seconds(timeout))",
        "            await Blocking.run { Self.tearDown(p, grace: grace) }",
        "            somethingElse()",
        "        }",
    ])

    left = outside_the_helper(closure)

    assert "tearDown" not in left
    assert "somethingElse()" in left, (
        "the remover swallowed the rest of the closure, so anything after a "
        "Blocking.run is invisible to this check")
    assert "Task.sleep" in left


def test_the_helper_the_message_names_actually_exists():
    """A message that tells somebody how to recover has to name a step that
    changes the state they are stuck in (L111)."""
    helper = SOURCES / "Services" / "Blocking.swift"

    assert helper.is_file(), f"{helper} does not exist"
    text = helper.read_text(encoding="utf-8")
    assert "DispatchQueue.global" in text, (
        "Blocking.run no longer leaves the cooperative pool, so every call site "
        "moved onto it is back where it started")
    assert "Task.detached" not in text.replace("`Task.detached`", ""), (
        "Blocking.run detaches, which is the thing it exists to avoid")
