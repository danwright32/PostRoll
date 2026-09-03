"""Where the Mac build setup lives, read in one place (#1249).

Selecting the pinned Xcode, installing XcodeGen and generating the project were
written out in `swift.yml`, `guards.yml` and `ui.yml`, four copies of the same
three steps across three files. Changing any of it meant finding all four, and
missing one failed on whichever job was forgotten rather than at the point of
the change.

The duplication also broke a guard the first time it appeared. Every entry in
`tests/fixtures/guard_mutations` pins its target with a `find` that must match
its file exactly once, so a second copy of the Xcode pin inside ONE file made
`ci-selects-the-recorded-xcode` unresolvable and the guard proofs failed with
"matches 2 places ... the registry is stale".

Every reader here RAISES on an empty answer rather than returning one, for the
reason this repository keeps rediscovering: a parse that matches nothing reports
a clean run over an empty set (L98), and these readers exist to answer questions
whose safe-looking answer is exactly the empty one.
"""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
ACTION = REPO_ROOT / ".github" / "actions" / "prepare-mac-build" / "action.yml"

#: How a workflow step calls the action. GitHub resolves a local action by this
#: path from the repository root.
ACTION_REF = "./.github/actions/prepare-mac-build"

#: The setup itself, as the strings that DO each part of it. A workflow holding
#: any of these outside the action has its own copy again.
SETUP_MARKERS = (
    "PostRollApp/.ci-xcode-version",
    "xcode-select --switch",
    "brew install xcodegen",
    "xcodegen generate",
)


def action_text() -> str:
    if not ACTION.exists():
        raise AssertionError(
            f"{ACTION} is missing, so every workflow that calls it fails at its "
            "first step and nothing here can say what the setup is")
    return ACTION.read_text()


def workflow_texts() -> dict[str, str]:
    """Every workflow, by file name."""
    texts = {path.name: path.read_text() for path in sorted(WORKFLOWS.glob("*.yml"))}
    if not texts:
        raise AssertionError(
            f"no workflows were read out of {WORKFLOWS}, so every check over "
            "them would pass across an empty set")
    return texts


def uncommented(text: str) -> str:
    """The text with comment lines dropped.

    Every one of these files explains itself in prose that names the very
    commands being checked for, so a scan of the raw text is answered by a
    comment describing a rule that was deleted (L103).
    """
    return "\n".join(line for line in text.splitlines()
                     if not line.strip().startswith("#"))


def jobs(text: str) -> dict[str, str]:
    """Each job in a workflow, by name, comments dropped.

    Per job rather than per file, because a claim about one job is otherwise
    satisfied by something sitting in another (L135).
    """
    if "\njobs:" not in text:
        raise AssertionError("this workflow has no jobs: block")
    found: dict[str, list[str]] = {}
    current: str | None = None
    for line in uncommented(text.split("\njobs:", 1)[1]).splitlines():
        header = re.match(r"^  ([A-Za-z][\w-]*):\s*$", line)
        if header:
            current = header.group(1)
            found[current] = []
        elif current is not None:
            found[current].append(line)
    if not found:
        raise AssertionError(
            "no jobs were read out of this workflow, so every check over them "
            "passed across an empty set (L98)")
    return {name: "\n".join(body) for name, body in found.items()}
