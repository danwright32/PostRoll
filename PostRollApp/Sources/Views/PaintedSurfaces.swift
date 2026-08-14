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
    static let failureCardMessage = Color.warmDark

    /// The row of counts on the configure screen.
    static let summaryPanel = Color.creamDeep
    static let summaryBorder = Color.creamEdge
    static let summaryValue = Color.roseGold
    /// Deeper than the `warmMid` this used to be. On `creamDeep` that pair
    /// measured 4.33:1, under the 4.5:1 its 9pt label needs, and nothing said
    /// so: the row is mostly its own panel, so the ink check read it as full
    /// whatever the label did (#574).
    static let summaryLabel = Color.warmDark.opacity(0.8)

    /// The row saying photos have gone missing off disk.
    static let missingMediaPanel = Color.roseGold.opacity(0.08)
    static let missingMediaBorder = Color.roseGold.opacity(0.25)
    static let missingMediaIcon = Color.roseGold
    static let missingMediaMessage = Color.warmDark
    /// Deeper than `roseGold`, which measured 3.92:1 on this panel against the
    /// 4.5:1 its 11pt label needs. Same reason as the banner's action buttons
    /// below, and the same remedy #569 used on the primary button (#574).
    static let missingMediaAction = Color.roseDeep

    /// Type drawn straight onto the page, with no fill of its own. Named for
    /// the same reason: the check has to be able to say it looked at these too.
    static let refusalNoteText = Color.warmMid
    static let outlineButtonLabel = Color.roseDeep

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
                          failureCardMessage, on: cardPanel, .bodyText))

        pairs.append(Pair("summary row", "value",
                          summaryValue, on: summaryPanel, .largeText))
        pairs.append(Pair("summary row", "label",
                          summaryLabel, on: summaryPanel, .bodyText))

        let missingPanel = missingMediaPanel.composited(over: page)
        pairs.append(Pair("missing media row", "message",
                          missingMediaMessage, on: missingPanel, .bodyText))
        pairs.append(Pair("missing media row", "icon",
                          missingMediaIcon, on: missingPanel, .interfaceElement))
        pairs.append(Pair("missing media row", "locate button",
                          missingMediaAction, on: missingPanel, .bodyText))

        pairs.append(Pair("refusal note", "sentence",
                          refusalNoteText, on: page, .bodyText))

        return pairs
    }
}
