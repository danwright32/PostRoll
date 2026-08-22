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

/// What the phone and Instagram draw over a full-frame asset (#753).
///
/// Mirrors `design_tokens.SAFE_TOP`, `SAFE_BOTTOM`, `SAFE_RIGHT` and
/// `SAFE_RIGHT_FROM`; nothing but the parity test in
/// tests/test_safe_area_tokens.py keeps the two in step. The Python side is the
/// source and carries the measurement, its date and the phone it came from.
///
/// The app needs them so the caption review screen can show a preview the way
/// Instagram will show it. That gap is how #752 survived: the show title had
/// been printed under the clock on every scroll reel published, every local
/// render looked perfect, and the only detector was Dan seeing a live story on
/// his phone.
///
/// In canvas pixels of a 1080 by 1920 frame, so a view scales them by whatever
/// it is drawing that frame at rather than carrying its own copy in points.
enum PhoneSafeArea {
    /// The status bar and the Dynamic Island.
    static let top: CGFloat = 170
    /// Instagram's account row and caption.
    static let bottom: CGFloat = 160
    /// Instagram's like, comment, share and save rail.
    static let right: CGFloat = 240
    /// Where that rail starts, as a fraction of the frame's height.
    static let rightFrom: CGFloat = 0.54

    /// The frame these are measured against, so a view scaling them has the
    /// denominator to hand rather than restating 1080 by 1920 itself.
    static let canvas = CGSize(width: 1080, height: 1920)
}


/// Which generation of the collage design this build renders (#160).
///
/// Mirrors `design_tokens.COLLAGE_DESIGN_VERSION`; nothing but the parity test
/// in tests/test_collage_design_version.py keeps the two in step. A cached
/// collage stamped with less than this, or with nothing at all, was made by an
/// older design, and is badged rather than left to render the old look
/// indefinitely until somebody happens to regenerate that day.
enum CollageDesign {
    static let collageDesignVersion = 1
}

/// Which generation of each template's design this build renders (#286).
///
/// Mirrors `design_tokens.MEDIA_DESIGN_VERSIONS`; nothing but the parity test in
/// tests/test_media_design_version.py keeps the two in step. #160 stamped the
/// collage only, so a cached scroll reel, Tuesday reel, before/after or story
/// rendered before the same gallery redesign kept rendering the old look
/// indefinitely with nothing saying so. The reels are the worst of it, because
/// re-rendering one is expensive enough that nobody does it speculatively.
///
/// Keyed by the filename stem the generator writes into a day folder, which is
/// what the stamp records and what a day folder is scanned for.
enum MediaDesign {
    static let mediaDesignVersions: [String: Int] = [
        "collage": 1,
        "story": 2,
        "cover": 2,
        "before_after": 2,
        "reel_screen": 2,
        "reel_morph": 3,
        "reel_slider": 3,
        "reel_scroll": 2,
        "reel_preview": 2,
        "reel_clip": 2,
    ]

    /// The day each template's CURRENT design version was set (#804).
    ///
    /// Mirrors `MEDIA_DESIGN_CHANGED` in `postroll/media/design_tokens.py`,
    /// which is where the reasoning lives and which
    /// `tests/test_media_design_version.py` holds this to.
    ///
    /// The badge used to fire only on a recorded version, and there were zero
    /// stamps under the whole preview library, so it covered no asset that
    /// existed. A file's own modification date is evidence nobody has to
    /// invent, so an UNSTAMPED asset older than the day its template's design
    /// changed is badged too.
    ///
    /// Only templates whose version has actually been BUMPED are here. One
    /// still at its first version has no change to be older than, only a date
    /// on which a number was first written down.
    static let mediaDesignChanged: [String: String] = [
        "story": "2026-08-21",
        "cover": "2026-08-21",
        "before_after": "2026-08-21",
        "reel_screen": "2026-08-21",
        "reel_morph": "2026-08-21",
        "reel_slider": "2026-08-21",
        "reel_scroll": "2026-08-20",
        "reel_preview": "2026-08-20",
        "reel_clip": "2026-08-22",
    ]

    /// Every template this build knows how to judge.
    static var allTemplates: [String] { mediaDesignVersions.keys.sorted() }

    /// The day `template`'s design last changed, or nil for one that has never
    /// been bumped and therefore has no change to be older than.
    static func changed(of template: String) -> Date? {
        guard let text = mediaDesignChanged[template] else { return nil }
        return isoDay.date(from: text)
    }

    /// Dates are calendar days in the local zone, matching the Python half,
    /// which compares `date.fromtimestamp` against `date.fromisoformat`.
    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        // A fixed locale, or a device on a non-Gregorian calendar parses the
        // same string into a different day.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// The design generation this build renders `template` at, or nil for one it
    /// does not know (an asset from a newer build, which regenerating here could
    /// only make worse).
    static func version(of template: String) -> Int? { mediaDesignVersions[template] }
}

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

    /// The fill behind a primary button's label, and only that (#569).
    ///
    /// Deeper than `roseGold` because it is the one place the accent has cream
    /// TEXT on it rather than sitting beside text. At `roseGold` that pair
    /// measures 4.31:1, just under the 4.5:1 WCAG AA asks for at the label's
    /// 13pt; here it measures 5.05:1. `roseGold` itself is unchanged, because
    /// its other 240-odd uses are borders, icons and rules, where the level
    /// that matters is the 3:1 for interface components and it clears that.
    ///
    /// `BannerLegibilityTests.testTheRescanLabelHasReadableContrastAgainstItsFill`
    /// holds the pair at 4.5:1, so this cannot drift back.
    static let roseButton = Color(red: 146/255, green:  95/255, blue:  86/255)

    /// Primary text — warm near-black
    static let warmDark  = Color(red:  60/255, green:  55/255, blue:  50/255)
    /// Secondary text — warm mid-tone
    static let warmMid   = Color(red: 122/255, green: 104/255, blue:  96/255)
    /// Placeholder / tertiary
    static let warmFaint = Color(red: 175/255, green: 160/255, blue: 152/255)

    // MARK: Stage pill colors
    //
    // Warm editorial progression, each drawn as a 0.14 wash behind the pill.
    // Rule: every color must lean warm (R ≥ B). No cool blues or hospital greens.
    //
    // These are the WASH. They are not the words on it: measured against their
    // own wash on an event row, the seven of them run from 2.42:1 to 3.67:1,
    // every one under the 4.5:1 the pill's 10pt label needs (#582). This block
    // used to say they were "calibrated as foreground at 0.14 opacity on
    // creamDeep", which is what the design intends and what nothing held them
    // to, so the calibration was a claim rather than a measurement.
    //
    // The ink beside each one is that same hue carried down until the label
    // clears its own wash, on the plain row and on the warmer hovered one. The
    // wash is untouched, so the progression a person reads across the list is
    // the same; only the words on it moved. Same shape as the accent's two
    // roles (#580): one colour cannot answer for both a fill and the type on it.
    //
    // PaintedSurfaces.stagePill pairs each wash with its ink and is what the
    // pill draws from, and BannerLegibilityTests walks every state.

    /// Step 1 — Event Created
    static let stageCreated          = warmMid
    static let stageCreatedInk       = Color(red: 102/255, green:  87/255, blue:  81/255)
    /// Step 2 — Program Uploaded: warm rose, one step past neutral
    static let stageProgramUploaded  = Color(red: 175/255, green: 130/255, blue: 120/255)
    static let stageProgramUploadedInk = Color(red: 115/255, green:  86/255, blue:  79/255)
    /// Step 3 — OCR Done: rose gold (primary accent marks this milestone)
    static let stageOCRDone          = roseGold
    static let stageOCRDoneInk       = Color(red: 122/255, green:  80/255, blue:  72/255)
    /// Step 4 — Photos Assigned: warm amber
    static let stagePhotosAssigned   = Color(red: 165/255, green: 120/255, blue:  85/255)
    static let stagePhotosAssignedInk = Color(red: 117/255, green:  85/255, blue:  60/255)
    /// Step 5 — Assets Generated: warm olive gold
    static let stageAssetsGenerated  = Color(red: 150/255, green: 125/255, blue:  70/255)
    static let stageAssetsGeneratedInk = Color(red: 106/255, green:  89/255, blue:  50/255)
    /// Step 6 — Captions Reviewed: warm sage (R ≈ B keeps it from going clinical)
    static let stageCaptionsReviewed = Color(red: 115/255, green: 140/255, blue: 105/255)
    static let stageCaptionsReviewedInk = Color(red:  79/255, green:  97/255, blue:  72/255)
    /// Step 7 — Exported: warm forest green (R > B — yellow-green, not blue-green)
    static let stageExported         = Color(red:  85/255, green: 125/255, blue:  60/255)
    static let stageExportedInk      = Color(red:  67/255, green:  99/255, blue:  47/255)

    /// The accent and the deep accent as pill ink, for the states that are not
    /// a stage: the four that report work in flight wear `roseGold`, and the
    /// two failures wear `roseDeep`. `roseDeep` on its own wash measures
    /// 4.44:1 on a hovered row, just under, so both get carried down the same
    /// way rather than one of them being left as the exception nobody rechecks.
    static let stageBusyInk          = Color(red: 122/255, green:  80/255, blue:  72/255)
    static let stageFailedInk        = Color(red: 122/255, green:  76/255, blue:  67/255)
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
            .fill(PaintedSurfaces.dividerRule.opacity(opacity))
            .frame(height: 0.5)
    }
}
