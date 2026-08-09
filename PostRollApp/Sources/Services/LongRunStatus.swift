import Foundation

/// What a long Python run is currently doing, as written by
/// `postroll/ai/progress.py` (#95, #96).
///
/// Read from a small file that holds where the run IS, never a log: the shared
/// log is truncated by whichever run starts next, and reading an unscoped tail
/// of it is how a UUID containing "413" once turned a 401 into "photos too
/// large" (#90).
struct GenerationStep: Codable, Hashable {
    var label: String = ""
    var index: Int? = nil
    var total: Int? = nil
    var done: Bool = false
    /// Unix time the step was written. This is the heartbeat: a label on its
    /// own freezes just as silently as a spinner, sitting there reading "Blog
    /// pass 2" whether the pass is running or the process died during it.
    var updatedAt: Double = 0

    enum CodingKeys: String, CodingKey {
        case label, index, total, done
        case updatedAt = "updated_at"
    }

    init(label: String = "", index: Int? = nil, total: Int? = nil,
         done: Bool = false, updatedAt: Double = 0) {
        self.label = label
        self.index = index
        self.total = total
        self.done = done
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label     = try c.decodeIfPresent(String.self, forKey: .label)     ?? ""
        index     = try c.decodeIfPresent(Int.self,    forKey: .index)
        total     = try c.decodeIfPresent(Int.self,    forKey: .total)
        done      = try c.decodeIfPresent(Bool.self,   forKey: .done)      ?? false
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }

    /// "Writing the Sunday caption (2 of 7)", or just the label when the run
    /// does not know how many steps there are.
    var display: String {
        guard let index, let total, total > 0 else { return label }
        return "\(label) (\(index) of \(total))"
    }
}

/// The three states a time-taking action must be able to show apart: it
/// started, it is still alive, and it has stalled or failed.
///
/// A spinner that looks identical whether the work is progressing, hung, or
/// dead is a defect, so this is deliberately not a bool.
enum LongRunStatus: Equatable {
    case idle
    /// Running normally. `step` is nil before the run has reported anything.
    case working(elapsedSeconds: Int, step: GenerationStep?)
    /// Alive as far as anyone knows, but nothing new has been reported for
    /// longer than this kind of work should ever take between steps.
    case stalled(elapsedSeconds: Int, step: GenerationStep?)
    case failed(String)
    case finished
}

enum LongRunState {
    /// How long a run may go without reporting a new step before it is shown
    /// as stalled rather than working.
    ///
    /// Measured against the work, not chosen for comfort: a single blog pass is
    /// one Claude call with a 600 second timeout, and captions for one day run
    /// to a few minutes. A threshold under that would flag every ordinary run
    /// and train Dan to ignore it, which is the failure #36 describes.
    static let defaultSilenceThreshold: TimeInterval = 660

    /// What to show, from the run's start, the last step it reported, and now.
    ///
    /// Staleness is measured from the STEP's own timestamp rather than from the
    /// run's start. A run that has been going forty minutes but reported a step
    /// four seconds ago is healthy, and one that started four minutes ago and
    /// has said nothing since second one is not: judging by total elapsed time
    /// gets both of those backwards.
    static func status(
        startedAt: Date?,
        step: GenerationStep?,
        now: Date,
        failedMessage: String? = nil,
        silenceThreshold: TimeInterval = defaultSilenceThreshold
    ) -> LongRunStatus {
        // A failure always wins: a run can fail after appearing stalled, and
        // the reason is more useful than the silence.
        if let failedMessage { return .failed(failedMessage) }
        guard let startedAt else { return .idle }
        if step?.done == true { return .finished }

        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))

        // Before the first step lands there is nothing to be stale, so fall
        // back to the run's own start for the silence measurement.
        let lastHeard = step.map { Date(timeIntervalSince1970: $0.updatedAt) } ?? startedAt
        let silence = now.timeIntervalSince(lastHeard)

        return silence >= silenceThreshold
            ? .stalled(elapsedSeconds: elapsed, step: step)
            : .working(elapsedSeconds: elapsed, step: step)
    }

    /// The current step for a run, or nil when there isn't a readable one.
    ///
    /// nil covers "not written yet" and "caught mid-write" alike. Both mean
    /// there is nothing to show, and neither is worth surfacing as an error.
    static func readStep(at url: URL) -> GenerationStep? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GenerationStep.self, from: data)
    }
}
