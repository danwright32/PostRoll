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

    /// UserDefaults key shared with `PostingPresetStore`.
    static let storageKey = "postroll.posting.preset.v1"

    /// The currently persisted app wide preset, readable from any thread.
    /// Defaults to `.balanced` when nothing is stored yet.
    static var current: PostingPreset {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
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

    init() { selected = PostingPreset.current }

    func save() {
        UserDefaults.standard.set(selected.rawValue, forKey: PostingPreset.storageKey)
    }
}
