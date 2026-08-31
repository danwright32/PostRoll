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
    DECLARES_ITS_OWN_COLOURS,
    DISABLED_LABEL,
    PALETTE,
    QUIET_MARK,
    QUIET_MARK_DRAWN_ELSEWHERE,
    app_source,
    bare_colour_views,
    every_source_file,
    faint_labels_on_live_controls,
    raw_faint_tone_uses,
    quiet_marks_on_words,
    raw_type_colour_uses,
    system_colour_foregrounds,
    unnamed_accent_uses,
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


# ── the accent may not be drawn without saying which role it is in (#580) ────

ACCENT_IT_MUST_CATCH = [
    "            .foregroundStyle(Color.roseGold)",
    "                .tint(Color.roseGold)",
    "                ProgressView().controlSize(.small).tint(Color.roseGold)",
    "            .listRowSeparatorTint(Color.roseGold)",
]

#: The wrapped ternary, invisible until #611: the half naming the colours
#: carries no modifier at all. BOTH widths, because the first version of the fix
#: read two lines, the real one in PhotoAssignmentView spans three, and it went
#: green on exactly the mutation written for it (L144).
ACCENT_WRAPPED = [
    """.foregroundStyle(canGoPrevious
                 ? Color.roseGold : PaintedSurfaces.disabledControlLabel)""",
    """.foregroundStyle(tagsBinding.wrappedValue.isEmpty
                 ? PaintedSurfaces.disabledControlLabel
                 : Color.roseGold)""",
]

#: A bracket inside a sentence is not structure. Left uncounted, the statement
#: never closes, everything after it joins on, and this reports a fill three
#: lines away as part of a foreground.
ACCENT_IT_MUST_ALLOW = """.help("Copies this photo's tags onto every photo :-( in this day")
.foregroundStyle(PaintedSurfaces.pageAccentText)
Capsule().fill(Color.roseGold.opacity(0.15))"""


def test_the_accent_matcher_sees_every_role_the_accent_is_drawn_in():
    for line in ACCENT_IT_MUST_CATCH:
        assert len(unnamed_accent_uses(line)) == 1, (
            f"the check cannot see {line.strip()} as the raw accent, so a "
            "control coloured that way is exempt from the rule and reads "
            "exactly like a screen that has none")


def test_the_accent_matcher_sees_a_ternary_however_it_wraps():
    for spelling in ACCENT_WRAPPED:
        assert len(unnamed_accent_uses(spelling)) == 1, (
            "the check cannot see the accent chosen by a ternary spread over "
            f"{len(spelling.splitlines())} lines, so a label drawn that way is "
            "exempt from the rule while reading as covered by it")


def test_a_bracket_inside_a_sentence_does_not_join_the_statements():
    assert len(unnamed_accent_uses(ACCENT_IT_MUST_ALLOW)) == 0, (
        "the check joins a statement past an unbalanced bracket inside a "
        "string, so it reads a fill three lines away as part of a foreground "
        "and fails on correct code")


def test_the_accent_is_never_drawn_unnamed():
    offenders: list[str] = []
    for relative in every_source_file():
        for statement in unnamed_accent_uses(app_source(relative)):
            offenders.append(f"{relative}\n    {statement}")

    assert not offenders, (
        "these draw the raw accent, which does not say whether it is type or a "
        "symbol. As type it is 4.31:1 on the page, under the level it needs, "
        "and nothing else can tell. Use PaintedSurfaces.pageAccentText or "
        "PaintedSurfaces.iconAccent.\n\n" + "\n\n".join(offenders))


# ── the faint tone is never drawn at a call site (#611) ──────────────────────
#
# `warmFaint` measures 2.43:1 on the page, under the 4.5:1 body text needs and
# under even the 3:1 an interface element needs, and it was the foreground of 14
# text draws across three screens. Nothing reported it: the pair registry never
# held it, so the harness built to catch exactly this had never been given it
# (L143, the same shape as #580).

FAINT_IT_MUST_CATCH = [
    "            .foregroundStyle(Color.warmFaint)",
    "                             ? Color.warmFaint : Color.roseGold)",
    "                .foregroundStyle(Color.warmFaint.opacity(0.45))",
    "            .foregroundStyle(draftIsChange ? PaintedSurfaces.pageAccentText : Color.warmFaint)",
]

FAINT_IT_MUST_ALLOW = [
    "            .foregroundStyle(PaintedSurfaces.tertiaryText)",
    "            .foregroundStyle(PaintedSurfaces.disabledControlLabel)",
    "                .foregroundStyle(Color.warmMid)",
]


def test_the_faint_tone_matcher_sees_every_spelling():
    for line in FAINT_IT_MUST_CATCH:
        assert len(raw_faint_tone_uses(line)) == 1, (
            f"the check cannot see {line.strip()} as a raw use of the faint "
            "tone, so type drawn that way is exempt from the rule and reads "
            "exactly like a screen that has none")


def test_the_faint_tone_matcher_leaves_correct_code_alone():
    for line in FAINT_IT_MUST_ALLOW:
        assert len(raw_faint_tone_uses(line)) == 0, (
            f"the check reports {line.strip()} as a raw use of the faint tone, "
            "which it is not. A rule that fires on correct code is the rule "
            "people learn to work around")


def test_the_faint_tone_is_never_drawn_at_a_call_site():
    offenders: list[str] = []
    for relative in every_source_file():
        for line in raw_faint_tone_uses(app_source(relative)):
            offenders.append(f"{relative}\n    {line}")

    assert not offenders, (
        "these draw Color.warmFaint, which is 2.43:1 on the page and says "
        "nothing about which role it is playing. Use "
        "PaintedSurfaces.tertiaryText for type, PaintedSurfaces.fieldPlaceholder "
        "inside a field, or PaintedSurfaces.disabledControlLabel on a control "
        "that is switched off.\n\n" + "\n\n".join(offenders))


# ── the exempt colour only ever dresses a control that is switched off ───────

A_LIVE_CONTROL = '''Button("Send to Claude") { }
    .buttonStyle(.plain)
    .foregroundStyle(PaintedSurfaces.disabledControlLabel)'''

AN_INACTIVE_CONTROL = '''Button("Send to Claude") { }
    .foregroundStyle(empty ? PaintedSurfaces.disabledControlLabel
                     : PaintedSurfaces.pageAccentText)
    .buttonStyle(.plain)
    .disabled(empty)'''


def test_the_disabled_label_matcher_sees_a_live_control():
    assert len(faint_labels_on_live_controls(A_LIVE_CONTROL)) == 1, (
        "the check cannot see the exempt colour drawn on a control that is not "
        "disabled, which is the only thing it exists to catch")


def test_the_disabled_label_matcher_leaves_a_switched_off_control_alone():
    assert len(faint_labels_on_live_controls(AN_INACTIVE_CONTROL)) == 0, (
        "the check reports a genuinely switched-off control as an offender, "
        "which is the state the exemption is for")


def test_every_faint_label_dresses_a_control_that_is_switched_off():
    offenders: list[str] = []
    found = 0
    for relative in every_source_file():
        code = app_source(relative)
        found += code.count(DISABLED_LABEL)
        for number, line in faint_labels_on_live_controls(code):
            offenders.append(f"{relative}:{number}\n    {line}")

    assert not offenders, (
        "these draw the disabled-label colour on a control with no .disabled( "
        "near it. That tone is 2.43:1 and is exempt only because an inactive "
        "component is exempt; on a live control it is unreadable type that no "
        "check will ever object to.\n\n" + "\n\n".join(offenders))

    # A sweep that finds no subjects is not a sweep that passed (L98).
    assert found > 0, (
        "nothing in the app draws PaintedSurfaces.disabledControlLabel any "
        "more, so the one colour allowed under the contrast floor has no user "
        "and should be deleted rather than left as a way around the rule")


# ── no screen draws type in one of the platform's own colours (#598) ─────────

SYSTEM_IT_MUST_CATCH = [
    ".foregroundStyle(.white)",
    ".foregroundStyle(.white.opacity(0.85))",
    ".foregroundStyle(.secondary)",
    ".foregroundColor(.red)",
    "ProgressView().controlSize(.small).tint(.white)",
    ".foregroundStyle(.orange)",
    ".foregroundStyle( .green )",
    ".foregroundStyle(.white.opacity(0.9), Color.warmDark.opacity(0.5))",
]

SYSTEM_IT_MUST_ALLOW = [
    ".foregroundStyle(PaintedSurfaces.photoScrimText)",
    ".foregroundStyle(Color.warmDark)",
    ".tint(PaintedSurfaces.iconAccent)",
    ".background(Color.black.opacity(0.65))",
    ".shadow(color: .black.opacity(0.5), radius: 24, y: 6)",
    ".symbolRenderingMode(.palette)",
    "ProgressView().progressViewStyle(.circular)",
    ".foregroundStyle(PaintedSurfaces.stateWarningText)",
]


def test_the_system_colour_matcher_sees_every_spelling():
    for line in SYSTEM_IT_MUST_CATCH:
        assert len(system_colour_foregrounds(line)) == 1, (
            f"the check cannot see {line} as a system colour, so type drawn "
            "that way is exempt from the rule and reads exactly like a screen "
            "with none")


def test_the_system_colour_matcher_leaves_correct_code_alone():
    for line in SYSTEM_IT_MUST_ALLOW:
        assert len(system_colour_foregrounds(line)) == 0, (
            f"the check reports {line} as a system colour, which it is not. A "
            "rule that fires on correct code is the rule people learn to work "
            "around")


def test_no_screen_draws_type_in_a_system_colour():
    offenders: list[str] = []
    for relative in every_source_file():
        for line in system_colour_foregrounds(app_source(relative)):
            offenders.append(f"{relative}\n    {line}")

    assert not offenders, (
        "these draw type in one of the platform's own colours, which follow the "
        "Mac rather than this app's palette and cannot be measured against what "
        "is behind them.\n\n" + "\n\n".join(offenders))


# ── type is never drawn in a raw palette colour (#620) ───────────────────────

TYPE_IT_MUST_CATCH = [
    "            .foregroundStyle(Color.warmMid)",
    "            .foregroundStyle(Color.warmMid.opacity(0.55))",
    "                .foregroundColor(Color.warmDark)",
    "            .tint(Color.roseDeep)",
    "            .listRowSeparatorTint(Color.creamEdge)",
    "        .foregroundStyle(Color.cream, Color.warmDark.opacity(0.7))",
    # The two colour-returning helpers, outside every rule in this file until
    # the sweep was widened past the modifiers.
    '        case "high":   return Color.green.opacity(0.8)',
    "        if blocked { return Color.warmMid.opacity(0.35) }",
]

#: The same helper with a BRANCH in it (#630). The one-statement lookahead this
#: replaced saw the `if` and nothing after it, so every colour in a helper of
#: more than one line was exempt.
A_BRANCHING_COLOUR_HELPER = '''private var confidenceColor: Color {
    switch suggestion.confidence {
    case "high":   PaintedSurfaces.stateSuccessText
    case "medium": PaintedSurfaces.stateWarningText
    default:       Color.warmMid.opacity(0.6)
    }
}'''

#: A helper that is ONE expression, so its body carries no `return` at all.
#: This is what the mutation for this guard put back, and the first version of
#: the sweep stayed green on it (L1).
AN_IMPLICIT_COLOUR_HELPER = '''private func colour(isHere: Bool) -> Color {
    isHere ? Color.roseGold : Color.warmMid.opacity(0.35)
}'''

#: The wrapped ternary, the spelling that defeated the first version of the
#: accent rule and which a line-based conversion could not see either (L144).
A_WRAPPED_TYPE_TERNARY = '''.foregroundStyle(stats.freshness(asOf: Date()).isStale
                 ? Color.roseDeep : Color.warmMid)'''

TYPE_IT_MUST_ALLOW = [
    "            .foregroundStyle(PaintedSurfaces.secondaryText)",
    "            .foregroundStyle(PaintedSurfaces.bodyText)",
    "        .foregroundStyle(isOn ? PaintedSurfaces.iconAccent : PaintedSurfaces.quietMark)",
    # A fill is the other rule's business, and Color.clear draws nothing.
    "            .background(Color.creamDeep)",
    "            .foregroundStyle(Color.clear)",
    "    static let warmMid   = Color(red: 122/255, green: 104/255, blue:  96/255)",
]


def test_the_type_colour_matcher_sees_every_spelling():
    for line in TYPE_IT_MUST_CATCH:
        assert len(raw_type_colour_uses(line)) == 1, (
            f"the check cannot see {line.strip()} as type drawn in a colour "
            "written at the point of use, so type spelled that way is exempt "
            "from the rule and reads exactly like a screen that has none")


def test_the_type_colour_matcher_sees_inside_a_branching_helper():
    assert len(raw_type_colour_uses(A_BRANCHING_COLOUR_HELPER)) == 1, (
        "the check cannot see a colour inside a `-> Color` helper that "
        "BRANCHES, so a screen fed its type by one of those is exempt from the "
        "rule while the one line version of the same helper is caught")


def test_the_type_colour_matcher_sees_an_implicitly_returned_colour():
    assert len(raw_type_colour_uses(AN_IMPLICIT_COLOUR_HELPER)) == 1, (
        "the check cannot see a colour returned implicitly from a `-> Color` "
        "helper, so a screen fed its type by one of those is exempt from the "
        "rule. This is the shape the mutation for this guard put back")


def test_the_type_colour_matcher_sees_a_ternary_that_wraps():
    assert len(raw_type_colour_uses(A_WRAPPED_TYPE_TERNARY)) == 1, (
        "the check cannot see a colour chosen by a ternary spread over two "
        "lines, so type drawn that way is exempt while reading as covered")


def test_the_type_colour_matcher_leaves_correct_code_alone():
    for line in TYPE_IT_MUST_ALLOW:
        assert len(raw_type_colour_uses(line)) == 0, (
            f"the check reports {line.strip()} as type in a raw palette "
            "colour, which it is not. A rule that fires on correct code is the "
            "rule people learn to work around")


def test_no_screen_draws_type_in_a_raw_palette_colour():
    offenders: list[str] = []
    for relative in every_source_file():
        if relative in DECLARES_ITS_OWN_COLOURS:
            continue
        for statement in raw_type_colour_uses(app_source(relative)):
            offenders.append(f"{relative}  {statement[:120]}")

    assert not offenders, (
        f"{len(offenders)} places draw type in a colour written at the point of "
        "use. Nothing can hold any of them to a level, because nothing else can "
        "name what is behind them:\n\n" + "\n".join(offenders[:40])
        + "\n\nGive the role a name in PaintedSurfaces and register it in `all` "
        "against the surface it is drawn on, the way the accent and the faint "
        "tone already are.")


def test_every_colour_exemption_still_has_something_to_exempt():
    """Both directions (L129, L96). A stale exemption quietly covers whatever
    drifts into its place."""
    for relative, reason in DECLARES_ITS_OWN_COLOURS.items():
        assert raw_type_colour_uses(app_source(relative)), (
            f"{relative} is exempt from the type colour rule, on the grounds "
            f"that it {reason}, but it no longer names a colour of its own. An "
            "exemption with nothing under it silently covers whatever arrives "
            "in that file next.")


# ── the quiet tone only ever dresses a mark (#629) ───────────────────────────

#: A checkbox row: the tone is on the Image, and a label sits under it in the
#: same stack. A WINDOW around the line would report the icon as words, which is
#: why the owner is found by walking back to the nearest view constructor (L135).
QUIET_ON_AN_ICON = '''Image(systemName: allSelected ? "checkmark.square.fill" : "square")
.font(.system(size: 12))
.foregroundStyle(allSelected ? PaintedSurfaces.iconAccent : PaintedSurfaces.quietMark)
Text(allSelected ? "Deselect all" : "Select all")
.foregroundStyle(PaintedSurfaces.secondaryText)'''

#: The separator dot between two buttons: a mark that happens to be typed as a
#: character, and it says so.
QUIET_ON_A_HIDDEN_DOT = '''Text("·").foregroundStyle(PaintedSurfaces.quietMark)
.accessibilityHidden(true)'''

#: The one thing the rule exists to catch.
QUIET_ON_A_SENTENCE = '''Text(summary)
.font(.system(size: 11))
.foregroundStyle(PaintedSurfaces.quietMark)'''


def test_the_quiet_mark_owner_walk_leaves_a_real_mark_alone():
    assert len(quiet_marks_on_words(QUIET_ON_AN_ICON)) == 0, (
        "the check reports a checkbox mark as words, because a label sits under "
        "it in the same stack. A rule that fires on correct code is the rule "
        "people learn to work around")


def test_the_quiet_mark_owner_walk_leaves_a_decorative_character_alone():
    assert len(quiet_marks_on_words(QUIET_ON_A_HIDDEN_DOT)) == 0, (
        "the check reports a decorative separator nobody reads as words")


def test_the_quiet_mark_owner_walk_finds_a_sentence():
    assert len(quiet_marks_on_words(QUIET_ON_A_SENTENCE)) == 1, (
        "the check cannot see a sentence drawn in the quiet mark tone, which is "
        "the one thing this rule exists to catch")


def test_the_quiet_tone_only_ever_dresses_a_mark():
    offenders: list[str] = []
    found = 0

    for relative in every_source_file():
        code = app_source(relative)
        found += code.count(QUIET_MARK)
        unjudged = quiet_marks_on_words(code)
        if relative not in QUIET_MARK_DRAWN_ELSEWHERE:
            offenders += [f"{relative}:{number}  {line[:110]}"
                          for number, line in unjudged]
        else:
            assert unjudged, (
                f"{relative} is exempt from the quiet mark rule, because "
                f"{QUIET_MARK_DRAWN_ELSEWHERE[relative]}, but the check now "
                "judges every use in it. An exemption with nothing under it "
                "silently covers whatever arrives in that file next.")

    # A sweep that finds nothing to look at proves nothing (L98).
    assert found > 0, (
        "no use of PaintedSurfaces.quietMark was found at all, so this check is "
        "proving nothing about the role it exists for")

    assert not offenders, (
        "these draw WORDS in the quiet mark tone, which is 4.33:1 on the deeper "
        "page against the 4.5:1 a sentence needs:\n\n" + "\n".join(offenders)
        + "\n\nUse PaintedSurfaces.secondaryText for anything that is read.")
