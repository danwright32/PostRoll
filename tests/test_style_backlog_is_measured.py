"""#948: the style rule could only ever be asked about what CHANGED.

`check-style-guide.sh` is a pre-push hook and it reads the lines a push ADDS.
Anything that predates it is invisible to it, permanently, and there was no way
to ask it for a total.

That is L223 exactly: a check that finds violations by reading what changed can
never see the backlog that existed before it shipped, which is the population it
exists to find. And a count of new violations sitting at zero reads as the rule
being kept, so nobody re-examines the rest (L182).

#944 was one instance. Six user-facing strings carried an em dash, in violation
of an explicit standing rule, and the hook had never been able to see them. They
were found by putting a screen on the review sheet and reading the rendered
banner, which is not a method that scales.

## What this holds

The words on Dan's SCREEN are held to zero, because #944 cleared them.

The rest is held to not growing, and the numbers are recorded rather than
described. Rewriting a prompt changes what a model is shown and wants reading
sentence by sentence, which #959 did for three files and is separate work for
the others; 337 comments is a bigger piece again. A ratchet is not the same as a
rule being kept, and saying which is which is the whole point (L182).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
BASELINE = REPO_ROOT / "tests" / "fixtures" / "style_backlog.json"


@pytest.fixture(scope="module")
def counted() -> dict[str, list[str]]:
    import sys
    sys.path.insert(0, str(REPO_ROOT))
    from tools.style_backlog import offences
    return offences()


@pytest.fixture(scope="module")
def baseline() -> dict:
    assert BASELINE.is_file(), (
        f"{BASELINE.name} is missing, so there is no measurement to compare "
        f"against and this file would pass by having nothing to check (L98). "
        f"Record it with `venv/bin/python tools/style_backlog.py --record`.")
    return json.loads(BASELINE.read_text(encoding="utf-8"))


def test_the_sweep_reaches_the_tree(counted):
    """The positive control. A sweep finding nothing anywhere would report a
    clean repository and every check below would pass on an empty answer, which
    is the shape this whole file is about (L98, L100)."""
    total = sum(len(lines) for lines in counted.values())

    assert total > 50, (
        f"the sweep found only {total} lines across the whole tree, which is "
        f"not this repository: it is reading the wrong files, or the pattern "
        f"stopped matching")


def test_no_word_on_dans_screen_breaks_the_rule(counted):
    """The half that is actually at zero, and stays there.

    A string literal under PostRollApp/Sources is words on screen. #944 cleared
    six of them; this is what stops a seventh arriving through a path the
    pre-push hook cannot see, such as a file moved rather than edited (L223).
    """
    offending = counted["copyInTheApp"]

    assert not offending, (
        "these are words on Dan's screen and they break the writing style rule "
        "(no em dashes, en dashes or emoji), which applies to app copy and not "
        "only to conversation:\n" + "\n".join(offending))


@pytest.mark.parametrize("kind", ["copyElsewhere", "prose"])
def test_the_backlog_does_not_grow(counted, baseline, kind):
    """The other two are ratchets, and they say so.

    Held to the recorded number rather than to zero, because clearing them is
    separate work: a prompt rewrite changes what a model is SHOWN and wants
    reading sentence by sentence (#959), and 337 comments is a bigger piece
    again. What this stops is the number going UP while nobody is looking.
    """
    now, was = len(counted[kind]), baseline.get(kind)

    assert was is not None, f"{kind} is not in the recorded baseline"
    assert now <= was, (
        f"{kind} grew from {was} to {now}. The pre-push hook only reads the "
        f"lines a push ADDS, so this is how a violation arrives without being "
        f"one: a file moved rather than edited, or a branch that skipped the "
        f"hook. The new ones are:\n"
        + "\n".join(counted[kind][:15]))


def test_a_backlog_that_shrank_is_worth_re_recording(counted, baseline):
    """Not a failure, a nudge. A baseline left above the truth is slack the
    ratchet is not using, and slack that nobody measures is how the number
    creeps back up (L182)."""
    for kind in ("copyElsewhere", "prose"):
        now, was = len(counted[kind]), baseline.get(kind, 0)
        if now < was:
            pytest.skip(
                f"{kind} is down from {was} to {now}. Re-record with "
                f"`venv/bin/python tools/style_backlog.py --record` so the "
                f"ratchet holds the ground that was gained.")


def test_the_tool_holds_no_banned_character_itself(counted):
    """The trap this whole area sets.

    Code that must NAME a forbidden character trips the pre-push hook, which is
    the hook working correctly: it cannot tell the line banning the character
    from the line using it. The tool writes them as escapes, and so does this
    file, so neither holds one.
    """
    for name in ("tools/style_backlog.py", "tests/test_style_backlog_is_measured.py"):
        offending = [line for lines in counted.values() for line in lines
                     if line.startswith(name)]
        assert not offending, (
            f"{name} contains a character it exists to count, so the pre-push "
            f"hook cannot tell it from a violation: {offending}")
