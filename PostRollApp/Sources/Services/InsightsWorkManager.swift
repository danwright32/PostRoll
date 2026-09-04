import Foundation
import Observation

/// Owns the two Insights runs, so they outlive the screen that started them
/// (#718).
///
/// The CSV import and the report generation both kept their in flight flag,
/// their start time and their error message in `InsightsOverviewView`'s own
/// `@State`. Clicking Events in the sidebar destroys that view and takes all
/// three with it, so a run still going, one that had finished and one that had
/// failed all looked identical: nothing at all. Coming back showed the idle
/// button, so a second paid analysis over the whole history was one click away.
///
/// The rule and the shape to copy are on `JobTracker`. What is different here
/// is only the key: neither run is about an event, because there is one
/// analytics history and one report, so this keys on its own small enum rather
/// than growing a second mechanism beside the per-event managers.
///
/// Results already land in `AnalyticsStore`, which is app scoped and outlives
/// everything, so unlike #693 nothing was being written through a binding into
/// a destroyed view. What was lost was the whole report of what happened: the
/// progress, the elapsed clock, the reason a run failed, and whether the write
/// landed. That is what this holds.
@MainActor
@Observable
final class InsightsWorkManager {

    /// The two runs. Neither is about an event.
    enum Job: Hashable, CaseIterable {
        case importCSV
        case generateReport
    }

    struct Run {
        var startedAt: Date
        var elapsedSeconds: Int
        /// The handle on the work, so it can be stopped (#1050).
        ///
        /// It was started with a bare `Task { }` and the handle thrown away, so
        /// nothing could ever have stopped this: the screen put up a spinner
        /// and offered no way back. `JobTracker` requires this now, so a new
        /// owner cannot be written that way (L96).
        fileprivate var task: Task<Void, Never>?
    }

    /// What a finished run left to say, kept after the run so that leaving
    /// Insights and coming back does not destroy it.
    ///
    /// Two fields rather than one string because they render differently and
    /// mean different things. `success` draws a green tick and may be set ONLY
    /// once the write has actually landed; a tick over a write that did not
    /// happen is the defect #439 fixed. `note` draws a warning triangle and
    /// covers all three of the things that are not a success: import warnings
    /// on a run that did land, a write the store refused, and a failure.
    struct Outcome: Equatable {
        var success: String?
        var note: String?
    }

    private let tracker = JobTracker<Job, Run>(elapsed: \.elapsedSeconds, task: \.task)

    /// The terminal state of each job, in ONE place.
    ///
    /// Deliberately not also flagged on the tracker: two fields for one
    /// outcome are two fields that can disagree, and then nothing can say which
    /// is right (L53). The tracker answers "is it going", this answers "what
    /// happened", and a job is removed from the tracker the moment it ends.
    private var outcomes: [Job: Outcome] = [:]

    // MARK: - Reads

    func isRunning(_ job: Job) -> Bool { tracker.isActive(job) }

    /// Stop this run (#1050).
    ///
    /// Through the tracker, which is the one place stopping lives: it cancels
    /// the task, remembers the request so a screen can say it is winding down,
    /// and refuses a second press. Returns whether the request was taken, so a
    /// caller can tell a stop from a press that arrived after the work was
    /// already over (L197).
    ///
    /// This owner had no way to stop at all. It put up a spinner, and the only
    /// ways out of a run started by mistake were to wait or to quit the app.
    @discardableResult
    func stop(_ job: Job) -> Bool { tracker.requestStop(job) }

    /// A stop was asked for and the work has not stopped yet.
    func isStopping(_ job: Job) -> Bool { tracker.isStopping(job) }
    func startedAt(_ job: Job) -> Date? { tracker.job(for: job)?.startedAt }
    func outcome(for job: Job) -> Outcome? { outcomes[job] }

    /// Whether either run is going, for the decisions that are about the app.
    ///
    /// Updating PostRoll is the one that matters: it quits to install, and a
    /// paid model pass over the whole history is exactly the thing that must
    /// not be thrown away without saying so (#686).
    var hasWorkInFlight: Bool { tracker.hasWorkInFlight }

    // MARK: - Deadlines

    /// How long either run may take before it is called stalled.
    ///
    /// Deliberately LONGER than the subprocess's own timeout rather than equal
    /// to it, and derived from that value rather than spelled again here, so
    /// the two cannot drift apart (L41). Equal deadlines would race: whichever
    /// fired first would decide the message, and the subprocess's own timeout
    /// says something specific about what it was doing while this one can only
    /// say that nothing came back. The generic answer is the backstop, for a
    /// hang that is not the subprocess at all.
    static let deadline: TimeInterval = PythonBridge.processTimeout + 180

    #if POSTROLL_TESTS
    /// Test seam: a test of the stall cannot wait half an hour, and one that
    /// did would be a test nobody runs. Settable only in the test bundle.
    var reportDeadlineForTesting: TimeInterval = InsightsWorkManager.deadline
    private var activeDeadline: TimeInterval { reportDeadlineForTesting }
    #else
    private var activeDeadline: TimeInterval { Self.deadline }
    #endif

    // MARK: - What the work actually is

    #if POSTROLL_TESTS
    /// Test seams. The real ones shell out to Python, and the analysis is a
    /// paid model call over the whole post history: a suite able to reach that
    /// is a suite that spends money and needs a network (L2).
    var runImport: @Sendable ([URL]) async throws -> MetaImportResult = {
        try await PythonBridge.shared.importMetaCSV(paths: $0)
    }
    var runAnalysis: @Sendable ([IGPost], [String: OrgFollowerBand], [String])
        async throws -> InsightReport = {
        try await PythonBridge.shared.runAnalytics(
            posts: $0, orgBands: $1, globalHashtags: $2)
    }
    #else
    let runImport: @Sendable ([URL]) async throws -> MetaImportResult = {
        try await PythonBridge.shared.importMetaCSV(paths: $0)
    }
    let runAnalysis: @Sendable ([IGPost], [String: OrgFollowerBand], [String])
        async throws -> InsightReport = {
        try await PythonBridge.shared.runAnalytics(
            posts: $0, orgBands: $1, globalHashtags: $2)
    }
    #endif

    // MARK: - Starting

    /// Read `urls` and merge what they hold into `store`.
    func startImport(of urls: [URL], into store: AnalyticsStore) {
        guard !urls.isEmpty else { return }
        // Assume it runs twice. Coming back to Insights mid run showed the
        // idle button, so stacking two imports was one click away.
        guard begin(.importCSV) else { return }

        let read = runImport
        let deadline = activeDeadline
        let held = Task { @MainActor [weak self] in
            do {
                let result = try await DeadlinedWork.run(within: deadline) {
                    try await read(urls)
                }
                self?.finish(.importCSV, with: Self.apply(result, to: store))
            } catch is CancellationError {
                // Dan pressed stop (#1050). Not a failure: reporting one would
                // put a red banner over something he asked for, and the
                // notification would say the work died (L11).
                self?.tracker.remove(.importCSV)
            } catch {
                self?.finish(.importCSV, with: Outcome(
                    success: nil, note: Self.message(for: error, doing: "import")))
            }
        }
        // Held so the work can be stopped (#1050). It was a bare
        // `Task { }` and the handle went straight in the bin, so this
        // put up a spinner that nothing could ever have ended.
        tracker.update(.importCSV) { $0.task = held }
    }

    /// Analyse everything in `store` and write the report back to it.
    func startReport(store: AnalyticsStore, globalHashtags: [String]) {
        guard begin(.generateReport) else { return }

        // Read off the store at the moment the run starts, the same way the
        // per-event managers read the stored event: what is analysed and what
        // the report is about are then the same set.
        let posts = store.posts
        let bands = store.orgFollowerBands
        let analyse = runAnalysis
        let deadline = activeDeadline
        let held = Task { @MainActor [weak self] in
            do {
                let report = try await DeadlinedWork.run(within: deadline) {
                    try await analyse(posts, bands, globalHashtags)
                }
                // Same rule as the import (#439): a report the store was
                // refused permission to write is in this window only, and the
                // screen has to say so rather than showing it as recorded.
                let unsaved = InsightsDisplay.unsavedReportNotice(
                    save: store.addReport(report))
                self?.finish(.generateReport,
                             with: Outcome(success: nil, note: unsaved))
            } catch is CancellationError {
                // Dan pressed stop (#1050). Not a failure: reporting one would
                // put a red banner over something he asked for, and the
                // notification would say the work died (L11).
                self?.tracker.remove(.generateReport)
            } catch {
                self?.finish(.generateReport, with: Outcome(
                    success: nil, note: Self.message(for: error, doing: "analysis")))
            }
        }
        // Held so the work can be stopped (#1050). It was a bare
        // `Task { }` and the handle went straight in the bin, so this
        // put up a spinner that nothing could ever have ended.
        tracker.update(.generateReport) { $0.task = held }
    }

    // MARK: - Transitions

    /// Mark `job` started, or say no because it already is.
    private func begin(_ job: Job) -> Bool {
        guard !tracker.isActive(job) else { return false }
        // The previous run's notice goes now rather than when the next one
        // lands: a success from ten minutes ago sitting beside a run that is
        // going reads as this run having already worked.
        outcomes[job] = nil
        tracker.begin(Run(startedAt: Date(), elapsedSeconds: 0), for: job)
        return true
    }

    private func finish(_ job: Job, with outcome: Outcome) {
        outcomes[job] = outcome
        tracker.remove(job)
    }

    /// Merge an import into the store and say what may be claimed about it.
    ///
    /// Nonisolated-free and static so the decision can be read in one piece:
    /// what the screen is allowed to say about an import lives in
    /// `InsightsDisplay`, and this only feeds it the counts.
    private static func apply(_ result: MetaImportResult,
                              to store: AnalyticsStore) -> Outcome {
        let before = store.posts.count
        let save = store.mergePosts(result.posts)
        let added = max(0, store.posts.count - before)
        let updated = max(0, result.posts.count - added)

        switch InsightsDisplay.importNotice(imported: result.posts.count,
                                            added: added,
                                            updated: updated,
                                            warnings: result.warnings.count,
                                            save: save) {
        case .saved(let text):
            // Warnings sit beside the success rather than replacing it: rows
            // the import skipped are worth reading, and the posts that did
            // arrive really did arrive.
            return Outcome(success: text,
                           note: result.warnings.isEmpty
                               ? nil
                               : result.warnings.prefix(3).joined(separator: "\n"))
        case .notSaved(let text):
            // Deliberately NOT `success`: that row renders a green tick, and a
            // tick over a write that did not happen is the whole defect.
            return Outcome(success: nil, note: text)
        }
    }

    /// What Dan reads when a run did not work.
    ///
    /// A stall gets its own sentence. "It failed" and "it never came back" are
    /// different problems with different next steps, and a message may only
    /// claim what its check actually measured (L11).
    private static func message(for error: Error, doing what: String) -> String {
        if let stalled = error as? DeadlinedWork.Stalled {
            return "The \(what) did not come back within "
                 + "\(Int(stalled.seconds / 60)) minutes. Nothing was changed. "
                 + "Try again, and check the log if it happens twice."
        }
        return error.localizedDescription
    }
}

/// Asked whenever PostRoll is about to quit or install an update (#862).
///
/// The phrase is a clause rather than a name, because it is dropped into a
/// sentence that already says what is happening to it.
extension InsightsWorkManager: BackgroundWork {
    var workPhrase: String { "an Insights import is still running" }
}
