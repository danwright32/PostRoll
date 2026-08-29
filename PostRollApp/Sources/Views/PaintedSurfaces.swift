import SwiftUI
import AppKit

extension Color {
    /// This colour as it will actually be seen once drawn over `background`.
    ///
    /// A translucent fill is not the colour behind the words: `roseGold` at 7%
    /// over cream is a pale wash, and measuring a sentence's contrast against
    /// `roseGold` itself would compute a ratio against a colour nothing ever
    /// draws. Every painted surface in this app is a wash over the page, so the
    /// compositing has to happen before any of them can be judged, and it
    /// happens here once rather than at each place that asks (L16).
    func composited(over background: Color) -> Color {
        let top = NSColor(self).usingColorSpace(.sRGB) ?? .clear
        let bottom = NSColor(background).usingColorSpace(.sRGB) ?? .white
        let alpha = top.alphaComponent
        func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * alpha + b * (1 - alpha) }
        return Color(nsColor: NSColor(
            srgbRed: blend(top.redComponent, bottom.redComponent),
            green: blend(top.greenComponent, bottom.greenComponent),
            blue: blend(top.blueComponent, bottom.blueComponent),
            alpha: 1))
    }
}

/// Every surface this app paints behind its own words, each as a named pair of
/// the type and the colour actually behind it (#574).
///
/// `BannerLegibilityTests` renders each notice and measures ink on the page,
/// which catches a message that never drew. It cannot catch a message drawn in
/// the colour of the thing behind it, because a panel, a border or a button
/// fill is itself a mark on the page and measures as presence. That was proved
/// by mutation on the Insights staleness notice: its sentence, drawn in its own
/// panel colour, still measured 0.0799 against a 0.01 threshold and the guard
/// SURVIVED (#559, L141).
///
/// So every filled surface names its pair here, the views draw from these names
/// rather than from colours typed in at the point of use, and the check reads
/// these same values. A check reading a copy of the two colours could only ever
/// confirm itself (L70).
///
/// The list is what `BannerLegibilityTests.testEverySurfaceIsReadableAgainstWhatIsBehindIt`
/// walks. Adding a painted surface without adding it here is caught by
/// `testNoMeasuredSurfacePaintsAColourItDidNotName`, which refuses an unnamed
/// fill in any of the files these surfaces are drawn in, so the list cannot
/// quietly fall behind the code (L96).
enum PaintedSurfaces {

    /// The page every one of these sits on. Not a decoration: it is the colour
    /// a translucent fill is composited over, so it decides what is behind the
    /// words as much as the fill does.
    static let page = Color.cream

    // MARK: - The Dock (#863)

    /// The band drawn across the foot of the Dock icon while background work is
    /// running, and the elapsed clock on it.
    ///
    /// Named here rather than written into the drawing, because a foreground
    /// only means anything as one half of a pair and only a pair can be held to
    /// a level (L213). Registered in `all` below, so it is measured by the same
    /// machinery as every other surface.
    ///
    /// Opaque black rather than a translucent scrim over the icon. What is
    /// behind this band is the app icon, which this palette does not own and
    /// which changes when the icon does: a translucent band would make both
    /// halves of the pair depend on artwork nothing here can measure, and the
    /// contrast would be decided by whoever last redrew the icon.
    static let dockWorkingBand = Color.black
    static let dockWorkingClock = Color.white

    /// The field the working mark is drawn on when the app has no icon (#885).
    ///
    /// Its own token rather than reusing the band's black, because the two are
    /// beside each other and a band on a field of the same colour is one solid
    /// square: the clock would be the only thing on the tile and the mark would
    /// have no shape at all. Grey keeps the band readable as a band, and is
    /// obviously not the app icon, which is what it is there to say.
    static let dockMissingIcon = Color(red: 0.35, green: 0.35, blue: 0.35)


    /// What a pair has to clear.
    ///
    /// WCAG AA: 4.5:1 for body-sized text, 3:1 for text at 18pt and above and
    /// for interface components (icons, borders) that carry meaning.
    enum Kind {
        case bodyText
        case largeText
        case interfaceElement

        var floor: Double {
            switch self {
            case .bodyText:         return 4.5
            case .largeText:        return 3.0
            case .interfaceElement: return 3.0
            }
        }
    }

    /// One run of type (or one icon) and the colour actually behind it, both
    /// resolved to what will be drawn.
    struct Pair {
        let surface: String
        let element: String
        let foreground: Color
        let background: Color
        let kind: Kind

        init(_ surface: String, _ element: String,
             _ foreground: Color, on background: Color, _ kind: Kind) {
            self.surface = surface
            self.element = element
            // Composited here rather than at each call site, so a translucent
            // foreground (the run note's 75% warmDark) is judged as it lands
            // rather than as it was declared.
            self.foreground = foreground.composited(over: background)
            self.background = background
            self.kind = kind
        }
    }

    // MARK: - The panels the generation screens paint

    /// The note about a failure the cap detector did not recognise.
    static let runNotePanel = Color.roseGold.opacity(0.08)
    static let runNoteText = Color.warmDark.opacity(0.75)

    /// One failed day's card.
    static let failureCardPanel = Color.roseDeep.opacity(0.08)
    static let failureCardLabel = Color.roseDeep

    /// The row of counts on the configure screen.
    static let summaryPanel = Color.creamDeep
    static let summaryBorder = Color.creamEdge
    static let summaryValue = Color.roseGold
    /// Deeper than the `warmMid` this used to be. On `creamDeep` that pair
    /// measured 4.33:1, under the 4.5:1 its 9pt label needs, and nothing said
    /// so: the row is mostly its own panel, so the ink check read it as full
    /// whatever the label did (#574).

    /// The row saying photos have gone missing off disk.
    static let missingMediaPanel = Color.roseGold.opacity(0.08)
    static let missingMediaBorder = Color.roseGold.opacity(0.25)
    static let missingMediaIcon = Color.roseGold
    /// Deeper than `roseGold`, which measured 3.92:1 on this panel against the
    /// 4.5:1 its 11pt label needs. Same reason as the banner's action buttons
    /// below, and the same remedy #569 used on the primary button (#574).
    static let missingMediaAction = Color.roseDeep

    /// Type drawn straight onto the page, with no fill of its own. Named for
    /// the same reason: the check has to be able to say it looked at these too.
    static let outlineButtonLabel = Color.roseDeep

    // MARK: - The accent in its two roles (#580)
    //
    // A colour that clears the level for an icon does not thereby clear it for
    // TEXT: an interface component needs 3:1 and body text needs 4.5:1. Measured,
    // `roseGold` is 4.31:1 on the page and 3.68:1 on `creamDeep`, which is fine
    // for a rule or a symbol and under the line for a label, and it was drawn as
    // both in about ninety places. Nothing could report it: ink measures whether
    // type DREW, and this type draws perfectly well, it is simply too pale.
    //
    // So the two roles are two names. Which one a call site uses says what it is
    // drawing, `testTheAccentIsNeverDrawnUnnamed` refuses the raw colour in any
    // foreground, and both names are held against the two backgrounds this app
    // has, at the level their own role asks for.

    /// The accent as TYPE: a label, a link-styled button, a tracked heading.
    static let pageAccentText = Color.roseDeep

    /// The accent as an ICON, a rule or a symbol, where 3:1 is the level and
    /// `roseGold` clears it on both backgrounds. Unchanged, so nothing that was
    /// drawn as a mark rather than as words moves.
    static let iconAccent = Color.roseGold

    /// The window's wordmark, at 44pt.
    ///
    /// Deliberately not in the pair list. A logotype is exempt from the contrast
    /// requirement, and this one is drawn faint on purpose as the backdrop to an
    /// empty window rather than as something to read. Named anyway so the raw
    /// accent cannot come back through here, and named separately so the
    /// exemption is a decision somebody made rather than a gap (L129).
    static let mastheadWordmark = Color.roseGold

    /// The deeper of the two page colours, which is the harder background for
    /// both roles and so the one the accent has to clear.
    static let deepPage = Color.creamDeep

    // MARK: - The faint tone in its three roles (#611)
    //
    // The same shape as the accent above, one step further down the palette.
    // `warmFaint` is 2.43:1 on the page and 2.07:1 on the deeper one, under the
    // 4.5:1 body text needs and under even the 3:1 an interface element needs,
    // and it was the foreground of 14 text draws across the reading screen, OCR
    // review and photo assignment. Nothing reported it: the token was in no pair
    // here, so the harness built to catch exactly this had never been given it.
    //
    // Splitting it by role is what made the values decidable. Two of the three
    // roles are read, so each takes the value its own background asks for; the
    // third is exempt and keeps the tone.

    /// The sentence under a control saying what it does, and the small labels
    /// beside a value: the step below secondary type.
    ///
    /// `warmMid`, which is where that step runs out. On cream this measures
    /// 5.07:1 and on a resolved flag 4.69:1, and anything lighter is under
    /// 4.5:1, so there is no room for a paler tone that is still read. What
    /// carries the hierarchy instead is size and weight: these are 10pt light
    /// against the 12pt regular they sit under.
    static let tertiaryText = Color.warmMid

    /// The placeholder inside a field, which is filled with `deepPage` rather
    /// than drawn on the page.
    ///
    /// Its own value because its background is the deeper one: `tertiaryText`
    /// is 4.33:1 there, under the line, so the role that lands on the harder
    /// surface decides its own value rather than inheriting one measured
    /// somewhere easier (L143). 4.86:1 on that fill, and still clearly lighter
    /// than the `warmDark` a typed value is drawn in.
    static let fieldPlaceholder = Color.warmDark.opacity(0.75)

    /// The label of a control that is switched off.
    ///
    /// The tone itself, unchanged, and the one place in the app allowed under
    /// the contrast floor: WCAG 1.4.3 exempts the text of an inactive component,
    /// and a greyed-out control that reads at full strength is not reporting
    /// that it cannot be pressed.
    ///
    /// Deliberately not in the pair list, because there is no level it has to
    /// clear. What reviews it instead is
    /// `BannerLegibilityTests.testEveryFaintLabelDressesAControlThatIsSwitchedOff`,
    /// which holds every use of it to a control carrying `.disabled(`, so the
    /// exemption cannot spread to ordinary type (L129).
    static let disabledControlLabel = Color.warmFaint

    // MARK: - The app's ink, in the roles it is drawn in (#619, #620)
    //
    // The third time this shape has come up, and the first time it is the whole
    // class rather than one token. #580 took the accent apart because it was
    // right as a symbol and too pale as words; #611 did the same for the faint
    // tone. Both were found by somebody measuring, both had been under the floor
    // for months, and nothing could have reported either, because a colour
    // written straight into a foreground has no name and an unnamed colour has
    // no pair (L30).
    //
    // So the palette's ink now has roles too, and `testNoScreenDrawsTypeInARawPaletteColour`
    // refuses a colour written at the point of use in any foreground or tint.
    // 362 statements were drawing type that way when that check first ran.

    /// The app's primary ink: a heading, a sentence, a value, a field's
    /// contents. Measured 11.29:1 on the page and 9.65:1 on the deeper one, so
    /// this moves nothing. Named because it could not be measured at all
    /// before, which is the gap rather than the colour.
    static let bodyText = Color.warmDark

    // Ten names came out of here in #637. `bodyText` was five (the failure
    // card's message, the missing media row's message, the event row's name,
    // a tag chip's text and itself), `secondaryText` was four, `tertiaryText`
    // was two and `quietMark` was three. Each was defensible alone, and each
    // arrived separately as its own surface was measured, which is how a
    // palette ends up with four names for one decision.
    //
    // A Pair carries its own background, so ONE name is measured against every
    // surface it is drawn on. The name is for the decision, not for the place.
    //
    // What is deliberately NOT merged, so the next reader does not have to work
    // it out again: `runNoteText` and `fieldPlaceholder` share a value and are
    // different decisions, a sentence on a panel against a placeholder inside a
    // field, and either could move without the other. `clearButtonGlyph` and
    // `removeButtonDisc` likewise, a mark against the disc behind a different
    // mark. And `insightConfidenceLow` keeps its own name because it is one of
    // three ratings in a lookup table, and naming that table's entries
    // separately is what stopped the other two being invisible (L113).
    //
    // No check enforces this. A rule reading "two names may not share a value"
    // fires on seventeen groups in this file, nearly all of them correct: the
    // accent is legitimately a fill, an icon, a rule and a wordmark. A rule
    // that fires on correct code is the rule people learn to work around.

    /// The line under it: an organisation and a date, a count, a hint, the
    /// label beside a value.
    ///
    /// Deeper than the `warmMid` this was. That measured 5.07:1 on the page and
    /// **4.33:1 on the deeper one**, under the 4.5:1 body text needs, and the
    /// deeper page is what the sidebar, the panels and every field are filled
    /// with, so most of this app's secondary type was sitting on the surface
    /// where the tone ran out (#619). 6.16:1 and 5.56:1 now.
    ///
    /// One value for both backgrounds rather than one each, and the deeper one
    /// decided it. A role that takes its value from the easier surface is a role
    /// that is under the line everywhere else it is used, which is exactly how
    /// this arrived (L143).
    ///
    /// The same remedy, at the same strength, that #574 used on the summary
    /// row's label, #590 on the event row's detail lines and #582 on the missing
    /// photo badge. Those keep their own names because each is registered
    /// against its own fill rather than against the page.
    static let secondaryText = Color.warmDark.opacity(0.8)

    /// A quieter still line that is genuinely decorative rather than read: the
    /// separator dot between two facts, a chevron, a drag handle.
    ///
    /// Its own role because the alternative is a foreground with an opacity on
    /// it at the point of use, which is what 26 of these were: `warmMid` at
    /// strengths from 0.85 down to 0.30, measuring 3.74:1 down to **1.49:1**,
    /// none of them named and so none of them measured. As a mark 3:1 is the
    /// level, and this clears it at 4.33:1 on the deeper page.
    ///
    /// It is deliberately NOT for words. Anything that has to be read is
    /// `secondaryText`, and the check that separates them is the pair list: this
    /// is registered as an interface element only.
    static let quietMark = Color.warmMid

    // The two tone symbols, each as the mark and the disc behind it.
    //
    // The shape `lightboxCloseIcon` and its disc already have, and for the same
    // reason: a palette-rendered SF Symbol draws its glyph ON its own disc, so
    // the disc is what is behind the mark and the page is not. Written at the
    // point of use as a pair of raw colours, neither half could be named, and
    // the pale one below turned out to be the closest to the line.

    /// The clear button inside a field or a panel.
    ///
    /// It was `warmMid` at 60% on this disc, which is 2.19:1: a mark needs 3:1
    /// and this is the palest disc in the app, so the glyph on it had the least
    /// room of any in the product and was given the least. 3.65:1 now. The
    /// first value tried here was still under at 2.64:1, which is the pair walk
    /// doing its job rather than anybody's judgement.
    static let clearButtonGlyph = Color.warmDark.opacity(0.7)
    static let clearButtonDisc = Color.creamEdge

    /// The remove button on a thumbnail, which sits over a photograph.
    static let removeButtonGlyph = Color.cream
    static let removeButtonDisc = Color.warmDark.opacity(0.7)

    /// The tick on a selected photo.
    static let selectionTickGlyph = Color.cream

    /// The circle beside a step that has not started.
    ///
    /// Deliberately not a pair, and the exemption is the reasoning the
    /// hairlines are exempt under (L129): the step's NAME is beside it and its
    /// position in the list is what says where the run has got to, so no
    /// meaning rests on this mark alone. It measures 1.56:1, which would be
    /// indefensible if it were carrying anything.
    ///
    /// What reviews it instead is the name, which is `secondaryText` now: a
    /// pending step used to be drawn at 2.02:1 and was the only thing on that
    /// row anybody had to read.
    static let pendingStepMark = Color.creamEdge

    /// The ink on the Instagram card, which is black because Instagram is
    /// black. Named for the reason the rest of that mock was in #600: exempt by
    /// a decision somebody made rather than by nobody having looked.
    static let instagramInk = Color.black

    // MARK: - The rest of the app's painted surfaces (#582)
    //
    // #574 named the surfaces the notices paint. Seventeen other view files
    // still painted a fill from a colour written at the point of use, where
    // nothing can name it and so nothing can read the words against it. These
    // are those, by the role each one plays rather than by the colour it
    // happens to be, so a pair says which surface it is about.

    /// A hairline rule between two areas. A border, not a surface: nothing is
    /// drawn on it, so it is judged by the same reasoning as the banner
    /// hairlines below.
    static let edgeRule = Color.creamEdge

    // MARK: - The lines, at last (#628)
    //
    // #574 named the fills, #620 named the type, and the rule about fills read
    // the two spellings that fill an AREA. A line drawn with `.stroke`,
    // `.strokeBorder`, `.border` or `.shadow` was outside all of it, and 31
    // borders were colours written at the point of use.
    //
    // Still deliberately NOT pairs. The reasoning over the pair list stands:
    // every surface here is identified by its fill, its icon and its words, so
    // no meaning rests on a border alone and the level for interface components
    // does not apply to it. Exempt from being MEASURED is not exempt from being
    // NAMED, though: an unnamed border is one nothing else can describe, notice
    // changing, or hold to the decision above.

    /// The accent as an outline: a focused field, a selected card, a panel that
    /// wants the eye. At whatever strength its call site asks for, the way
    /// `dividerRule` is.
    static let accentBorder = Color.roseGold

    /// The outline button's own edge, deeper than the accent because its label
    /// is `outlineButtonLabel` and the two read as one control.
    static let outlineButtonBorder = Color.roseDeep.opacity(0.55)

    /// The rule around a preview thumbnail that has been given a treatment.
    static let treatmentTileBorder = Color.warmMid.opacity(0.2)

    /// What lifts the Instagram card off the page. Part of the mock, so exempt
    /// for the reason the rest of that card is (#600).
    static let instagramCardShadow = Color.black.opacity(0.18)

    /// The accent hairline `RoseGoldDivider` draws, at whatever strength its
    /// call site asks for.
    ///
    /// This was the app's last raw fill, and it was exempt for no better
    /// reason than living in `DesignTokens.swift` rather than in a view file
    /// (#586). A rule with nothing drawn on it is genuinely exempt from the
    /// level, but that has to be a decision written down, not a side effect of
    /// which folder the check happened to walk (L129).
    static let dividerRule = Color.roseGold

    // The event list.

    /// The row at rest. `EventRowBackground` paints this opaque so the system
    /// accent selection cannot bleed through.
    static let eventRow = Color.creamDeep
    static let eventRowSelectedFill = Color.roseGold.opacity(0.12)
    static let eventRowSelectedSpine = Color.roseGold
    static let eventRowHoverFill = Color.roseGold.opacity(0.05)

    /// The three row backgrounds a stage pill can sit on.
    static var eventRowAtRest: Color { eventRow }
    static var eventRowHovered: Color { eventRowHoverFill.composited(over: eventRow) }
    static var eventRowSelected: Color { eventRowSelectedFill.composited(over: eventRow) }

    /// The pill on a selected row, which drops its stage colour and wears the
    /// system label colour instead, so the whole row reads as one selected
    /// unit (#587).
    ///
    /// Resolved rather than assumed. `Color.primary` is whatever the current
    /// appearance says it is, and a check reading it under the appearance a
    /// test process happens to have would be measuring a colour the app never
    /// draws. The app pins itself to light (`PostRollApp.swift`) and forces the
    /// aqua appearance on its window (`MainWindowView.swift`), so that is the
    /// one this is resolved under.
    ///
    /// What this does NOT cover, said out loud rather than left as a gap
    /// (L129): AppKit can draw a focused selected row EMPHASIZED, which
    /// substitutes white for the label colour. This app gives every row an
    /// opaque background of its own precisely to keep the system selection out
    /// (`EventRowBackground`), so the emphasized path should not arise, and
    /// "should not" is the honest strength of that claim. It cannot be settled
    /// from here: it needs the running app.
    static var selectedPillLabel: Color { inPinnedAppearance(.primary) }
    static var selectedPillFill: Color { inPinnedAppearance(.primary).opacity(0.15) }

    /// The event's name, the first line of the row.
    ///
    /// Measured at 11.61:1 on a selected row, so this moves nothing. Named
    /// because it was the only foreground on the row nothing could read: the
    /// two lines under it were 3.68:1 in the same state and no pair covered
    /// either of them, which is the gap rather than the colour (#590).
    static var eventRowNameSelected: Color { inPinnedAppearance(.primary) }

    /// The second and third lines of a row: the organisation and date, and the
    /// shoot type beside the pill (#590).
    ///
    /// That line is what confirms the right show was clicked, and it was the
    /// palest thing on the row in exactly the state where the row is being
    /// read: 4.33:1 at rest, 4.10:1 hovered and 3.68:1 selected, against the
    /// 4.5:1 a 10pt line needs. Nothing reported it because the selected value
    /// was `Color.secondary`, a system colour sitting outside the palette, so
    /// no pair covered it, and the name above it measures 11.61:1 whatever
    /// these do.
    ///
    /// Deeper than the `warmMid` it was, which is the same remedy #574 used on
    /// the summary row's label against the same background.

    /// The same lines on a selected row, which keeps the adaptation
    /// `EventListView` records as deliberate rather than dropping it: the row
    /// still warms towards the system label colour when it is picked, at three
    /// quarters strength so the name above stays the stronger of the two.
    static var eventRowDetailSelected: Color { readableSecondaryLabel }

    // MARK: - Secondary type, and the one window that is not ours (#596)

    /// The platform's secondary label, dark enough to read.
    ///
    /// SwiftUI's `.secondary` is the label colour at half strength, and half of
    /// it is not enough on either background this app puts it on: 3.68:1 on a
    /// selected event row and 3.95:1 on the white a system form is drawn on,
    /// against the 4.5:1 body text needs. Three quarters is 5.83:1 and 6.58:1.
    ///
    /// One definition rather than one per screen. Both places want the same
    /// thing, type that is quieter than the line above it and still readable,
    /// and two copies of that decision would drift the first time one of them
    /// was tuned.
    ///
    /// Resolved under the appearance the app pins itself to, for the reason
    /// `selectedPillLabel` is: read under whatever a test process happens to
    /// have, this would be measuring a colour the app never draws.
    static var readableSecondaryLabel: Color { inPinnedAppearance(.primary).opacity(0.75) }

    /// What the Settings window is filled with.
    ///
    /// The one window this app does not paint. It is a system `Form` on system
    /// chrome, and holding Apple's own controls to a cream palette would be
    /// holding them to rules they never agreed to, which is the reasoning the
    /// Instagram card is exempt under. The WORDS on it are still this app's, so
    /// the type is named and measured and the surface is taken from AppKit.
    ///
    /// `MainWindowView` sets `NSApplication.shared.appearance` to aqua, which
    /// covers every panel including this one, so this is resolved there too.
    static var systemFormBackground: Color {
        inPinnedAppearance(Color(nsColor: .windowBackgroundColor))
    }

    /// The appearance this app pins itself to, named once (#918).
    ///
    /// It was spelled in three places: here, on the application and window in
    /// `MainWindowView`, and nowhere at all in the render harness, which is how
    /// the harness came to draw platform chrome in whatever appearance the
    /// machine happened to be in while every colour above resolved to light
    /// (L41). Anything that has to agree about the appearance now reads this.
    /// Computed rather than stored: `NSAppearance` is not `Sendable`, and a
    /// stored one would be shared mutable state across every actor that reads
    /// it. Each caller gets its own, which costs nothing and is what the three
    /// call sites were doing separately anyway.
    static var pinnedAppearance: NSAppearance? { NSAppearance(named: .aqua) }

    /// A dynamic system colour as it lands under the appearance the app pins
    /// itself to, rather than under whatever is current where this is read.
    private static func inPinnedAppearance(_ colour: Color) -> Color {
        var resolved = colour
        pinnedAppearance?.performAsCurrentDrawingAppearance {
            if let sRGB = NSColor(colour).usingColorSpace(.sRGB) {
                resolved = Color(nsColor: sRGB)
            }
        }
        return resolved
    }

    /// The count of hidden exported events, on the archive toggle.
    static let exportedCountBadge = Color.warmMid
    static let exportedCountText = Color.cream

    // Photo assignment.

    /// A tag already on a photo, and the accounts the event suggests.
    static let tagChipFill = Color.roseGold.opacity(0.14)
    static let suggestionChipFill = Color.roseGold.opacity(0.10)

    /// How many photos are on a day, drawn over the photo itself.
    ///
    /// Opaque, and deeper than the accent. It used to be `roseGold` at 65% over
    /// whatever the photograph happened to be: over a bright frame that put
    /// its label at 2.35:1, and no fill that lets the picture through can
    /// promise anything, because the picture is the half nobody controls
    /// (#582).
    static let photoCountBadge = Color.roseButton
    static let photoCountText = Color.cream

    /// The section washes that separate the assignment panes.
    static let sectionWash = Color.roseGold.opacity(0.02)

    /// The button that moves to the next step, hand-rolled rather than styled.
    /// Drawn from the button style's own fill, which #569 deepened for exactly
    /// this reason: `roseGold` under a cream label is 4.31:1.
    static var nextStepFill: Color { BrandButtonStyle.fill }
    static var nextStepLabel: Color { BrandButtonStyle.label }

    // Controls drawn on top of a photograph.
    //
    // The background here is a photograph, which is the one surface the app
    // does not choose. So these are measured against the worst case a
    // photograph can be, a white frame, and the scrim has to be dark enough on
    // its own to carry the icon. It was 0.4, which put a 90% white glyph at
    // 2.61:1 over a bright picture, under the 3:1 an icon needs. One strength
    // now, at the 0.55 the carousel counter already used, rather than three.

    /// What a photograph is measured as when it could be anything.
    static let brightestPhoto = Color.white
    static let photoScrim = Color.black.opacity(0.55)
    static let photoScrimIcon = Color.white.opacity(0.9)
    static let photoScrimText = Color.white

    /// What the phone and Instagram cover, drawn over a full-frame preview
    /// (#758). A wash, not a mask: what is underneath has to stay readable or
    /// the preview stops being a preview and the overlay gets switched off.
    static let phoneChrome = Color.black.opacity(0.34)
    /// The action rail, which covers less than the bands do: it is a column of
    /// controls with gaps, not a solid strip.
    static let phoneChromeFaint = Color.black.opacity(0.18)
    /// Where a covered band ends, so the line a template has to stay clear of
    /// is visible rather than inferred from a gradient edge.
    static let phoneChromeEdge = Color.white.opacity(0.5)

    /// The panel that explains why cell editing is off, over the collage.
    static let photoHintPanel = Color.black.opacity(0.65)

    // OCR review.

    /// A suggested correction, and the control that dismisses it. The icon was
    /// `warmMid` at half strength, which is 1.98:1 on this row (#582).
    static let suggestionRowFill = Color.warmDark.opacity(0.03)
    /// The panel offering to reflow a page.
    static let reflowPanelFill = Color.roseGold.opacity(0.05)
    /// A flag whose correction has been accepted, faded back.
    static let resolvedFlagFill = Color.cream.opacity(0.5)

    /// The track the OCR shimmer travels along.
    ///
    /// Deliberately not a pair. It is the rail behind the moving highlight, and
    /// the highlight is what says the run is alive; nothing is drawn on the
    /// rail and no meaning rests on it alone, which is the same reasoning the
    /// hairlines below are exempt under. What reviews it instead is the ink
    /// measurement, which a track that stopped drawing would move (L129).
    static let shimmerTrack = Color.roseGold.opacity(0.15)

    /// Caption review's brand-note field and its tagged-accounts strip.
    static let noteFieldFill = Color.roseGold.opacity(0.06)
    static let taggedAccountsFill = Color.roseGold.opacity(0.10)
    /// The tile that adds a black-and-white treatment, and the placeholder
    /// where a collage has not rendered yet.
    static let addTreatmentFill = Color.warmFaint.opacity(0.3)
    static let imagePlaceholderFill = Color.warmMid.opacity(0.1)
    /// A cell the drag is over.
    static let dropTargetFill = Color.roseGold.opacity(0.18)
    static let dropTargetMarker = Color.roseGold

    // What stands in for a photograph that is not on screen yet (#586).
    //
    // Nine places painted this, all of them by using a colour as a view, which
    // is the one spelling neither fill check could express. Two of them carry
    // marks with meaning on top: the spinner that says the file is still
    // loading, and the badge that says it is gone.

    static let photoPlaceholder = Color.creamDeep
    static let photoPlaceholderSpinner = Color.roseGold
    /// The mark on the badge for a photo that has moved or been deleted. It was
    /// the accent at 85%, which is 2.93:1 on the placeholder, just under the
    /// 3:1 a symbol needs, and its label was `warmMid` at 4.33:1 against the
    /// 4.5:1 its own asks for. Same remedy #574 used on the summary row.
    static let missingPhotoIcon = Color.roseGold

    /// The backdrop behind a photo opened at full size.
    ///
    /// It DOES carry words after all: when the file has gone, the lightbox says
    /// so on this backdrop rather than showing a photo, and those three lines
    /// were white at three different strengths written at the point of use, in
    /// two files, with nothing measuring any of them (#598).
    static let lightboxBackdrop = Color.black.opacity(0.78)
    static let lightboxLabel = Color.white.opacity(0.85)
    /// The file name under it, quieter on purpose.
    static let lightboxDetail = Color.white.opacity(0.6)
    /// The close button, a two tone symbol: the mark and the disc behind it.
    static let lightboxCloseIcon = Color.white.opacity(0.9)
    static let lightboxCloseIconDisc = Color.warmDark.opacity(0.5)

    // MARK: - The dark surfaces the previews sit on (#598)

    /// The panel a story or reel preview is drawn on.
    ///
    /// Near black on purpose: a phone story is a bright thing and the panel is
    /// what stops the page glowing around it. It was written as literal colour
    /// components at two call sites, which is a third way past the rule that a
    /// painted fill must be named: `testEveryPaintedFileDrawsFromTheNamedColours`
    /// recognises `Color.<token>`, and a colour built from numbers is not that,
    /// so it read as no fill at all.
    static let storyPanel = Color(red: 0.10, green: 0.09, blue: 0.08)
    static let storyPanelLabel = Color.white.opacity(0.85)
    static let storyPanelDetail = Color.white.opacity(0.8)

    /// The handle on a collage divider, and the fill behind it while it is
    /// being dragged. Written as a ternary at the point of use, which is a
    /// fourth way past the same rule, since the check looks for `Color.` right
    /// after the bracket and a condition sits in between.
    static let dragHandleFill = Color.black.opacity(0.65)
    static let dragHandleActiveFill = Color.roseGold
    static let dragHandleIcon = Color.white

    // MARK: - What a state label is drawn in (#598)
    //
    // Three labels reported success, a refusal and a warning in `.green`,
    // `.red` and `.orange`, the platform's own state colours. As TYPE those
    // measure 2.22:1, 3.57:1 and 2.31:1 on the white a system form is drawn on,
    // against the 4.5:1 body text needs, and the warning is the sentence that
    // says a pasted API key is the wrong shape.
    //
    // Taken from the palette's own ink family rather than deepened by hand.
    // Those are the colours already calibrated to be read at small sizes, they
    // keep the rule that every colour leans warm, and they measure 6.4:1 to
    // 6.9:1 on both backgrounds this app puts a state label on.

    static let stateWarningText = Color.stagePhotosAssignedInk
    static let stateSuccessText = Color.stageExportedInk
    static let stateErrorText = Color.roseDeep

    /// The Instagram post preview.
    ///
    /// Deliberately not pairs. This card is a drawing of somebody else's
    /// product, so it is white because Instagram is white, and holding it to
    /// this app's palette would be holding a photograph of a thing to the
    /// thing's own rules. Named for the same reason `mastheadWordmark` is: so
    /// the exemption is a decision somebody made rather than a gap the check
    /// cannot see (L129).
    ///
    /// The whole mock is here now, not just the three that happened to be
    /// written as `Color.<token>` (#600). The other thirteen were built from
    /// literal components, which is a spelling the unnamed fill rule cannot
    /// see, so they were exempt by accident rather than by the decision above.
    /// That is the difference this block is about: `instagramCard` was chosen
    /// to be exempt and `Color(white: 0.45)` simply was not looked at.
    static let instagramCard = Color.white
    static let instagramAvatarRing = Color.white
    static let instagramOverlayButton = Color.white.opacity(0.92)
    /// The story ring around the avatar.
    static let instagramRingWarm = Color(red: 1.0, green: 0.78, blue: 0.22)
    static let instagramRingPink = Color(red: 0.98, green: 0.28, blue: 0.50)
    static let instagramRingViolet = Color(red: 0.62, green: 0.18, blue: 0.82)
    /// Its greys, in the shades Instagram uses them: the audio line under the
    /// handle, the glyphs, the placeholder square and the photo mark on it, the
    /// caption placeholder, the comments line, the date, and the card's edge.
    static let instagramSecondaryText = Color(white: 0.45)
    static let instagramGlyph = Color(white: 0.2)
    static let instagramPlaceholder = Color(white: 0.92)
    static let instagramPlaceholderMark = Color(white: 0.7)
    static let instagramCaptionPlaceholder = Color(white: 0.65)
    static let instagramCommentsLine = Color(white: 0.55)
    static let instagramDate = Color(white: 0.6)
    static let instagramCardEdge = Color(white: 0.82)
    /// Instagram's link blue, which is the one colour on this card that is not
    /// this app's to choose at all.
    static let instagramLink = Color(red: 0.07, green: 0.31, blue: 0.78)

    /// A rating this app is confident about, drawn as a dot and as a tick.
    ///
    /// A mark rather than words, so 3:1 is its level and it measures 3.57:1 on
    /// the page. Named because it was written from literal components at two
    /// call sites, where nothing could say which of those two levels applied
    /// (#600). It satisfies the palette's warm rule exactly, R equal to B.
    static let insightConfidenceHigh = Color(red: 110/255, green: 140/255, blue: 110/255)

    /// The other two ratings, which the table had all along and nobody could
    /// see (#620).
    ///
    /// #600 named the high one because it was written from literal components,
    /// and left these two because they were written as palette tokens, so a
    /// three entry lookup ended up with one entry measured and two exempt for
    /// no reason anybody chose (L113). Both are marks, at the 3:1 a mark needs:
    /// 4.33:1 and 4.31:1 on the page.
    static let insightConfidenceMedium = Color.roseGold
    static let insightConfidenceLow = Color.warmMid

    /// The caption findings badge and the panel under it, in both states (#600).
    ///
    /// One place decides the wash and the ink, the shape #582 gave the stage
    /// pill and for the same reason: this drew its count in the colour of its
    /// own wash, chosen by a ternary at the point of use, which is a spelling
    /// the unnamed fill rule cannot see either. Measured, the stale badge was
    /// `warmMid` on a 12% `warmMid` wash at 4.35:1, under the 4.5:1 its 10pt
    /// count needs, so the stale ink is carried down the way the pills' were.
    /// The fresh one measured 5.56:1 and is unchanged.
    static func captionFindings(stale: Bool)
    -> (badge: Color, panel: Color, border: Color, ink: Color) {
        let hue = stale ? Color.warmMid : Color.roseDeep
        return (badge: hue.opacity(0.12),
                panel: hue.opacity(0.07),
                border: hue.opacity(0.45),
                ink: stale ? Color.warmDark.opacity(0.8) : Color.roseDeep)
    }

    /// The wash the pill draws behind its label, and the ink on it, for one
    /// state (#582).
    ///
    /// One place decides both, so a state cannot get a wash without getting
    /// the ink that was measured against it. The pill used to return a single
    /// colour used as fill AND as type, which is the shape #580 took apart for
    /// the accent: a colour that clears the level for a wash does not thereby
    /// clear it for the words on that wash.
    ///
    /// The wash comes back at the strength it is drawn at, not as the colour it
    /// is made from, so the view has no opacity of its own to apply and the
    /// check cannot be measuring a different number from the one that ships.
    static func stagePill(_ state: StagePillState) -> (wash: Color, ink: Color) {
        let (colour, ink) = stagePillColours(state)
        return (colour.opacity(0.14), ink)
    }

    private static func stagePillColours(_ state: StagePillState) -> (Color, Color) {
        switch state {
        case .reading, .generating, .exporting, .finishingMedia:
            return (Color.roseGold, Color.stageBusyInk)
        case .readingFailed, .generationFailed:
            return (Color.roseDeep, Color.stageFailedInk)
        case .awaitingGeneration:
            return (Color.stagePhotosAssigned, Color.stagePhotosAssignedInk)
        case .awaitingExport:
            return (Color.stageCaptionsReviewed, Color.stageCaptionsReviewedInk)
        case .stage(let stage):
            switch stage {
            case .created:          return (.stageCreated, .stageCreatedInk)
            case .programUploaded:  return (.stageProgramUploaded, .stageProgramUploadedInk)
            case .ocrDone:          return (.stageOCRDone, .stageOCRDoneInk)
            case .photosAssigned:   return (.stagePhotosAssigned, .stagePhotosAssignedInk)
            case .assetsGenerated:  return (.stageAssetsGenerated, .stageAssetsGeneratedInk)
            case .captionsReviewed: return (.stageCaptionsReviewed, .stageCaptionsReviewedInk)
            case .exported:         return (.stageExported, .stageExportedInk)
            }
        }
    }

    /// Every colour named here, keyed by the name a call site writes.
    ///
    /// Naming these moved them out of reach of the checks that read source and
    /// recognise `Color.<token>`: `VisibleControlGuardTests` decides whether a
    /// plain button is drawn in a body-text colour that way, and a name it
    /// cannot resolve reads as "no colour set", which can never offend. A guard
    /// that has gone blind is indistinguishable from one that is passing, so
    /// this is how a name is turned back into the colour it draws.
    ///
    /// `testEveryNamedColourIsResolvable` holds this to the declarations in this
    /// file, so a name added without an entry fails there rather than silently
    /// exempting whatever it is put on (L96).
    static let byName: [String: Color] = [
        "dockWorkingBand": dockWorkingBand,
        "dockWorkingClock": dockWorkingClock,
        "dockMissingIcon": dockMissingIcon,
        "page": page,
        "deepPage": deepPage,
        "runNotePanel": runNotePanel,
        "runNoteText": runNoteText,
        "failureCardPanel": failureCardPanel,
        "failureCardLabel": failureCardLabel,
        "summaryPanel": summaryPanel,
        "summaryBorder": summaryBorder,
        "summaryValue": summaryValue,
        "missingMediaPanel": missingMediaPanel,
        "missingMediaBorder": missingMediaBorder,
        "missingMediaIcon": missingMediaIcon,
        "missingMediaAction": missingMediaAction,
        "outlineButtonLabel": outlineButtonLabel,
        "outlineButtonHitArea": outlineButtonHitArea,
        "pageAccentText": pageAccentText,
        "iconAccent": iconAccent,
        "bodyText": bodyText,
        "secondaryText": secondaryText,
        "quietMark": quietMark,
        "clearButtonGlyph": clearButtonGlyph,
        "clearButtonDisc": clearButtonDisc,
        "removeButtonGlyph": removeButtonGlyph,
        "removeButtonDisc": removeButtonDisc,
        "selectionTickGlyph": selectionTickGlyph,
        "pendingStepMark": pendingStepMark,
        "instagramInk": instagramInk,
        "tertiaryText": tertiaryText,
        "fieldPlaceholder": fieldPlaceholder,
        "disabledControlLabel": disabledControlLabel,
        "mastheadWordmark": mastheadWordmark,
        "accentBorder": accentBorder,
        "outlineButtonBorder": outlineButtonBorder,
        "treatmentTileBorder": treatmentTileBorder,
        "instagramCardShadow": instagramCardShadow,
        "edgeRule": edgeRule,
        "eventRow": eventRow,
        "eventRowSelectedFill": eventRowSelectedFill,
        "eventRowSelectedSpine": eventRowSelectedSpine,
        "eventRowHoverFill": eventRowHoverFill,
        "eventRowAtRest": eventRowAtRest,
        "eventRowHovered": eventRowHovered,
        "eventRowSelected": eventRowSelected,
        "selectedPillLabel": selectedPillLabel,
        "selectedPillFill": selectedPillFill,
        "eventRowNameSelected": eventRowNameSelected,
        "eventRowDetailSelected": eventRowDetailSelected,
        "readableSecondaryLabel": readableSecondaryLabel,
        "systemFormBackground": systemFormBackground,
        "exportedCountBadge": exportedCountBadge,
        "exportedCountText": exportedCountText,
        "tagChipFill": tagChipFill,
        "suggestionChipFill": suggestionChipFill,
        "photoCountBadge": photoCountBadge,
        "photoCountText": photoCountText,
        "sectionWash": sectionWash,
        "nextStepFill": nextStepFill,
        "nextStepLabel": nextStepLabel,
        "brightestPhoto": brightestPhoto,
        "phoneChrome": phoneChrome,
        "phoneChromeEdge": phoneChromeEdge,
        "phoneChromeFaint": phoneChromeFaint,
        "photoScrim": photoScrim,
        "photoScrimIcon": photoScrimIcon,
        "photoScrimText": photoScrimText,
        "photoHintPanel": photoHintPanel,
        "suggestionRowFill": suggestionRowFill,
        "reflowPanelFill": reflowPanelFill,
        "resolvedFlagFill": resolvedFlagFill,
        "shimmerTrack": shimmerTrack,
        "noteFieldFill": noteFieldFill,
        "taggedAccountsFill": taggedAccountsFill,
        "addTreatmentFill": addTreatmentFill,
        "imagePlaceholderFill": imagePlaceholderFill,
        "dropTargetFill": dropTargetFill,
        "dropTargetMarker": dropTargetMarker,
        "instagramCard": instagramCard,
        "instagramAvatarRing": instagramAvatarRing,
        "instagramOverlayButton": instagramOverlayButton,
        "instagramRingWarm": instagramRingWarm,
        "instagramRingPink": instagramRingPink,
        "instagramRingViolet": instagramRingViolet,
        "instagramSecondaryText": instagramSecondaryText,
        "instagramGlyph": instagramGlyph,
        "instagramPlaceholder": instagramPlaceholder,
        "instagramPlaceholderMark": instagramPlaceholderMark,
        "instagramCaptionPlaceholder": instagramCaptionPlaceholder,
        "instagramCommentsLine": instagramCommentsLine,
        "instagramDate": instagramDate,
        "instagramCardEdge": instagramCardEdge,
        "instagramLink": instagramLink,
        "insightConfidenceHigh": insightConfidenceHigh,
        "insightConfidenceMedium": insightConfidenceMedium,
        "insightConfidenceLow": insightConfidenceLow,
        "dividerRule": dividerRule,
        "photoPlaceholder": photoPlaceholder,
        "photoPlaceholderSpinner": photoPlaceholderSpinner,
        "missingPhotoIcon": missingPhotoIcon,
        "lightboxBackdrop": lightboxBackdrop,
        "lightboxLabel": lightboxLabel,
        "lightboxDetail": lightboxDetail,
        "lightboxCloseIcon": lightboxCloseIcon,
        "lightboxCloseIconDisc": lightboxCloseIconDisc,
        "storyPanel": storyPanel,
        "storyPanelLabel": storyPanelLabel,
        "storyPanelDetail": storyPanelDetail,
        "dragHandleFill": dragHandleFill,
        "dragHandleActiveFill": dragHandleActiveFill,
        "dragHandleIcon": dragHandleIcon,
        "stateWarningText": stateWarningText,
        "stateSuccessText": stateSuccessText,
        "stateErrorText": stateErrorText,
    ]

    /// Not a surface anybody sees. The outline button is a border and a label,
    /// and a shape with no fill takes no clicks in its middle, so this is the
    /// hit area, drawn at an alpha low enough to be invisible. Named anyway,
    /// because the check that no painted fill goes unnamed cannot tell this
    /// apart from a real one, and an exception carved into the check would be
    /// the hole the next unnamed fill goes through.
    static let outlineButtonHitArea = Color.cream.opacity(0.001)

    // MARK: - Every pair, which is what the check walks
    //
    // Text and icons, not borders. Measured, the hairlines these surfaces draw
    // sit between 1.34:1 and 2.60:1 against the fill beside them, and holding
    // them to 3:1 would fail a design that is not wrong: every one of these
    // surfaces is identified by its fill, its icon and its words, so no meaning
    // rests on the border alone and the level for interface components does not
    // apply to it. What reviews them instead is the ink measurement, which a
    // border that stopped drawing at all would move (L129).

    static var all: [Pair] {
        var pairs: [Pair] = []

        for style in BrandBannerStyle.allCases {
            let behind = BrandBanner.background(style)
            pairs.append(Pair("banner \(style)", "message",
                              BrandBanner.text, on: behind, .bodyText))
            pairs.append(Pair("banner \(style)", "icon",
                              BrandBanner.icon(style), on: behind, .interfaceElement))
            pairs.append(Pair("banner \(style)", "action button",
                              BrandBanner.actionLabel, on: behind, .bodyText))
        }

        pairs.append(Pair("primary button", "label",
                          BrandButtonStyle.label, on: BrandButtonStyle.fill, .bodyText))
        // The pressed state is a different colour behind the same label, and a
        // person reads the words while pressing.
        pairs.append(Pair("primary button, pressed", "label",
                          BrandButtonStyle.label, on: BrandButtonStyle.pressedFill, .bodyText))
        pairs.append(Pair("outline button", "label",
                          outlineButtonLabel, on: page, .bodyText))

        pairs.append(Pair("insights staleness notice", "sentence",
                          AnalyticsStalenessNotice.text,
                          on: AnalyticsStalenessNotice.panel, .bodyText))
        pairs.append(Pair("insights staleness notice", "icon",
                          AnalyticsStalenessNotice.icon,
                          on: AnalyticsStalenessNotice.panel, .interfaceElement))

        let notePanel = runNotePanel.composited(over: page)
        pairs.append(Pair("run note", "sentence", runNoteText, on: notePanel, .bodyText))

        let cardPanel = failureCardPanel.composited(over: page)
        pairs.append(Pair("failure card", "day label",
                          failureCardLabel, on: cardPanel, .bodyText))
        pairs.append(Pair("failure card", "message",
                          bodyText, on: cardPanel, .bodyText))

        pairs.append(Pair("summary row", "value",
                          summaryValue, on: summaryPanel, .largeText))
        pairs.append(Pair("summary row", "label",
                          secondaryText, on: summaryPanel, .bodyText))

        let missingPanel = missingMediaPanel.composited(over: page)
        pairs.append(Pair("missing media row", "message",
                          bodyText, on: missingPanel, .bodyText))
        pairs.append(Pair("missing media row", "icon",
                          missingMediaIcon, on: missingPanel, .interfaceElement))
        pairs.append(Pair("missing media row", "locate button",
                          missingMediaAction, on: missingPanel, .bodyText))

        pairs.append(Pair("refusal note", "sentence",
                          tertiaryText, on: page, .bodyText))

        // Both roles of the accent, on both of the app's page colours, each at
        // the level its own role asks for. The deeper page is the harder one,
        // and it is where the accent as type was furthest under.
        for (name, colour, kind) in [
            ("accent text", pageAccentText, Kind.bodyText),
            ("accent icon", iconAccent, Kind.interfaceElement),
        ] {
            pairs.append(Pair(name, "on the page", colour, on: page, kind))
            pairs.append(Pair(name, "on the deeper page", colour, on: deepPage, kind))
        }

        // The faint tone in each of the roles it is actually drawn in, which is
        // the whole of #611: it was under the floor as type on all three of
        // these and in the registry on none of them.
        pairs.append(Pair("tertiary text", "sentence", tertiaryText, on: page, .bodyText))
        pairs.append(Pair("tertiary text", "sentence, on a resolved flag",
                          tertiaryText, on: resolvedFlagFill.composited(over: deepPage),
                          .bodyText))
        // The same colour as a symbol rather than as words: the handle a piece
        // is dragged by. A lower level, and it is the level the token would have
        // been judged against if only its icon role had been listed (L143).
        pairs.append(Pair("tertiary text", "reorder handle",
                          tertiaryText, on: page, .interfaceElement))
        pairs.append(Pair("field placeholder", "placeholder",
                          fieldPlaceholder, on: deepPage, .bodyText))

        // The app's ink, each role on both of the page colours it can land on
        // (#619, #620). Both, not the easier one: the whole of #619 is that
        // secondary type was judged by eye on cream and then drawn on the
        // deeper page, where the same tone is 4.33:1.
        for (name, colour, kind) in [
            ("body text", bodyText, Kind.bodyText),
            ("secondary text", secondaryText, Kind.bodyText),
            // A mark rather than words, at the level a mark is held to, and the
            // one role here allowed to stay at the tone that was too pale for
            // type. What keeps it honest is that it is registered ONLY as an
            // interface element, so using it for a sentence is using a name
            // that was never measured for one (L143).
            ("quiet mark", quietMark, Kind.interfaceElement),
        ] {
            pairs.append(Pair(name, "on the page", colour, on: page, kind))
            pairs.append(Pair(name, "on the deeper page", colour, on: deepPage, kind))
        }

        // Every stage pill, on both of the row backgrounds it can sit on
        // (#582). Per state rather than one sample of the family: the wash is
        // the pill's own colour, so each state is a different measurement and
        // the seven stages ran from 2.42:1 to 3.67:1 while nothing looked.
        for state in StagePillState.allPillStates {
            let pill = stagePill(state)
            for (where_, row) in [("at rest", eventRowAtRest), ("hovered", eventRowHovered)] {
                let wash = pill.wash.composited(over: row)
                pairs.append(Pair("stage pill \(state)", "label, row \(where_)",
                                  pill.ink, on: wash, .bodyText))
            }
        }

        // The third row state (#587). One pair, not one per stage: a selected
        // pill wears the system label colour whatever stage it is reporting.
        pairs.append(Pair("stage pill, row selected", "label",
                          selectedPillLabel,
                          on: selectedPillFill.composited(over: eventRowSelected),
                          .bodyText))

        // Every word on the row, on all three of its states (#590). The pill
        // was covered above and the type beside it was not, because a system
        // colour sits outside the palette and so no pair could name it: the
        // two lines that confirm which show was clicked were 3.68:1 on the
        // state they are read in.
        for (where_, row) in [("at rest", eventRowAtRest), ("hovered", eventRowHovered)] {
            pairs.append(Pair("event row \(where_)", "name",
                              bodyText, on: row, .largeText))
            pairs.append(Pair("event row \(where_)", "detail lines",
                              secondaryText, on: row, .bodyText))
        }
        pairs.append(Pair("event row selected", "name",
                          eventRowNameSelected, on: eventRowSelected, .largeText))
        pairs.append(Pair("event row selected", "detail lines",
                          eventRowDetailSelected, on: eventRowSelected, .bodyText))

        // The Settings window (#596). Its footers are where the app explains
        // what a setting does, and they were the platform's `.secondary` at
        // 3.95:1 on the white a form is drawn on. Nothing could report it: a
        // system colour on system chrome sits outside the palette, so no pair
        // named either half of it.
        pairs.append(Pair("settings form", "section footers",
                          readableSecondaryLabel, on: systemFormBackground, .bodyText))

        // The three state labels, on both backgrounds the app reports a state
        // on: the system form in Settings, and its own page in caption review
        // (#598).
        for (name, colour) in [("warning", stateWarningText),
                               ("success", stateSuccessText),
                               ("refusal", stateErrorText)] {
            pairs.append(Pair("state label", "\(name), on a system form",
                              colour, on: systemFormBackground, .bodyText))
            pairs.append(Pair("state label", "\(name), on the page",
                              colour, on: page, .bodyText))
        }

        // The dark panel a preview sits on, and the two lines it shows when the
        // preview could not be built (#598).
        pairs.append(Pair("story panel", "headline", storyPanelLabel,
                          on: storyPanel, .bodyText))
        pairs.append(Pair("story panel", "sentence", storyPanelDetail,
                          on: storyPanel, .bodyText))

        // The lightbox, measured over the brightest thing its backdrop can be
        // laid on, for the same reason the photo scrim is: what is behind it is
        // whatever was on screen when the photo was opened.
        let backdrop = lightboxBackdrop.composited(over: brightestPhoto)
        pairs.append(Pair("lightbox", "missing file headline",
                          lightboxLabel, on: backdrop, .bodyText))
        pairs.append(Pair("lightbox", "file name",
                          lightboxDetail, on: backdrop, .bodyText))
        pairs.append(Pair("lightbox", "close button",
                          lightboxCloseIcon,
                          on: lightboxCloseIconDisc.composited(over: backdrop),
                          .interfaceElement))

        // The caption findings badge and its panel, in both states (#600).
        for stale in [false, true] {
            let findings = captionFindings(stale: stale)
            let state = stale ? "stale" : "fresh"
            pairs.append(Pair("caption findings badge, \(state)", "count",
                              findings.ink, on: findings.badge.composited(over: page),
                              .bodyText))
            pairs.append(Pair("caption findings panel, \(state)", "sentence",
                              findings.ink, on: findings.panel.composited(over: page),
                              .bodyText))
        }

        // The two tone symbols, each mark against its own disc rather than
        // against the page (#620). The clear button is why these are named: at
        // the tone it was written in it measured under the level a mark needs,
        // on the palest disc in the app.
        pairs.append(Pair("clear button", "glyph",
                          clearButtonGlyph,
                          on: clearButtonDisc.composited(over: page),
                          .interfaceElement))
        // Over the brightest a photograph can be, like every other surface
        // drawn on one.
        pairs.append(Pair("remove button", "glyph",
                          removeButtonGlyph,
                          on: removeButtonDisc.composited(over: brightestPhoto),
                          .interfaceElement))
        pairs.append(Pair("selection tick", "glyph",
                          selectionTickGlyph, on: iconAccent, .interfaceElement))

        // A confident rating, as the dot and the tick it is drawn as.
        for (rating, colour) in [("high", insightConfidenceHigh),
                                 ("medium", insightConfidenceMedium),
                                 ("low", insightConfidenceLow)] {
            pairs.append(Pair("insight confidence", rating,
                              colour, on: page, .interfaceElement))
        }

        // The divider handle, in both of its states, over the worst a photo can
        // be underneath it.
        pairs.append(Pair("divider handle", "icon", dragHandleIcon,
                          on: dragHandleFill.composited(over: brightestPhoto),
                          .interfaceElement))
        pairs.append(Pair("divider handle, dragging", "icon", dragHandleIcon,
                          on: dragHandleActiveFill, .interfaceElement))

        pairs.append(Pair("exported count badge", "count",
                          exportedCountText, on: exportedCountBadge, .bodyText))

        let tagChip = tagChipFill.composited(over: page)
        pairs.append(Pair("tag chip", "tag", bodyText, on: tagChip, .bodyText))
        pairs.append(Pair("tag chip", "remove icon",
                          quietMark, on: tagChip, .interfaceElement))
        pairs.append(Pair("suggestion chip", "account",
                          pageAccentText, on: suggestionChipFill.composited(over: page),
                          .bodyText))

        // Measured over the brightest a photograph can be, which is the only
        // honest worst case for a surface drawn on top of a picture.
        pairs.append(Pair("photo count badge", "count",
                          photoCountText, on: photoCountBadge, .bodyText))
        let scrim = photoScrim.composited(over: brightestPhoto)
        pairs.append(Pair("photo scrim", "icon", photoScrimIcon, on: scrim, .interfaceElement))
        pairs.append(Pair("photo scrim", "counter", photoScrimText, on: scrim, .bodyText))
        pairs.append(Pair("photo hint panel", "sentence", photoScrimText,
                          on: photoHintPanel.composited(over: brightestPhoto), .bodyText))

        pairs.append(Pair("next step button", "label",
                          nextStepLabel, on: nextStepFill, .bodyText))

        let suggestionRow = suggestionRowFill.composited(over: page)
        pairs.append(Pair("suggestion row", "sentence",
                          Color.warmDark, on: suggestionRow, .bodyText))
        pairs.append(Pair("suggestion row", "dismiss icon",
                          quietMark, on: suggestionRow, .interfaceElement))
        pairs.append(Pair("reflow panel", "sentence", Color.warmDark,
                          on: reflowPanelFill.composited(over: page), .bodyText))
        pairs.append(Pair("resolved flag", "sentence", Color.warmDark,
                          on: resolvedFlagFill.composited(over: deepPage), .bodyText))
        pairs.append(Pair("section wash", "sentence", Color.warmDark,
                          on: sectionWash.composited(over: page), .bodyText))
        pairs.append(Pair("brand note field", "the note", Color.warmDark,
                          on: noteFieldFill.composited(over: page), .bodyText))
        pairs.append(Pair("tagged accounts strip", "handle", pageAccentText,
                          on: taggedAccountsFill.composited(over: page), .bodyText))
        pairs.append(Pair("add treatment tile", "label", pageAccentText,
                          on: addTreatmentFill.composited(over: page), .bodyText))

        // What stands in for a photo that has not arrived (#586).
        pairs.append(Pair("photo placeholder", "loading spinner",
                          photoPlaceholderSpinner, on: photoPlaceholder, .interfaceElement))
        pairs.append(Pair("missing photo badge", "icon",
                          missingPhotoIcon, on: photoPlaceholder, .interfaceElement))
        pairs.append(Pair("missing photo badge", "label",
                          secondaryText, on: photoPlaceholder, .bodyText))

        // The busy scrim covers the picture while it is being remade, and says
        // so in words, so it is measured against the brightest a photo can be
        // like every other surface drawn on one.
        pairs.append(Pair("busy scrim", "label", photoScrimText,
                          on: photoScrim.composited(over: brightestPhoto), .bodyText))

        // The Dock, which is a surface like any other: it carries words, and
        // they are read at a glance from across a desk (#863).
        pairs.append(Pair("dock working band", "elapsed clock",
                          dockWorkingClock, on: dockWorkingBand, .bodyText))

        return pairs
    }
}
