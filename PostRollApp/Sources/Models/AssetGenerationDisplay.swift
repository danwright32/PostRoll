import Foundation

/// What the generation screen should show. Kept as a pure value type (no view,
/// no GenerationManager dependency) so the precedence rule can be unit-tested.
///
/// The rule is the heart of the "switching events loses progress" fix: a live
/// run owned by GenerationManager (running or failed) always wins over the
/// view-local configuring/done toggle. Because the run lives app-scoped rather
/// than in the view's `@State`, tearing down and remounting AssetGenerationView
/// (which happens on every sidebar event switch via `.id(event.id)`) re-derives
/// the same display from the surviving run instead of resetting it.
enum AssetGenerationDisplay: Equatable {
    case configuring
    case running
    case failed(String)
    case done

    /// Status of an in-flight or just-finished run, as tracked by
    /// GenerationManager. A successful run is removed from the manager, so
    /// success is represented by the absence of a status plus a saved weekResult.
    enum RunStatus: Equatable {
        case running
        case failed(String)
    }

    /// Derive the screen state. An active run takes precedence; otherwise the
    /// local `forceConfigure` toggle (set by "Regenerate all") wins, falling
    /// back to done when results already exist.
    static func resolve(runStatus: RunStatus?,
                        forceConfigure: Bool,
                        hasWeekResult: Bool) -> AssetGenerationDisplay {
        if let status = runStatus {
            switch status {
            case .running:          return .running
            case .failed(let msg):  return .failed(msg)
            }
        }
        if forceConfigure { return .configuring }
        return hasWeekResult ? .done : .configuring
    }
}

/// Which screen a run that did not finish shows (#257).
///
/// A week stopped by a usage cap is not a failed week: the days that finished
/// are real, and there are two ways forward rather than only "try again". An
/// error state and a halt are different screens, so the choice between them is
/// made here rather than inside the view, where nothing could test it.
enum FailureScreen: Equatable {
    case halted(HaltedWeek)
    case error(String)

    static func resolve(message: String, week: WeekGenerationResult?) -> FailureScreen {
        if let week, let halted = HaltedWeek.from(week) { return .halted(halted) }
        return .error(message)
    }
}
