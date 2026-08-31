r"""Every painted surface draws from a NAMED colour, checked without a build (#1045).

This rule and the two matchers under it were `BannerLegibilityTests`, where
every one of them cost an app build to re-prove. They read nothing but source
text, so they never needed one.

Measured on 2026-08-31: `BannerLegibilityTests` carries 33 of the 503 registry
entries, and 15 name a rule that only scans text, at about 29s each. Over
2026-08-30 and 31 the `Guard proofs / changed` job was the sole thing holding
four separate merges, for 15 to 19 minutes each, with every other check green.

## Why the fixtures are the proof, and running it over the tree is not

The tree is clean. So a matcher that sees one spelling and a matcher that sees
three give the same silent pass over the real files, and both read as a rule
that holds (L48, L159). That is not hypothetical here: the Swift versions
shipped narrow twice, once seeing ten of twenty three colour-as-view sites
(#586) and once missing the four modifiers that draw a line or a shadow rather
than an area, with 31 borders written at the point of use while the check
reported a clean sweep (#628). Both were caught by asking the matcher directly,
never by the codebase.

So every `must catch` and `must allow` line below is carried across from the
Swift fixtures verbatim, and they are what says this port kept the rules rather
than a narrower version of them (L263).

## What the rule is

A painted surface has to come from `PaintedSurfaces`, because nothing can check
the words against a colour written at the point of use: nothing else can name
it, and nothing notices it changing.
"""

from __future__ import annotations

from swift_colour_rules import (
    PALETTE,
    app_source,
    bare_colour_views,
    every_source_file,
    unnamed_fills,
)


# ── the fill matcher is asked directly what it can see (#600, L1) ────────────

FILLS_IT_MUST_CATCH = [
    "            .background(Color.creamDeep)",
    "            .fill(Color.roseGold.opacity(0.12))",
    "            .background(Color(red: 0.10, green: 0.09, blue: 0.08))",
    "                    Color(white: 0.92)",
    "            .background(isDragging ? Color.roseGold : Color.black.opacity(0.65))",
    "                Capsule().fill((stale ? Color.warmMid : Color.roseDeep).opacity(0.12))",
    "            .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.78, blue: 0.22)],",
    # The four that draw a line or a shadow rather than an area (#628).
    "                .strokeBorder(Color.creamEdge, lineWidth: 1)",
    "                .stroke(Color.warmMid.opacity(0.2), lineWidth: 1)",
    "        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 2)",
    "            .border(Color.roseGold)",
    "            .strokeBorder(isSelected ? Color.roseGold : Color.creamEdge, lineWidth: 1)",
]

FILLS_IT_MUST_ALLOW = [
    "            .background(PaintedSurfaces.page)",
    "            .fill(pill.wash)",
    "            .background(isSelected ? PaintedSurfaces.selectedPillFill : pill.wash)",
    "            .fill(PaintedSurfaces.captionFindings(stale: stale).panel)",
    "            .background(Color.clear)",
    "            .foregroundStyle(Color.warmDark)",
    "                .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)",
    "                .stroke(PaintedSurfaces.accentBorder.opacity(0.2), lineWidth: 1)",
    "    static let creamDeep = Color(red: 237/255, green: 232/255, blue: 224/255)",
]


def test_the_unnamed_fill_matcher_sees_every_spelling():
    for line in FILLS_IT_MUST_CATCH:
        hits = len(unnamed_fills(line)) + len(bare_colour_views(line))
        assert hits == 1, (
            f"the check cannot see {line.strip()} as a painted surface written "
            "at the point of use, so a fill spelled that way is exempt from the "
            "rule and reads exactly like no fill at all")


def test_the_unnamed_fill_matcher_leaves_correct_code_alone():
    for line in FILLS_IT_MUST_ALLOW:
        hits = len(unnamed_fills(line)) + len(bare_colour_views(line))
        assert hits == 0, (
            f"the check reports {line.strip()} as an unnamed painted surface, "
            "which it is not. A rule that fires on correct code is the rule "
            "people learn to work around")


# ── the colour-as-a-view matcher, the same way (#586) ────────────────────────

VIEWS_IT_MUST_CATCH = [
    "        Color.creamDeep",
    '        Color.creamDeep.overlay { Text("x") }',
    "        Color.cream.ignoresSafeArea()",
    "        Color.creamEdge.frame(height: 0.5)",
    "        Color.black.opacity(0.4)",
]

VIEWS_IT_MUST_ALLOW = [
    "        Color.clear",
    "        Color.clear.frame(width: 8)",
    "        .background(PaintedSurfaces.page)",
    "        .foregroundStyle(Color.warmDark)",
    "        let x = Color.roseGold",
]


def test_the_colour_as_a_view_matcher_sees_every_spelling():
    for line in VIEWS_IT_MUST_CATCH:
        assert len(bare_colour_views(line)) == 1, (
            f"the check cannot see {line.strip()} as a painted area, so a "
            "surface written that way is exempt from it and reads exactly like "
            "no surface at all")


def test_the_colour_as_a_view_matcher_leaves_correct_code_alone():
    for line in VIEWS_IT_MUST_ALLOW:
        assert len(bare_colour_views(line)) == 0, (
            f"the check reports {line.strip()} as an unnamed painted area, "
            "which it is not. A rule that fires on correct code is the rule "
            "people learn to work around")


# ── the sweep itself ─────────────────────────────────────────────────────────

def test_the_sweep_reads_the_whole_tree():
    """A sweep that reads nothing objects to nothing (L98). The five file
    version of this could not have told you it had gone blind either."""
    files = every_source_file()
    assert len(files) > 20, (
        f"the sweep read {len(files)} source files, so it is proving nothing "
        "about the ones it did not open")
    assert not any(name.endswith(PALETTE) for name in files), (
        f"the sweep reads {PALETTE}, which is the one file allowed to write "
        "colours as values, so it would report the palette itself as an "
        "offender")


def test_every_painted_file_draws_from_the_named_colours():
    offenders: list[str] = []
    for relative in every_source_file():
        code = app_source(relative)
        for number, line in unnamed_fills(code):
            offenders.append(
                f"{relative}:{number} paints from a colour written at the "
                f"point of use. Nothing can check the words against it, "
                f"because nothing else can name it.\n    {line}")
        for number, line in bare_colour_views(code):
            offenders.append(
                f"{relative}:{number} paints an area by using a colour as a "
                f"view, which is the same unnamed surface.\n    {line}")

    assert not offenders, (
        "these paint from a colour written at the point of use. Add it to "
        "PaintedSurfaces and draw from there.\n\n" + "\n\n".join(offenders))
