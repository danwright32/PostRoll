"""Every `make` target a person can run is named in the README (#796).

The README's fingerprint section documented `make record-fingerprints`, which
answers one of the two questions the design fingerprint guard asks, and said
nothing about `make record-design-change`, which answers the other. That is the
worse half to omit: the second command exists precisely because the sequence for
a DELIBERATE design change kept being done in the wrong order (#786), and a
section naming one door sends the reader through the one that was going wrong.
`make test-python-fast` and `make record-test-durations` (#766) were missing the
same way.

Held to the Makefile rather than to a list kept here, because a list of what is
documented, maintained beside the thing it describes, drifts exactly as the
prose did (L41). The targets are read out of the Makefile, so a new one is
undocumented until somebody writes the line, and a renamed one takes its
documentation with it.

Every function raises rather than returning an empty answer, for the reason
`ci_workflow.py` gives: a scan that has stopped matching would report a README
documenting every target at the moment it can see no target at all (L98, L100).
"""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
MAKEFILE = REPO_ROOT / "Makefile"
README = REPO_ROOT / "README.md"


def targets() -> list[str]:
    """Every rule in the Makefile, by name.

    Rules only: a line like `BUILD_LOCK := ...` is a variable, and `.PHONY` is a
    directive, so both are excluded by requiring the name to start with a
    letter and the colon to be a plain one.
    """
    found = re.findall(
        r"^([a-z][a-z0-9-]*):(?!=)", MAKEFILE.read_text(encoding="utf-8"), re.M)
    assert len(found) >= 10, (
        f"only {found} look like Makefile rules, which is not this Makefile. "
        "The scan has stopped matching, and a README holding to nothing passes.")
    return sorted(set(found))


def documented(target: str, readme: str) -> bool:
    """Whether the README names `make <target>` as itself.

    The boundary matters in both directions: `make test` must not be answered by
    the line documenting `make test-python`, and `make record-fingerprints` must
    not be answered by a longer target nobody has written yet.
    """
    return re.search(rf"\bmake {re.escape(target)}(?![\w-])", readme) is not None


def test_the_readme_names_every_target():
    readme = README.read_text(encoding="utf-8")
    missing = [name for name in targets() if not documented(name, readme)]

    assert not missing, (
        f"the Makefile has targets the README never names: {missing}. A command "
        "that exists and is written down nowhere is found by reading the "
        "Makefile, which is the thing the README is for. Add a line saying what "
        "each one is for, or delete the target.")


#: The two commands that answer the design fingerprint guard's question.
#:
#: They are only useful as a pair. The guard asks which of two things happened,
#: the template renders differently and the version has to be bumped, or it
#: renders identically and only the record moves, and there is one command for
#: each answer. Either one read alone looks like THE answer.
DESIGN_CHANGE_DOORS = ("record-fingerprints", "record-design-change")


def test_both_doors_for_a_design_change_are_in_one_section():
    """Not merely both present in the file: both in the SAME section.

    A reader arrives here holding a red fingerprint guard and reads the section
    it sent them to. A command documented three screens away is a command they
    do not find, which is the state the README was already in: it named the door
    for a rendering that did NOT change and said nothing about the one for a
    deliberate redesign, which is the sequence that kept being done in the wrong
    order (#786).

    Found by which section names the commands rather than by the heading's
    wording, so rephrasing the heading is not a failure and deleting half the
    content is (L103).
    """
    sections = README.read_text(encoding="utf-8").split("\n## ")
    assert len(sections) >= 4, (
        f"the README splits into {len(sections)} `## ` sections, which is not "
        "this file, so this check is reading nothing")

    holding = [s for s in sections if any(documented(c, s) for c in DESIGN_CHANGE_DOORS)]
    assert len(holding) == 1, (
        f"{len(holding)} sections of the README name one of {list(DESIGN_CHANGE_DOORS)}. "
        "The two commands answer the two halves of one question and belong in "
        "one place: split across sections, whichever the reader lands in reads "
        "as the whole answer.")
    for command in DESIGN_CHANGE_DOORS:
        assert documented(command, holding[0]), (
            f"the design change section does not name `make {command}`. It has "
            "to document which of the two cases each command answers, because a "
            "section naming one of them sends the reader down the path that was "
            "going wrong (#786).")


def test_every_target_is_declared_phony():
    """None of these rules produce a file, so all of them are .PHONY.

    A rule left out of the list works until a file or folder of that name
    appears beside the Makefile, and then make declares the target up to date
    and runs nothing, with no error and no output to say so. `install` would
    silently stop installing the day somebody made a folder called `install`.

    `record-test-durations` and `record-design-change` were both missing, which
    is how this was found: they were added as rules and the declaration above
    them, which is a separate line, was not extended (L41).
    """
    # Read across backslash continuations, the way make does. A pattern
    # stopping at the first newline would read only the first line of a wrapped
    # declaration and report every name below it as missing, which is a guard
    # failing on its own shape rather than on the Makefile's.
    phony = re.search(
        r"^\.PHONY:((?:[^\n\\]*\\\n)*[^\n]*)",
        MAKEFILE.read_text(encoding="utf-8"), re.M)
    assert phony, "the Makefile declares no .PHONY at all"

    declared = set(phony.group(1).replace("\\", " ").split())
    missing = [name for name in targets() if name not in declared]

    assert not missing, (
        f"these Makefile rules are not in .PHONY: {missing}. A file of that "
        "name in the repo root would make each one a no-op that reports "
        "success.")
