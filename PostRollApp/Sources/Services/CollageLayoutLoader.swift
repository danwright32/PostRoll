import Foundation
import Observation

/// Owns the layout gallery's render, so it outlives the sheet that opened it
/// (#718).
///
/// Rendering the options is a real render of every candidate collage. Its in
/// flight flag, its error and the candidates themselves lived in
/// `CollageLayoutGallery`'s own state, so closing the sheet, or switching
/// events with it open, threw the render away part way through and the next
/// open started again from nothing.
///
/// The results already had somewhere app scoped to live:
/// `CollageCandidateCache`, which exists so reopening shows the SAME options
/// rather than a fresh set (#61). What was missing was an owner for the run.
/// This is why nothing here stores candidates itself: two places holding them
/// would be two places that can disagree about which set Dan is looking at
/// (L53).
@MainActor
@Observable
final class CollageLayoutLoader {

    /// One render per day of one event. Two days are two different collages
    /// and cannot overwrite each other.
    private struct Key: Hashable {
        let eventID: Event.ID
        let day: DayName
    }

    struct Run {
        var startedAt: Date
        var elapsedSeconds: Int
    }

    private let tracker = JobTracker<Key, Run>(elapsed: \.elapsedSeconds)
    private var failures: [Key: String] = [:]

    // MARK: - Reads

    func isRunning(event: Event, day: DayName) -> Bool {
        tracker.isActive(Key(eventID: event.id, day: day))
    }

    func startedAt(event: Event, day: DayName) -> Date? {
        tracker.job(for: Key(eventID: event.id, day: day))?.startedAt
    }

    func failure(event: Event, day: DayName) -> String? {
        failures[Key(eventID: event.id, day: day)]
    }

    /// The options for this day, or nil when there are none to show yet.
    ///
    /// Read straight from the cache rather than from a copy here, so the set on
    /// screen is the set that will be reproduced when Dan reopens.
    func candidates(event: Event, day: DayName) -> [CollageCandidate]? {
        CollageCandidateCache.shared.cached(
            day: day, fingerprint: Self.fingerprint(event: event, day: day))
    }

    /// How long a render may take before it is called stalled.
    ///
    /// Outside the subprocess's own timeout rather than equal to it, and
    /// derived from it so the two cannot drift (L41).
    static let deadline: TimeInterval = PythonBridge.processTimeout + 180

    #if POSTROLL_TESTS
    var deadlineForTesting: TimeInterval = CollageLayoutLoader.deadline
    private var activeDeadline: TimeInterval { deadlineForTesting }
    #else
    private var activeDeadline: TimeInterval { Self.deadline }
    #endif

    #if POSTROLL_TESTS
    /// Test seam: the real one renders every candidate collage (L2).
    var render: @Sendable (Event, DayName) async throws -> [CollageCandidate] = {
        try await PythonBridge.shared.renderCollageCandidates(event: $0, day: $1)
    }
    #else
    let render: @Sendable (Event, DayName) async throws -> [CollageCandidate] = {
        try await PythonBridge.shared.renderCollageCandidates(event: $0, day: $1)
    }
    #endif

    // MARK: - Starting

    /// Render this day's layout options, or do nothing if they are already
    /// rendered or a render is going.
    func start(event: Event, day: DayName) {
        let key = Key(eventID: event.id, day: day)
        guard !tracker.isActive(key) else { return }
        let fingerprint = Self.fingerprint(event: event, day: day)
        // Reopening must show the SAME options, not a fresh set (#61).
        guard CollageCandidateCache.shared
            .cached(day: day, fingerprint: fingerprint) == nil else { return }

        failures[key] = nil
        tracker.begin(Run(startedAt: Date(), elapsedSeconds: 0), for: key)

        let work = render
        let deadline = activeDeadline
        Task { @MainActor [weak self] in
            do {
                let rendered = try await DeadlinedWork.run(within: deadline) {
                    try await work(event, day)
                }
                guard !Task.isCancelled else { return }
                if rendered.isEmpty {
                    // Not an empty grid. A day with no photos assigned renders
                    // nothing, and a blank sheet says neither what happened nor
                    // what to do (L10).
                    self?.finish(key, failure:
                        "Couldn't render layout options. Make sure this day has "
                        + "photos assigned.")
                } else {
                    CollageCandidateCache.shared.store(
                        day: day, fingerprint: fingerprint, candidates: rendered)
                    self?.finish(key, failure: nil)
                }
            } catch {
                self?.finish(key, failure: Self.failureMessage(error))
            }
        }
    }

    private func finish(_ key: Key, failure: String?) {
        failures[key] = failure
        tracker.remove(key)
    }

    /// Identity of the layout inputs: the day, its photos in order, and their
    /// crop offsets. When this is unchanged the cached candidates still apply.
    ///
    /// Here rather than on the sheet, because the run and the cache lookup have
    /// to agree about it and the sheet is no longer the only thing that asks.
    static func fingerprint(event: Event, day: DayName) -> String {
        guard let posting = event.days[day.rawValue] else { return day.rawValue }
        let count = event.effectivePostingPreset.format(for: day)?.count
            ?? posting.photoPaths.count
        let parts = posting.photoPaths.prefix(count).map { url -> String in
            let offset = posting.collageCropOffsets[url.absoluteString] ?? CropOffset()
            return "\(url.path)|\(offset.x),\(offset.y),\(offset.scale)"
        }
        return ([day.rawValue] + parts).joined(separator: "~")
    }

    /// The stall gets its own sentence: "it failed" and "it never came back"
    /// are different problems with different next steps (L11).
    private static func failureMessage(_ error: Error) -> String {
        if let stalled = error as? DeadlinedWork.Stalled {
            return "The layout render did not come back within "
                 + "\(Int(stalled.seconds / 60)) minutes. Try again, and check "
                 + "the log if it happens twice."
        }
        return error.localizedDescription
    }
}
