import Foundation

/// State a long-running background pipeline (Friday's clip-reel cut, cover
/// image regeneration, ...) can be in, extracted so it's unit-testable
/// without SwiftUI's Timer/TimelineView. Originally Friday-only
/// (FridayPipelineProgress); generalized when the cover image feature (#141)
/// needed the same elapsed-timer pattern rather than forking a second copy.
enum PipelineProgress: Equatable {
    case idle
    case running(elapsedSeconds: Int)
    /// Still running, but past the point this pipeline should ever
    /// reasonably take. Distinct from `running` so the UI can show an
    /// actionable "taking longer than usual" state instead of a spinner
    /// that looks identical whether it's progressing, hung, or dead.
    case stalled(elapsedSeconds: Int)
    case failed(String)
}

enum PipelineProgressState {
    /// Default stall threshold: generous enough to cover Stage 1 scoring +
    /// a Claude call + an ffmpeg render on a normal week's clip set without
    /// false-flagging, while still catching a genuinely hung run instead of
    /// spinning forever.
    static let defaultStallThreshold: TimeInterval = 180

    /// Decides what to show given the run's start time, the current time,
    /// and whether it already terminally failed. A failed message always
    /// wins (a run can fail after appearing stalled).
    static func state(
        startedAt: Date?, now: Date, failedMessage: String?,
        stallThreshold: TimeInterval = defaultStallThreshold
    ) -> PipelineProgress {
        if let failedMessage { return .failed(failedMessage) }
        guard let startedAt else { return .idle }
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        return TimeInterval(elapsed) >= stallThreshold
            ? .stalled(elapsedSeconds: elapsed)
            : .running(elapsedSeconds: elapsed)
    }
}
