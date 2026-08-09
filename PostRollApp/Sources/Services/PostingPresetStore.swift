import Foundation
import Observation

/// How a posting day is shaped.
enum DayFormat: Equatable {
    case single           // one feed photo + story.png
    case collageCarousel  // carousel feed + collage.png (doubles as the story)
}

/// The app wide posting preset. Mirrors `postroll/posting_preset.py` exactly —
/// the `rawValue` strings are what travel in the manifest to Python.
enum PostingPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case balanced   // Sun/Mon/Wed: 4 photo carousel + 4 photo collage story
    case classic    // Sun/Mon: single feed photo + story; Wed: 10 photo carousel + collage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .balanced: return "Balanced (4·4·4)"
        case .classic:  return "Classic (1·1·10)"
        }
    }

    /// `(format, photoCount)` for a preset governed day, else nil for days the
    /// preset doesn't control (Tuesday, Thursday, Friday).
    func format(for day: DayName) -> (format: DayFormat, count: Int)? {
        switch (self, day) {
        case (.balanced, .sunday), (.balanced, .monday), (.balanced, .wednesday):
            return (.collageCarousel, 4)
        case (.classic, .sunday), (.classic, .monday):
            return (.single, 1)
        case (.classic, .wednesday):
            return (.collageCarousel, 10)
        default:
            return nil
        }
    }

    func isCollageCarousel(_ day: DayName) -> Bool {
        format(for: day)?.format == .collageCarousel
    }

    /// The days a switch to this layout would rebuild for `event`: the
    /// preset-governed days (Sunday/Monday/Wednesday) that actually have photos.
    /// Used to warn before a switch regenerates posts (#71).
    func affectedDays(in event: Event) -> [DayName] {
        DayName.allCases.filter {
            format(for: $0) != nil && !(event.days[$0.rawValue]?.photoPaths.isEmpty ?? true)
        }
    }

    /// UserDefaults key shared with `PostingPresetStore`.
    static let storageKey = "postroll.posting.preset.v1"

    /// The currently persisted app wide preset, readable from any thread.
    /// Defaults to `.balanced` when nothing is stored yet.
    static var current: PostingPreset { current(in: .standard) }

    /// Where the preset is read from, injectable so a test never touches the
    /// real preference (#116).
    ///
    /// The tests saved and restored the live value around themselves, which is
    /// careful but not safe: a crash between the two leaves Dan's actual
    /// posting layout changed, and two suites running at once clobber each
    /// other. A seam removes the possibility rather than managing it.
    static func current(in defaults: UserDefaults) -> PostingPreset {
        guard let raw = defaults.string(forKey: storageKey),
              let preset = PostingPreset(rawValue: raw) else { return .balanced }
        return preset
    }
}

/// Pure decision logic for the "change collage photos" picker, extracted so it
/// can be unit-tested without the SwiftUI view (issue #63 regression cover).
enum CollagePhotoSelection {
    /// Smallest set the collage generator can lay out (a 2-photo grid).
    static let minimum = 2

    /// The preset's target photo count for a day's collage (guidance, not a hard cap).
    static func target(preset: PostingPreset, day: DayName) -> Int {
        preset.format(for: day)?.count ?? 10
    }

    /// Whether a day has enough photos for the collage generator to lay out.
    ///
    /// The gate is `minimum`, NOT the preset target (#195). The upload page
    /// hardcoded 10, a literal left over from the Classic preset, so under the
    /// default Balanced preset a Wednesday with its full 4 photos was told it
    /// needed 6 more, and the reroll button behind the same check was
    /// unreachable for the entire default preset. The generator has a
    /// dedicated four-photo layout table and adapts below the target.
    static func canGenerate(photoCount: Int) -> Bool {
        photoCount >= minimum
    }

    /// What to say when a day cannot generate its collage yet.
    ///
    /// Counts against the floor, not the target, so it never asks for photos
    /// that are not actually required.
    static func shortfallMessage(photoCount: Int) -> String? {
        guard !canGenerate(photoCount: photoCount) else { return nil }
        let needed = minimum - photoCount
        return "Need at least \(minimum) photos to generate the collage. "
            + "\(needed) more required."
    }

    /// Photo counts at which the generator has more than one arrangement to
    /// choose from, so rerolling produces a visibly different collage.
    ///
    /// Measured from `distinct_collage_splits` filtered by `split_fits_photos`,
    /// for Dan's 3:2 frames, and recorded in
    /// `tests/fixtures/collage_arrangements.json`. Both languages read that one
    /// file; `CollageLayoutSectionTests` fails if this range and the recorded
    /// counts disagree, so the enumeration cannot change underneath this.
    ///
    /// Below 4 there is exactly one arrangement, so a reroll redraws the same
    /// collage. Above 10 nothing fits the crop budget and the renderer falls
    /// back to a single forced layout, so there is nothing to reroll there
    /// either. Offering the button anyway is a control that visibly does
    /// nothing (#195).
    static let alternativeLayoutRange = 4...10

    static func offersAlternativeLayouts(photoCount: Int) -> Bool {
        alternativeLayoutRange.contains(photoCount)
    }

    /// Told to Dan when a day has more photos than its collage will use, so he
    /// knows which ones are in and can drag to reorder.
    ///
    /// Counts against the PRESET's target rather than a literal. The literal
    /// was 10, left over from Classic, so under Balanced this stayed silent
    /// from 5 to 10 photos, which is exactly the range where it was needed
    /// (#195, #119).
    static func extraPhotosNote(photoCount: Int, preset: PostingPreset,
                                day: DayName) -> String? {
        guard preset.isCollageCarousel(day) else { return nil }
        let target = target(preset: preset, day: day)
        guard photoCount > target else { return nil }
        return "Collage uses the first \(target) photos (\(photoCount) assigned). "
            + "Drag to reorder."
    }

    /// What to tell Dan when a day's collage was skipped for want of photos.
    ///
    /// Names the real floor and the day that actually failed. The old copy said
    /// 10 for Wednesday only, so under Balanced it asked for six photos more
    /// than the generator needs and contradicted the same screen's own advice
    /// (#119).
    static func generationShortfallHint(day: DayName) -> String {
        "Collage needs at least \(minimum) photos. "
            + "Add more photos to \(day.displayName) and retry."
    }

    /// An error message when the selection is below the floor, else nil. The
    /// floor is `minimum`, NOT the preset target — the generator adapts to
    /// fewer than the target, so picking 3 for a 4-photo day is allowed.
    static func validationError(selectedCount: Int, dayDisplayName: String) -> String? {
        guard selectedCount < minimum else { return nil }
        return "The \(dayDisplayName) collage needs at least \(minimum) photos (you picked \(selectedCount))."
    }
}

@MainActor
@Observable
final class PostingPresetStore {
    var selected: PostingPreset = .balanced

    /// Defaults to the real store; a test passes its own scratch suite so the
    /// live preference is never written (#116).
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = PostingPreset.current(in: defaults)
    }

    func save() {
        defaults.set(selected.rawValue, forKey: PostingPreset.storageKey)
    }
}
