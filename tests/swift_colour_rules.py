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


# ── the faint tone, and the one role that is exempt from the floor ───────────

#: The tone under the contrast floor. 2.43:1 on the page, under the 4.5:1 body
#: text needs and under even the 3:1 an interface element needs, and it was the
#: foreground of 14 text draws across three screens with nothing reporting it:
#: the pair registry never held it, so the harness built to catch exactly this
#: had never been given it (#611, L143).
FAINT_TONE = "Color.warmFaint"

#: Its one honest role, which WCAG 1.4.3 exempts: the label of a control that is
#: switched off.
DISABLED_LABEL = "PaintedSurfaces.disabledControlLabel"

#: How far either side of the label to look for the thing being switched off.
#: Two back and six forward, which is where a modifier chain puts `.disabled(`
#: relative to the foreground that sets the colour.
DISABLED_WINDOW_BACK, DISABLED_WINDOW_FORWARD = 2, 6


def raw_faint_tone_uses(code: str) -> list[str]:
    """Lines drawing the faint tone by name, wherever in the line it appears.

    Per line rather than per statement on purpose: the half of a wrapped ternary
    that names the colour carries no modifier at all, and it is still a draw.
    """
    return [line for line in (raw.strip() for raw in code.split("\n"))
            if FAINT_TONE in line]


def faint_labels_on_live_controls(code: str) -> list[tuple[int, str]]:
    """Lines drawing the exempt colour with no `.disabled(` near them.

    An exemption with no reviewer is the same as no rule (L129), so this is the
    reviewer: the exempt colour has to be on a control that is switched off, or
    it is ordinary type wearing 2.43:1 that no other check will ever object to.
    """
    lines = [raw.strip() for raw in code.split("\n")]
    found = []
    for number, line in enumerate(lines, start=1):
        if DISABLED_LABEL not in line:
            continue
        index = number - 1
        window = lines[max(0, index - DISABLED_WINDOW_BACK):
                       index + DISABLED_WINDOW_FORWARD + 1]
        if any(".disabled(" in near for near in window):
            continue
        found.append((number, line))
    return found


# ── the platform's own colours are never type ────────────────────────────────

#: A system colour handed to a foreground or a tint (#598).
#:
#: One rule over the whole tree rather than a scoped copy per screen. #590 and
#: #596 each banned these inside one declaration, which leaves the next screen
#: exempt by default and makes the guard's reach a list of the places somebody
#: had already thought about (L96).
SYSTEM_COLOUR_FOREGROUND = re.compile(
    r"(foregroundStyle|foregroundColor|tint)\(\s*\."
    r"(white|black|red|orange|yellow|green|blue|purple|pink|brown|"
    r"gray|grey|mint|teal|cyan|indigo|secondary|primary|accentColor)\b")


def system_colour_foregrounds(code: str) -> list[str]:
    """Lines drawing type in one of the platform's own colours."""
    return [line for line in (raw.strip() for raw in code.split("\n"))
            if SYSTEM_COLOUR_FOREGROUND.search(line)]


# ── type is never drawn in a colour written at the point of use (#620) ───────

#: A declaration whose body IS a colour, so the statement after it is that body.
DECLARES_A_COLOUR = re.compile(r"(->|:)\s*Color\s*\{")

#: A named colour, anywhere in a statement.
A_NAMED_COLOUR = re.compile(r"Color\.[A-Za-z][A-Za-z0-9]*")


def brace_balance(line: str) -> int:
    """Open braces minus closed ones, counting neither inside a string (#630).

    Why this exists rather than the one-statement lookahead it replaced: a
    colour-returning helper is only ONE statement when its body is one
    expression. Give it an `if` or a `switch` and its colours sit in the
    statements after that, where the lookahead could not see them, so the exact
    defect the lookahead was added for came back the moment the helper grew a
    branch.
    """
    if '"""' in line:
        return 0
    bare = A_STRING.sub('""', line)
    return bare.count("{") - bare.count("}")


def raw_type_colour_uses(code: str) -> list[str]:
    """Statements putting a raw palette colour on type.

    Which statements can put a colour on type: the two modifiers, plus `return`,
    plus the body of anything declared `-> Color`, because a colour handed to a
    foreground by a helper is type just as much as one written into the
    modifier.

    Each of those three was added because the sweep was found blind to it.
    `ProgramUploadView.colour(isHere:done:blocked:)` and
    `OCRReviewView.confidenceColor` sat outside the modifiers and between them
    held the raw accent, two of the platform's own state colours and a tone at
    1.60:1. Then the mutation written for this very guard put a raw colour back
    into the FIRST of those and it stayed green, because that helper is one
    expression with no `return` in it at all: the statement after a `-> Color`
    declaration is its body (L1).

    `Color.clear` draws nothing, so a statement whose only colour is that one is
    not a draw.
    """
    type_bearing: list[str] = []
    depth = 0
    colour_body_depth: int | None = None

    for statement in statements(code):
        if ("foreground" in statement
                or "tint(" in statement.lower()
                or "return " in statement
                or colour_body_depth is not None):
            type_bearing.append(statement)

        before = depth
        depth += brace_balance(statement)

        if (colour_body_depth is None
                and DECLARES_A_COLOUR.search(statement)
                and depth > before):
            colour_body_depth = before
        elif colour_body_depth is not None and depth <= colour_body_depth:
            colour_body_depth = None

    return [statement for statement in type_bearing
            if any(found != "Color.clear"
                   for found in A_NAMED_COLOUR.findall(statement))]


#: The files that DECLARE colours rather than draw with them, and why.
#:
#: Written down rather than left as a silent hole in the sweep, and checked in
#: both directions: an entry naming a file with nothing to exempt fails too,
#: because a stale exemption quietly covers whatever drifts into its place
#: (L129, L96).
DECLARES_ITS_OWN_COLOURS: dict[str, str] = {
    "Views/BrandBanner.swift":
        "declares the banner palette itself, and PaintedSurfaces.all reads its "
        "background, icon, text and action colours straight out of it to build "
        "the banner pairs. It is a naming site like PaintedSurfaces, so a rule "
        "against naming colours here would be a rule against the thing that "
        "makes the banners measurable",
    "Services/CollageRenderer.swift":
        "draws a photographic collage rather than app chrome. Its colours are "
        "print matting inside an exported image, held by the design version "
        "fingerprint guards rather than by contrast against a screen nobody "
        "reads them on",
}


# ── the quiet tone only ever dresses a mark (#629) ───────────────────────────

QUIET_MARK = "PaintedSurfaces.quietMark"

#: Views that ARE a mark, so the tone is right on them.
MARKS = ("Image", "Divider", "Circle", "Capsule", "Rectangle",
         "RoundedRectangle", "Label", "ProgressView")

#: How far back the owner walk looks, and how far forward it then reads a
#: `Text`'s own modifier chain for the accessibility escape.
OWNER_WALK_BACK, ACCESSIBILITY_CHAIN = 12, 5


def quiet_marks_on_words(code: str) -> list[tuple[int, str]]:
    """Uses of `quietMark` whose owning view is words, with the line number.

    The owner is found by walking BACK to the nearest view constructor, not by
    looking in a window around the line. A window is answered by whatever else
    happens to be nearby: both checkbox rows in photo assignment put a `Text`
    directly under the `Image` this colour dresses, so a window check would
    report the icon as words (L135).

    Words are allowed to wear it only when nobody reads them: the separator dot
    between two buttons is a mark that happens to be typed as a character, and
    it says so with `accessibilityHidden(true)`.

    A use whose owner the walk cannot reach is REPORTED, not passed over. A
    colour-returning helper has no view above it, so the walk finds nothing, and
    a use the check cannot judge and one it approves are otherwise the same
    thing.
    """
    lines = [raw.strip() for raw in code.split("\n")]
    found: list[tuple[int, str]] = []

    for index, line in enumerate(lines):
        if QUIET_MARK not in line:
            continue

        owner_found = False
        for back in range(index, max(0, index - OWNER_WALK_BACK) - 1, -1):
            candidate = lines[back]
            if any(candidate.startswith(f"{mark}(")
                   or candidate.startswith(f"{mark}.") for mark in MARKS):
                owner_found = True
                break
            if not candidate.startswith("Text("):
                continue
            chain = lines[back:min(len(lines), back + ACCESSIBILITY_CHAIN + 1)]
            if not any("accessibilityHidden(true)" in near for near in chain):
                found.append((index + 1, line))
            owner_found = True
            break

        if not owner_found:
            found.append((index + 1, line))

    return found


#: Uses whose owner the walk cannot reach, and where the tone IS drawn.
#:
#: Written down rather than passed over, and checked in both directions: an
#: entry that stops having anything under it fails too, because a stale
#: exemption silently covers whatever arrives in that file next (L129, L96).
QUIET_MARK_DRAWN_ELSEWHERE: dict[str, str] = {
    "Views/OCRReviewView.swift":
        "confidenceColor fills a 6pt Circle beside a suggestion, which is a "
        "mark and is held to the 3:1 a mark needs. The helper has no view above "
        "it for the walk to find",
}
