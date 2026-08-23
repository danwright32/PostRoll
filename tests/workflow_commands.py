"""Reading xcodebuild invocations out of a workflow, in one place.

Two guards need this and each would otherwise be a chance to spell the parse
differently: one asks whether anything RUNS the GUI suite, the other whether a
run that hangs can still fail. The failure of a private copy is the quiet kind,
because a parse that matches nothing reports a clean run over an empty set
(L98), so both callers raise on an empty answer rather than passing.

The lines are joined because the interesting words sit at opposite ends of one
backslash continued command: the scheme is in the middle, and whether it is
`test` or `build-for-testing`, and whether test timeouts are enabled, are
elsewhere in it. A check over the whole FILE is answered by any occurrence
anywhere in it (L135), which is exactly how the first of these guards stopped
working.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"


def xcodebuild_commands(text: str) -> list[str]:
    """Every xcodebuild invocation in a workflow, one string each.

    The lines are joined because the interesting words sit at opposite ends of a
    backslash continued command: the scheme is in the middle and whether it is
    `test` or `build-for-testing` is at one end. A check over the whole FILE is
    answered by any occurrence anywhere in it (L135), which is exactly how this
    guard stopped working.
    """
    commands: list[str] = []
    current: list[str] | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if current is None:
            if not stripped.startswith("xcodebuild"):
                continue
            current = [stripped]
        else:
            current.append(stripped)
        if not stripped.endswith("\\"):
            commands.append(" ".join(current))
            current = None
    if current is not None:
        commands.append(" ".join(current))
    return commands


def runs_the_gui_scheme(command: str) -> bool:
    """Whether this invocation EXECUTES the GUI suite rather than compiling it.

    #874 added a `build-for-testing` step on the same scheme to swift.yml, for
    a good reason: nothing local or on a pull request compiled the GUI tests, so
    a dispatched run failed at its build step on an error any compile would have
    caught. It also silently satisfied this guard, which until then only looked
    for the scheme's NAME anywhere in a workflow file. A compile is not a run,
    and #509 deleted the last UI target precisely for being the first without
    the second, so the two have to stay distinguishable here (L220).
    """
    return "-scheme PostRollUITests" in command and "build-for-testing" not in command
