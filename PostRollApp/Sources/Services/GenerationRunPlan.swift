import Foundation

/// The phase timeline and the one line subtitle the running generation screen
/// shows.
///
/// Lifted out of `AssetGenerationView` (#396) for two reasons. The screen could
/// not be rendered without standing up the whole app, so the retry timeline had
/// never been looked at; and the arithmetic took its inputs from
/// `TimingStore.shared`, which made it untestable and meant a retry's estimate
/// was only ever checked by running one.
///
/// Timings are passed in rather than read from the singleton here, so a test and
/// the render harness can drive this with the same numbers the app falls back to
/// when TimingStore has no history yet.
enum GenerationRunPlan {

    /// The app's own fallbacks, used when TimingStore has nothing recorded.
    /// Named rather than repeated at each call site, so the harness measures the
    /// same figures a first run shows.
    static let fallbackEstimate: Double = 360
    static let captionsShareOfRun = 0.50
    static let blogShareOfRun = 0.25

    struct Phase: Equatable {
        let name: String
        /// Seconds into the run when this phase is expected to begin.
        let startsAt: Int
    }

    /// A retry's phase timeline and its total estimate, or nil for a full run
    /// (which uses TimingStore's rolling window instead).
    ///
    /// `dayCount` is how many days the WEEK has, not how many are being retried:
    /// the per day cost is the caption mean spread across the whole week, which
    /// is the only figure history can give.
    static func retryPlan(retryDays: Set<String>?,
                          dayCount: Int,
                          fullEstimate: Double? = nil,
                          captionsMean: Double? = nil,
                          blogMean: Double? = nil) -> (phases: [Phase], estimate: Double)? {
        guard let retryDays else { return nil }

        let full = fullEstimate ?? fallbackEstimate
        let captions = captionsMean ?? (full * captionsShareOfRun)
        let blog = blogMean ?? (full * blogShareOfRun)
        let totalDayCount = max(1, dayCount)

        let retryDayKeys = retryDays.subtracting(["blog"])
        let hasBlog = retryDays.contains("blog")

        let perDay = captions / Double(totalDayCount)
        let retryCaptionsTotal = perDay * Double(max(1, retryDayKeys.count))

        var phases: [Phase] = []
        var cursor = 0

        if !retryDayKeys.isEmpty {
            let names = DayName.allCases
                .filter { retryDayKeys.contains($0.rawValue) }
                .map(\.displayName)
            phases.append(Phase(name: "Re-reading photos", startsAt: cursor))
            cursor += 5
            phases.append(Phase(name: "Writing \(joined(names)) captions", startsAt: cursor))
            cursor += Int(retryCaptionsTotal.rounded())
        }

        if hasBlog {
            phases.append(Phase(name: "Drafting blog post", startsAt: cursor))
            cursor += Int(blog.rounded())
        }

        return (phases, Double(cursor))
    }

    /// Whether this is a full run or a partial retry, said in one line, so the
    /// timeline underneath is not the only clue.
    static func subtitle(retryDays: Set<String>?, dayCount: Int) -> String {
        guard let retryDays else {
            return "Generating all \(dayCount) \(dayCount == 1 ? "day" : "days")"
        }
        let dayKeys = retryDays.subtracting(["blog"])
        let names = DayName.allCases
            .filter { dayKeys.contains($0.rawValue) }
            .map(\.displayName)
        let hasBlog = retryDays.contains("blog")

        if names.isEmpty && hasBlog { return "Retrying blog post" }
        if hasBlog { return "Retrying \(joined(names)) + blog" }
        return "Retrying \(joined(names))"
    }

    /// Which phase the run is in, given how long it has been going.
    ///
    /// Its own function because the screen's mark of progress and the phase rows
    /// have to agree about it, and the loop that decides it was previously
    /// inside the view where nothing could check it.
    static func activePhaseIndex(phases: [Phase], elapsedSeconds: Int) -> Int {
        var active = 0
        for (i, phase) in phases.enumerated() where elapsedSeconds >= phase.startsAt {
            active = i
        }
        return active
    }

    private static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) + \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(head) + \(names.last!)"
        }
    }
}
