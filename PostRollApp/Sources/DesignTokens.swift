import SwiftUI

// MARK: - Colors
//
// Mirrors the brand palette in `postroll/media/design_tokens.py`, which is the
// source: Swift cannot import it, so the values are restated here and
// `tests/test_design_tokens.py` asserts the two agree. Nothing else keeps this
// seam honest, and an app that draws a different cream from the asset it
// exports is exactly the kind of mismatch that reads as a rendering bug.
//
// The colours below with no Python counterpart (creamDeep, roseDeep, warmFaint,
// the stage pills) are app chrome that no generator paints, and stay Swift-only.

extension Color {
    /// Main window / detail background — warm off-white
    static let cream     = Color(red: 252/255, green: 250/255, blue: 247/255)
    /// Sidebar / secondary surface — slightly deeper cream
    static let creamDeep = Color(red: 237/255, green: 232/255, blue: 224/255)
    /// Dividers, subtle borders, and the hairline around a matted print in the
    /// before/after and morph templates
    static let creamEdge = Color(red: 212/255, green: 201/255, blue: 192/255)
    /// Hairline around a collage cell and a scroll-reel print. Two units off
    /// `creamEdge` above, which is historical drift rather than intent; both
    /// are preserved so no rendered pixel moves. See #162.
    static let hairline  = Color(red: 214/255, green: 208/255, blue: 200/255)

    /// Primary accent — rose gold
    static let roseGold  = Color(red: 160/255, green: 105/255, blue:  95/255)
    /// Pressed / active rose gold
    static let roseDeep  = Color(red: 125/255, green:  78/255, blue:  68/255)

    /// Primary text — warm near-black
    static let warmDark  = Color(red:  60/255, green:  55/255, blue:  50/255)
    /// Secondary text — warm mid-tone
    static let warmMid   = Color(red: 122/255, green: 104/255, blue:  96/255)
    /// Placeholder / tertiary
    static let warmFaint = Color(red: 175/255, green: 160/255, blue: 152/255)

    // MARK: Stage pill colors
    // Warm editorial progression — all calibrated as foreground at 0.14 opacity on creamDeep.
    // Rule: every color must lean warm (R ≥ B). No cool blues or hospital greens.

    /// Step 1 — Event Created
    static let stageCreated          = warmMid
    /// Step 2 — Program Uploaded: warm rose, one step past neutral
    static let stageProgramUploaded  = Color(red: 175/255, green: 130/255, blue: 120/255)
    /// Step 3 — OCR Done: rose gold (primary accent marks this milestone)
    static let stageOCRDone          = roseGold
    /// Step 4 — Photos Assigned: warm amber
    static let stagePhotosAssigned   = Color(red: 165/255, green: 120/255, blue:  85/255)
    /// Step 5 — Assets Generated: warm olive gold
    static let stageAssetsGenerated  = Color(red: 150/255, green: 125/255, blue:  70/255)
    /// Step 6 — Captions Reviewed: warm sage (R ≈ B keeps it from going clinical)
    static let stageCaptionsReviewed = Color(red: 115/255, green: 140/255, blue: 105/255)
    /// Step 7 — Exported: warm forest green (R > B — yellow-green, not blue-green)
    static let stageExported         = Color(red:  85/255, green: 125/255, blue:  60/255)
}

// MARK: - Fonts

extension Font {
    /// SignPainter: display / event-name headline
    static func signPainter(_ size: CGFloat) -> Font {
        .custom("SignPainter-HouseScript", size: size)
    }

    /// Helvetica Neue Light: UI labels, metadata
    static func light(_ size: CGFloat) -> Font {
        .custom("HelveticaNeue-Light", size: size)
    }
}

// MARK: - Corner Radii

enum Radius {
    static let xs:   CGFloat = 4
    static let sm:   CGFloat = 6
    static let md:   CGFloat = 8
    static let lg:   CGFloat = 12
}

// MARK: - Spacing

enum Spacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32

    /// Sidebar list row insets — horizontal leading/trailing edge
    static let rowInset: CGFloat = 12
    /// Sidebar list row insets — vertical top/bottom edge
    static let rowV:     CGFloat = 6
}

// MARK: - Opacity

enum Opacity {
    /// Icon ghost, display headings — decorative elements that recede behind content
    static let subtle: Double = 0.35
    /// Hairline rules — structural but visually lightweight
    static let faint:  Double = 0.30
}

// MARK: - RoseGold Divider

struct RoseGoldDivider: View {
    var opacity: Double = 0.6
    var body: some View {
        Rectangle()
            .fill(Color.roseGold.opacity(opacity))
            .frame(height: 0.5)
    }
}
