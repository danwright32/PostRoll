"""The colour rules that only read Swift SOURCE TEXT, in Python (#1045).

These lived in `BannerLegibilityTests`, where every one of them cost an app
build to re-prove. The guard sweep re-proves the registry entries a diff
touches, and 33 of them name that file: measured on 2026-08-31, 15 of those 33
name a rule that reads nothing but text, at about 29s each, which is 7 to 8
minutes on any pull request whose diff selects them. Over 2026-08-30 and 31 the
`Guard proofs / changed` job was the only thing holding four separate merges,
for 15 to 19 minutes each, with every other check already green.

Nothing about the rules changes here. They are the same predicates over the same
text, and the fixtures that prove each matcher sees every spelling are carried
across verbatim, because that is the only thing that CAN prove them: the tree is
clean, so a matcher that sees one spelling and a matcher that sees three give the
same silent pass over the real files (L48, L159). The Swift versions shipped
narrow twice for exactly that reason and were caught by their fixtures, not by
the codebase.

Read with comments stripped and string literals LEFT IN, which is what
`appSource` did. That is deliberate and not the same as `swift_code_only`: a
colour written inside a string is still a colour written at the point of use as
far as these rules are concerned, and stripping literals here would quietly
widen every exemption.
"""

from __future__ import annotations

import re
from pathlib import Path

from source_text import swift_without_comments, text_of

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES = REPO_ROOT / "PostRollApp" / "Sources"

#: The file the named colours are DECLARED in, which is the one place they are
#: allowed to be written as values.
PALETTE = "PaintedSurfaces.swift"

#: The two modifiers that fill an area, plus the four that draw a line or a
#: shadow rather than an area (#628). The four were outside the rule entirely,
#: and 31 borders had been written at the point of use while the check read as
#: covering every painted surface in the app. Exempt from being MEASURED for
#: contrast is not exempt from being NAMED.
PAINTING_MODIFIERS = (".background(", ".fill(", ".stroke(",
                      ".strokeBorder(", ".border(", ".shadow(")

#: A colour mentioned by value: named, or built from literal components (#600).
NAMES_A_COLOUR = re.compile(r"Color\.[A-Za-z]")
BUILDS_A_COLOUR = re.compile(r"Color\(\s*(red|white|hue|nsColor|\.)")

#: A colour used as a VIEW, at the start of the line, with anything after it.
#:
#: Anything after it, because a painted area routinely carries its modifiers on
#: the same line (`Color.creamDeep.overlay { … }`). The first Swift version
#: ended the pattern at the line break and saw the ten sites written with
#: nothing after the colour and none of the thirteen written with a modifier.
#: All thirteen had already been named by hand, so the suite was green and the
#: check looked like it worked (L1).
COLOUR_AS_A_VIEW = re.compile(r"^Color(\.[A-Za-z][A-Za-z0-9]*\b|\(\s*(red|white|hue)\b)")


def every_source_file() -> list[str]:
    """Every Swift file under Sources, except the palette itself.

    One walk shared by both sweeps rather than a copy each, so widening the tree
    cannot reach one of them and leave the other reading a subset nobody
    notices (L16).
    """
    found = sorted(str(path.relative_to(SOURCES))
                   for path in SOURCES.rglob("*.swift")
                   if path.name != PALETTE)
    assert found, (
        f"no Swift files under {SOURCES}, so every sweep over them would pass "
        "over nothing (L98)")
    return found


def app_source(relative: str) -> str:
    """One file under Sources, with its comments blanked and its strings kept."""
    return swift_without_comments(text_of(SOURCES / relative))


def unnamed_fills(code: str) -> list[tuple[int, str]]:
    """Lines painting a background or a shape from a colour written there.

    A line offends when it calls one of the painting modifiers AND mentions a
    colour by value. `PaintedSurfaces.x`, a local, or a computed pair mention no
    colour and pass.

    Read per LINE rather than over the whole file, so the failure names the line
    and so a colour reached through a ternary or built from numbers is caught
    too (#600): the first version looked for the literal text `.background(Color.`
    and a condition between the bracket and the colour walked straight past it.

    `Color.clear` is excluded because it paints nothing: it is a spacer and a hit
    area, with no surface behind any words. Excluded by name here so the
    exemption is one decision written down once (L129).
    """
    found = []
    for number, raw in enumerate(code.split("\n"), start=1):
        line = raw.strip()
        if not any(modifier in line for modifier in PAINTING_MODIFIERS):
            continue
        if not (NAMES_A_COLOUR.search(line) or BUILDS_A_COLOUR.search(line)):
            continue
        if "Color.clear" in line:
            continue
        found.append((number, line))
    return found


def bare_colour_views(code: str) -> list[tuple[int, str]]:
    """Lines where a colour is used as a view, with its 1-based line number.

    A colour is a view in its own right, so it paints an area with no modifier
    around it at all, and `unnamed_fills` cannot express that. Seven
    placeholders were drawn this way while the file reported a clean sweep over
    the same screens (#586), which is worse than not checking them: an
    unreadable spelling and an absent surface look identical from there.
    """
    found = []
    for number, raw in enumerate(code.split("\n"), start=1):
        line = raw.strip()
        if not COLOUR_AS_A_VIEW.match(line):
            continue
        if line.startswith("Color.clear"):
            continue
        found.append((number, line))
    return found


# ── statements, so a wrapped ternary is one string to match against ──────────

#: A string literal, so its contents cannot be counted as structure.
A_STRING = re.compile(r'"(\\.|[^"\\])*"')


def bracket_balance(line: str) -> int:
    """Open brackets minus closed ones, counting neither inside a string.

    A bracket inside a sentence is not structure. Left uncounted, a statement
    never closes and everything after it joins on, and the rules above would
    then report matches in code nobody wrote (#630).

    A multi-line literal's delimiter line carries no structure of its own.
    """
    if '"""' in line:
        return 0
    bare = A_STRING.sub('""', line)
    return bare.count("(") - bare.count(")")


def statements(code: str) -> list[str]:
    """Source rejoined into statements, by bracket depth.

    A modifier and the colours a wrapped ternary chooses become one string.

    A WINDOW of lines cannot do this, and the first Swift version of the
    widened accent rule was one: it read two lines, the real ternary in
    `PhotoAssignmentView` spans three, and the guard went green on the mutation
    written for it while passing the two-line case it had been shaped around
    (L144). Depth is a property of the code rather than a number measured off
    whichever spelling happened to exist that day.
    """
    out: list[str] = []
    buffer = ""
    depth = 0
    for raw in code.split("\n"):
        line = raw.strip()
        buffer = line if not buffer else buffer + " " + line
        depth += bracket_balance(line)
        if depth <= 0:
            if buffer:
                out.append(buffer)
            buffer = ""
            depth = 0
    if buffer:
        out.append(buffer)
    return out


def unnamed_accent_uses(code: str) -> list[str]:
    """Statements drawing the raw accent in a role that has a name for it.

    Both of the ways a colour reaches a control: as a foreground, and as the
    tint a spinner, a slider or a picker draws itself in. `tint(` is matched on
    the lowercased statement so `listRowSeparatorTint` and any other spelling
    ending in it are the same rule rather than a way round it (#591).

    `roseGold` measures 4.31:1 on the page: right for a symbol or a rule, under
    the line for a label, and it was drawn as both in about ninety places. Ink
    cannot report it, because this type draws perfectly well and is simply too
    pale, so the only thing that can is the call site saying what it is drawing.
    """
    return [statement for statement in statements(code)
            if ("foreground" in statement or "tint(" in statement.lower())
            and "Color.roseGold" in statement]
