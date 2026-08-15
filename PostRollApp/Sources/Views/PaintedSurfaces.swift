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

    /// A dynamic system colour as it lands under the appearance the app pins
    /// itself to, rather than under whatever is current where this is read.
    private static func inPinnedAppearance(_ colour: Color) -> Color {
        var resolved = colour
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
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
    static let tagChipText = Color.warmDark
    static let tagChipRemoveIcon = Color.warmMid
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

    /// The panel that explains why cell editing is off, over the collage.
    static let photoHintPanel = Color.black.opacity(0.65)

    // OCR review.

    /// A suggested correction, and the control that dismisses it. The icon was
    /// `warmMid` at half strength, which is 1.98:1 on this row (#582).
    static let suggestionRowFill = Color.warmDark.opacity(0.03)
    static let suggestionRowDismissIcon = Color.warmMid
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
    static let missingPhotoLabel = Color.warmDark.opacity(0.8)

    /// The backdrop behind a photo opened at full size. Deliberately not a
    /// pair: the photograph is drawn on top of it and nothing else is, so
    /// there are no words to read against it. Named so it cannot be mistaken
    /// for the scrim above, which does carry a label.
    static let lightboxBackdrop = Color.black.opacity(0.78)

    /// The Instagram post preview.
    ///
    /// Deliberately not pairs. This card is a drawing of somebody else's
    /// product, so it is white because Instagram is white, and holding it to
    /// this app's palette would be holding a photograph of a thing to the
    /// thing's own rules. Named for the same reason `mastheadWordmark` is: so
    /// the exemption is a decision somebody made rather than a gap the check
    /// cannot see (L129).
    static let instagramCard = Color.white
    static let instagramAvatarRing = Color.white
    static let instagramOverlayButton = Color.white.opacity(0.92)

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
        "page": page,
        "deepPage": deepPage,
        "runNotePanel": runNotePanel,
        "runNoteText": runNoteText,
        "failureCardPanel": failureCardPanel,
        "failureCardLabel": failureCardLabel,
        "failureCardMessage": failureCardMessage,
        "summaryPanel": summaryPanel,
        "summaryBorder": summaryBorder,
        "summaryValue": summaryValue,
        "summaryLabel": summaryLabel,
        "missingMediaPanel": missingMediaPanel,
        "missingMediaBorder": missingMediaBorder,
        "missingMediaIcon": missingMediaIcon,
        "missingMediaMessage": missingMediaMessage,
        "missingMediaAction": missingMediaAction,
        "refusalNoteText": refusalNoteText,
        "outlineButtonLabel": outlineButtonLabel,
        "outlineButtonHitArea": outlineButtonHitArea,
        "pageAccentText": pageAccentText,
        "iconAccent": iconAccent,
        "mastheadWordmark": mastheadWordmark,
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
        "exportedCountBadge": exportedCountBadge,
        "exportedCountText": exportedCountText,
        "tagChipFill": tagChipFill,
        "tagChipText": tagChipText,
        "tagChipRemoveIcon": tagChipRemoveIcon,
        "suggestionChipFill": suggestionChipFill,
        "photoCountBadge": photoCountBadge,
        "photoCountText": photoCountText,
        "sectionWash": sectionWash,
        "nextStepFill": nextStepFill,
        "nextStepLabel": nextStepLabel,
        "brightestPhoto": brightestPhoto,
        "photoScrim": photoScrim,
        "photoScrimIcon": photoScrimIcon,
        "photoScrimText": photoScrimText,
        "photoHintPanel": photoHintPanel,
        "suggestionRowFill": suggestionRowFill,
        "suggestionRowDismissIcon": suggestionRowDismissIcon,
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
        "dividerRule": dividerRule,
        "photoPlaceholder": photoPlaceholder,
        "photoPlaceholderSpinner": photoPlaceholderSpinner,
        "missingPhotoIcon": missingPhotoIcon,
        "missingPhotoLabel": missingPhotoLabel,
        "lightboxBackdrop": lightboxBackdrop,
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

        pairs.append(Pair("exported count badge", "count",
                          exportedCountText, on: exportedCountBadge, .bodyText))

        let tagChip = tagChipFill.composited(over: page)
        pairs.append(Pair("tag chip", "tag", tagChipText, on: tagChip, .bodyText))
        pairs.append(Pair("tag chip", "remove icon",
                          tagChipRemoveIcon, on: tagChip, .interfaceElement))
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
                          suggestionRowDismissIcon, on: suggestionRow, .interfaceElement))
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
                          missingPhotoLabel, on: photoPlaceholder, .bodyText))

        // The busy scrim covers the picture while it is being remade, and says
        // so in words, so it is measured against the brightest a photo can be
        // like every other surface drawn on one.
        pairs.append(Pair("busy scrim", "label", photoScrimText,
                          on: photoScrim.composited(over: brightestPhoto), .bodyText))

        return pairs
    }
}
