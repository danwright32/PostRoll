import Foundation

/// Running something with a deadline, in one place (#718).
///
/// A wait with no deadline cannot fail, it can only hang, and a hang is worse
/// than a failure because it is indistinguishable from slowness and holds
/// whatever it acquired (L110). Every long call in this app therefore runs
/// against a clock, so that one which never comes back becomes an error Dan can
/// act on rather than an indicator that sits there forever.
///
/// This was written twice, byte for byte the same, on `ProgramNotesManager` and
/// `PerformerLookupManager`, already sharing one `Stalled` error between them,
/// and the two Insights runs were about to make it three. One implementation
/// rather than a family of them: a deadline that is subtly different in one
/// copy is a defect nobody can see by reading either file.
enum DeadlinedWork {

    /// The work did not come back in time.
    ///
    /// Its own type rather than a generic failure, because "it failed" and "it
    /// never came back" are different problems with different next steps, and a
    /// message may only claim what its check actually measured (L11).
    struct Stalled: Error {
        let seconds: TimeInterval
    }

    /// Run `work`, or throw `Stalled` if it has not finished within `seconds`.
    ///
    /// The work's own error is passed through untouched: reporting a run that
    /// genuinely failed as a stall would send Dan off to wait out something
    /// that had already stopped.
    static func run<T: Sendable>(
        within seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Stalled(seconds: seconds)
            }
            // Whichever arm loses is cancelled, so a finished run does not keep
            // a task asleep for the rest of its deadline.
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw Stalled(seconds: seconds)
            }
            return first
        }
    }
}
