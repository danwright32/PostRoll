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
    // Sunday 7, Monday and Wednesday 4 (#900). Sunday's post for Battery Dance
    // Festival had 7 photos worth using and the app used 4, and there was no
    // way to ask for all 7 because 7 was not a count any preset could name.
    // A preset governs all three collage days at once, so this cannot say
    // "Sunday only" without declaring what the other two do; they stay at 4.
    case opening

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .balanced: return "Balanced (4·4·4)"
        case .classic:  return "Classic (1·1·10)"
        case .opening:  return "Opening (7·4·4)"
        }
    }

    /// One clause describing what this preset posts, for the sentence under the
    /// picker (#900).
    ///
    /// Here rather than typed into the Settings copy, which hand listed two of
    /// them and would have gone on describing two presets while the picker
    /// offered three. A list that has to mirror another source is derived from
    /// it, never maintained beside it (L41).
    var explanation: String {
        switch self {
        case .balanced:
            return "Balanced posts a 4 photo carousel with a collage story on "
                + "Sunday, Monday and Wednesday"
        case .classic:
            return "Classic posts a single photo Sunday and Monday plus a 10 "
                + "photo Wednesday"
        case .opening:
            return "Opening posts 7 photos on Sunday and 4 on Monday and "
                + "Wednesday"
        }
    }

    /// What every preset does, in one sentence, in picker order.
    static var explanations: String {
        allCases.map(\.explanation).joined(separator: "; ") + "."
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
        case (.opening, .sunday):
            return (.collageCarousel, 7)
        case (.opening, .monday), (.opening, .wednesday):
            return (.collageCarousel, 4)
        default:
            return nil
        }
    }

    func isCollageCarousel(_ day: DayName) -> Bool {
        format(for: day)?.format == .collageCarousel
    }

    /// How many of `day`'s assigned photos this preset actually posts (#1010).
    ///
    /// `min(assigned, target)`, because `generate_media.py` renders
    /// `photos[:count]`. A target above the assigned count changes nothing: a
    /// Sunday with three photos posts three under every preset that governs it,
    /// so switching between them is not a change to that day at all.
    ///
    /// nil for a day no preset governs, the same as `format(for:)`, so the
    /// absence keeps meaning "this day's own handling decides" rather than
    /// "zero". Mirrored by `posting_preset.effective_count` through
    /// `tests/fixtures/posting_presets.json`.
    func effectiveCount(for day: DayName, assigned: Int) -> Int? {
        guard let count = format(for: day)?.count else { return nil }
        return min(assigned, count)
    }

    /// What kind of post `day` is, given how many photos are assigned to it.
    ///
    /// The question that decides whether a layout switch needs a PAID caption
    /// rebuild, and deliberately not the same question as the format. Python's
    /// rule includes `photo_count > 1`, so a collage day with ONE photo is a
    /// `feed_photo`, exactly like a single day with one: a Balanced to Classic
    /// switch on such a day changes the format and does not change the post.
    /// Keying the rebuild on format alone pays for that day for nothing.
    ///
    /// Strings rather than an enum because they are Python's wire values and
    /// this exists to agree with them; an enum would need a rawValue that
    /// exists only for the mirror and could be wrong without anything noticing.
    /// Mirrored by `posting_preset.post_type`, which `generate_week` delegates
    /// to, so the app and the pipeline cannot answer this differently (L263).
    func postType(for day: DayName, assigned: Int) -> String {
        if isCollageCarousel(day) && assigned > 1 { return "carousel" }
        if day == .thursday && assigned > 1 { return "scroll_reel" }
        return "feed_photo"
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
    static var current: PostingPreset { current(in: AppPreferences.store) }

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

/// What one day needs when the posting layout changes (#1010).
enum DayLayoutChange: Equatable {
    /// Its images are different, its post is not. No caption call.
    case redrawImages
    /// It becomes a different KIND of post, so its caption is written
    /// differently and has to be regenerated.
    case rebuildPost
}

/// Which days a posting layout switch actually has to touch (#1010).
///
/// `PostingPreset.affectedDays` answers a different question: every governed
/// day that HAS PHOTOS, without ever comparing the two layouts. Switching
/// Balanced to Opening moves Sunday from 4 photos to 7 and leaves Monday and
/// Wednesday exactly as they were, yet all three were caption regenerated: paid
/// API calls that changed nothing, and any typed caption edits on those two
/// days destroyed.
enum PostingLayoutSwitch {

    /// Per day, what changing from `old` to `new` requires of `event`.
    ///
    /// Days needing nothing are ABSENT rather than present with a "no change"
    /// case, so a caller cannot accidentally pass the whole map to a generator.
    ///
    /// Two predicates, not one. The plan for this originally keyed the paid
    /// half on the FORMAT, which is wrong: Python decides a day's post type
    /// with `is_collage_carousel(preset, day) and photo_count > 1`, so a
    /// collage day with ONE photo is a feed_photo exactly like a single day
    /// with one. Balanced to Classic on such a day changes the format and does
    /// not change the post, and rebuilding its caption buys nothing.
    ///
    /// Counts are EFFECTIVE counts, because the renderer takes `photos[:count]`.
    /// A Sunday with three photos posts three under every layout that governs
    /// it, so no switch between them touches that day at all.
    static func plan(from old: PostingPreset,
                     to new: PostingPreset,
                     in event: Event) -> [DayName: DayLayoutChange] {
        var plan: [DayName: DayLayoutChange] = [:]
        for day in DayName.allCases {
            // A day no preset governs has a fixed format that no switch moves.
            guard old.format(for: day) != nil || new.format(for: day) != nil else { continue }

            let assigned = event.days[day.rawValue]?.photoPaths.count ?? 0
            // Nothing to draw and nothing to write about, either way.
            guard assigned > 0 else { continue }

            if old.postType(for: day, assigned: assigned)
                != new.postType(for: day, assigned: assigned) {
                plan[day] = .rebuildPost
            } else if old.format(for: day)?.format != new.format(for: day)?.format
                || old.effectiveCount(for: day, assigned: assigned)
                    != new.effectiveCount(for: day, assigned: assigned) {
                plan[day] = .redrawImages
            }
        }
        return plan
    }

    /// The two kinds of work a plan asks for, kept apart because one of them
    /// costs money and the other does not.
    struct Work: Equatable {
        /// Day names for the caption generator, in its own currency (raw
        /// strings, which is what `retryDays` takes). Empty means NO caption
        /// call, which is the whole point of #1010.
        let rebuildDays: Set<String>
        /// Days needing only their images redrawn. Sorted, so a switch reports
        /// and runs the same way twice rather than in dictionary order.
        let redrawDays: [DayName]
    }

    /// Split a plan into what has to be regenerated and what only has to be
    /// redrawn.
    ///
    /// A day lands in exactly one of the two. Both halves write that day's
    /// media, so a day in both would be two writers on one file, which is the
    /// hazard #1009's claim exclusion exists to prevent.
    static func work(_ plan: [DayName: DayLayoutChange]) -> Work {
        Work(rebuildDays: Set(plan.filter { $0.value == .rebuildPost }.keys.map(\.rawValue)),
             redrawDays: DayName.allCases.filter { plan[$0] == .redrawImages })
    }
}

/// Copy for the per-event posting layout picker (#1007).
///
/// Here rather than inside the view, because the sentence was written as a
/// two-way ternary over THREE presets and could not be tested where it lived:
/// selecting Opening printed Classic's sentence, and nothing anywhere could
/// notice. `SettingsView` stayed correct through the same change because it
/// reads `explanations` rather than restating them (L41).
enum PostingLayoutCopy {
    /// The sentence under the picker, describing what THIS event posts.
    ///
    /// Says "this event" because the Settings screen shows a sentence about the
    /// app wide default in the same words, and a reader has to be able to tell
    /// which of the two they are looking at.
    static func thisEvent(_ preset: PostingPreset) -> String {
        "This event: \(preset.explanation)."
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

    private let defaults: UserDefaults

    /// The one initializer, and every caller says which preferences it reads.
    ///
    /// It used to default to `.standard`, and `SettingsView` built its own
    /// store and took that default while being compiled into the test bundle,
    /// so any test rendering that screen read Dan's real posting layout and
    /// would have written it back the moment a rendered control moved the
    /// picker (#727). A test passing its own scratch suite was already the
    /// convention (#116), and a convention is not a structure (L2).
    init(defaults: UserDefaults) {
        self.defaults = defaults
        selected = PostingPreset.current(in: defaults)
    }

    #if !POSTROLL_TESTS
    /// The app's own store, on Dan's real preferences.
    ///
    /// Compiled out of the test bundle, so a test that does not say which
    /// preferences it means is a build error rather than a silent read of the
    /// live one. The condition is set on the test target only, in project.yml.
    convenience init() {
        self.init(defaults: .standard)
    }
    #endif

    func save() {
        defaults.set(selected.rawValue, forKey: PostingPreset.storageKey)
    }
}
