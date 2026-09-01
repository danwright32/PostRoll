import Foundation
import Observation

/// Owns the runs started from the caption review screen, so none of them dies
/// with it (#718).
///
/// Every one of them kept its in flight flag, its start time and its error in
/// `CaptionReviewView`'s own state, or in one of its rows'. `EventDetailView`
/// is `.id(event.id)` tagged, so an event switch remounts the whole screen and
/// destroys all three, and the screen that comes back shows the idle button.
///
/// The whole-week regeneration is the worst of them, and not only because it is
/// three to six minutes of paid Claude output. The two ways it can end EARLY, a
/// usage cap and a mid-run failure, both KEEP the days they finished and hand
/// back a banner saying which survived and where the two ways forward are
/// (#262). That banner lived in the view. Losing it does not merely leave Dan
/// uninformed: the days are on disk, the screen says nothing, and he re-runs
/// and pays again for work he already has.
///
/// The shape is `ProgramNotesManager`'s. What is different is that this screen
/// runs several DIFFERENT things on one event, so the key carries which, and a
/// caption revision going does not make the week regeneration read as busy.
@MainActor
@Observable
final class CaptionWorkManager {

    /// Which run this is. Part of the key rather than a manager each, because
    /// they are all runs on one week and must not be able to disagree about
    /// whether that week is busy.
    enum Job: Hashable {
        /// The whole week, three to six paid minutes, which deliberately
        /// replaces everything.
        case regenerateWeek
        /// One day's caption, rewritten to Dan's feedback. Keyed by the day, so
        /// revising Sunday does not make Monday's button read as busy.
        case reviseCaption(DayName)
        case reviseBlog
        case swapBlogPhotos
        /// Re-running the alt text repairs the pass could not finish (#1160).
        /// Its own job rather than a second meaning for `reviseBlog`: they can
        /// fail for different reasons and each needs its own message (L53).
        case retryBlogRepairs
        /// The paid pass that reads Dan's hand edits before the week is
        /// exported (#526).
        case learnFromEdits
    }

    private struct Key: Hashable {
        let eventID: Event.ID
        let job: Job
    }

    struct Run {
        var startedAt: Date
        var elapsedSeconds: Int
    }

    /// What a finished run left to say, kept after the run so that leaving the
    /// screen and coming back does not destroy it.
    struct Outcome: Equatable {
        /// Why it ended badly, OR the banner explaining what a run that stopped
        /// early managed to keep. The two are one field because they are one
        /// thing to the reader: something to act on before running again.
        var failure: String?
        /// What the learn-from-edits pass proposed, when it had something.
        ///
        /// Distinct from `failure` being nil, which is what #526 was about: a
        /// pass that failed and a pass with nothing to add both came back as
        /// nil and both advanced the week silently.
        var suggestion: String?
        /// A brand voice note that would not write.
        ///
        /// Its own field, never folded into `failure`: the revision landing and
        /// the note landing are different facts, and reporting the note's
        /// failure as the revision's would tell Dan his edit had not happened
        /// when it had (#462, L53).
        var noteFailure: String?
        /// The caption as it stood before a revision, so the undo for a change
        /// that now survives the screen survives it too (L97).
        var previousCaption: DayCaption?
        /// The same, for the blog: a revision and a photo swap both replace it.
        var previousBlog: BlogOutput?
        /// What a RETRY did, in a sentence (#1160).
        ///
        /// Its own field rather than `failure`, because a retry that rewrote
        /// nothing is not a failure: the app tried and its own checks refused
        /// the result, and reporting that as an error invites pressing the
        /// button again forever (L11, L109). Repairs are silent, so without
        /// this a retry that fixed everything and one that fixed nothing both
        /// just update the panel and say nothing (L98).
        var retryNote: String?
    }

    private let tracker = JobTracker<Key, Run>(elapsed: \.elapsedSeconds)
    private var outcomes: [Key: Outcome] = [:]

    // MARK: - Reads

    func isRunning(_ id: Event.ID, _ job: Job) -> Bool {
        tracker.isActive(Key(eventID: id, job: job))
    }

    func startedAt(_ id: Event.ID, _ job: Job) -> Date? {
        tracker.job(for: Key(eventID: id, job: job))?.startedAt
    }

    func outcome(for id: Event.ID, _ job: Job) -> Outcome? {
        outcomes[Key(eventID: id, job: job)]
    }

    /// Forget a finished run's outcome, so a retry starts clean.
    func clearOutcome(for id: Event.ID, _ job: Job) {
        outcomes[Key(eventID: id, job: job)] = nil
    }

    /// Whether anything here is going, for the decisions that are about the
    /// app. Updating quits to install (#686), and three to six paid minutes
    /// half way through is what must not be thrown away silently.
    var hasWorkInFlight: Bool { tracker.hasWorkInFlight }

    /// How long a run may take before it is called stalled.
    ///
    /// Outside the subprocess's own timeout rather than equal to it, and
    /// derived from it so the two cannot drift (L41). A whole week is the
    /// longest thing this app waits on, and the generator has its own watchdog;
    /// this is the backstop for a hang that is not the subprocess.
    static let deadline: TimeInterval = PythonBridge.processTimeout + 180

    #if POSTROLL_TESTS
    var deadlineForTesting: TimeInterval = CaptionWorkManager.deadline
    private var activeDeadline: TimeInterval { deadlineForTesting }
    #else
    private var activeDeadline: TimeInterval { Self.deadline }
    #endif

    // Test seams. Every one of these is a paid model call, and the note write
    // reaches the real brand voice file, so a suite able to run them is a suite
    // that spends money and edits Dan's own writing (L2).
    #if POSTROLL_TESTS
    var generateWeek: @Sendable (Event) async throws -> WeekGenerationResult = {
        try await PythonBridge.shared.runWeekGeneration(event: $0)
    }
    var reviseCaption: @Sendable (Event, DayName, String, DayCaption) async throws
        -> DayCaption = {
        try await PythonBridge.shared.runCaptionRevision(
            event: $0, day: $1, feedback: $2, currentCaption: $3)
    }
    var reviseBlog: @Sendable (Event, String, BlogOutput) async throws -> BlogOutput = {
        try await PythonBridge.shared.runBlogRevision(
            event: $0, feedback: $1, currentBlog: $2)
    }
    var swapBlogPhotos: @Sendable (String, [URL], Event, BlogOutput) async throws
        -> BlogOutput = {
        try await PythonBridge.shared.runBlogPhotoSwap(
            currentBody: $0, photoPaths: $1, event: $2, currentBlog: $3)
    }
    var retryBlogRepairs: @Sendable (String, [String], [URL], Event) async throws
        -> BlogRepairRetryResult = {
        try await PythonBridge.shared.runBlogRepairRetry(
            currentBody: $0, markers: $1, photoPaths: $2, event: $3)
    }
    var learnFromEdits: @Sendable (WeekGenerationResult) async throws -> String? = {
        try await PythonBridge.shared.runLearnFromEdits(result: $0)
    }
    var appendBrandVoiceNote: @Sendable (String) async throws -> Void = {
        try PythonBridge.shared.appendBrandVoiceNote($0)
    }
    #else
    let generateWeek: @Sendable (Event) async throws -> WeekGenerationResult = {
        try await PythonBridge.shared.runWeekGeneration(event: $0)
    }
    let reviseCaption: @Sendable (Event, DayName, String, DayCaption) async throws
        -> DayCaption = {
        try await PythonBridge.shared.runCaptionRevision(
            event: $0, day: $1, feedback: $2, currentCaption: $3)
    }
    let reviseBlog: @Sendable (Event, String, BlogOutput) async throws -> BlogOutput = {
        try await PythonBridge.shared.runBlogRevision(
            event: $0, feedback: $1, currentBlog: $2)
    }
    let swapBlogPhotos: @Sendable (String, [URL], Event, BlogOutput) async throws
        -> BlogOutput = {
        try await PythonBridge.shared.runBlogPhotoSwap(
            currentBody: $0, photoPaths: $1, event: $2, currentBlog: $3)
    }
    let retryBlogRepairs: @Sendable (String, [String], [URL], Event) async throws
        -> BlogRepairRetryResult = {
        try await PythonBridge.shared.runBlogRepairRetry(
            currentBody: $0, markers: $1, photoPaths: $2, event: $3)
    }
    let learnFromEdits: @Sendable (WeekGenerationResult) async throws -> String? = {
        try await PythonBridge.shared.runLearnFromEdits(result: $0)
    }
    let appendBrandVoiceNote: @Sendable (String) async throws -> Void = {
        try PythonBridge.shared.appendBrandVoiceNote($0)
    }
    #endif

    // MARK: - Regenerating the whole week

    func startRegeneratingWeek(eventID: Event.ID, appState: AppState,
                               globalHashtags: [String]) {
        let key = Key(eventID: eventID, job: .regenerateWeek)
        // Assume it runs twice. Coming back to the screen mid run showed the
        // idle button, so two whole-week runs on one event were one click away,
        // and both write the same week.
        guard !tracker.isActive(key) else { return }
        guard let live = appState.events.first(where: { $0.id == eventID }) else { return }

        outcomes[key] = nil
        tracker.begin(Run(startedAt: Date(), elapsedSeconds: 0), for: key)

        let generate = generateWeek
        let deadline = activeDeadline
        Task { @MainActor [weak self] in
            do {
                let week = try await DeadlinedWork.run(within: deadline) {
                    try await generate(live)
                }
                guard !Task.isCancelled else { return }
                self?.applyWholeWeek(week, to: eventID, in: appState,
                                     globalHashtags: globalHashtags)
                self?.finish(key, with: Outcome())
                NotificationService.shared.notifyRegenerationComplete(
                    eventName: live.name, what: "Captions")
            } catch let halt as WeekGenerationHalted {
                // The run stopped at a usage cap. What it finished is real and
                // paid for, so it is saved over the existing week rather than
                // discarded with the error (#262). The banner says which days
                // survived: a halt shown as a bare red error reads as a crash,
                // and Dan re-runs work he already has.
                let banner = HaltedWeek.from(halt.week)?.reviewBanner ?? halt.reason
                self?.keepPartial(halt.week, to: eventID, in: appState)
                self?.finish(key, with: Outcome(failure: banner))
            } catch let partial as WeekGenerationFailedWithPartial {
                // The run died with days already generated, usually the
                // watchdog. Saved for the same reason as a halt: they exist and
                // are paid for.
                self?.keepPartial(partial.week, to: eventID, in: appState)
                self?.finish(key, with: Outcome(
                    failure: partial.localizedDescription))
            } catch {
                self?.finish(key, with: Outcome(
                    failure: Self.failureMessage(error)))
            }
        }
    }

    // MARK: - Writing back

    /// Replace the week and fold in the global tags.
    ///
    /// The live event, re-read rather than the copy the run started from: this
    /// arrives minutes later and something else may have written in between.
    private func applyWholeWeek(_ week: WeekGenerationResult, to eventID: Event.ID,
                                in appState: AppState, globalHashtags: [String]) {
        guard var live = appState.events.first(where: { $0.id == eventID }) else { return }
        var next = week
        GlobalTagMerge.apply(globalHashtags, to: &next, for: live)
        live.weekResult = next
        appState.updateEvent(live)
    }

    /// Save what a run produced before it stopped.
    ///
    /// Through `PartialWeekMerge`, so a day the run never reached keeps the
    /// caption an earlier run produced instead of being overwritten with
    /// nothing (#262).
    private func keepPartial(_ week: WeekGenerationResult, to eventID: Event.ID,
                             in appState: AppState) {
        guard var live = appState.events.first(where: { $0.id == eventID }) else { return }
        live.weekResult = PartialWeekMerge.applying(week, onto: live.weekResult)
        appState.updateEvent(live)
    }

    // MARK: - Revising one day, the blog, and the blog's photos

    /// Rewrite one day's caption to Dan's feedback.
    ///
    /// Writes ONE DAY into the stored week rather than replacing it. Dan is
    /// very often editing another day while this runs, and a whole-week write
    /// would take those edits with it. The whole-week regeneration is the one
    /// run that is entitled to replace everything, and it asks first.
    func startRevisingCaption(eventID: Event.ID, day: DayName, feedback: String,
                              saveToBrandVoice: Bool, appState: AppState) {
        let key = Key(eventID: eventID, job: .reviseCaption(day))
        guard !tracker.isActive(key) else { return }
        guard let live = appState.events.first(where: { $0.id == eventID }),
              let current = live.weekResult?[day] else { return }

        run(key, brandVoiceNote: saveToBrandVoice ? feedback : nil,
            appState: appState) { [reviseCaption] in
            try await reviseCaption(live, day, feedback, current)
        } write: { [weak self] revised, state in
            self?.writeWeek(to: eventID, in: state) { $0[day] = revised }
            return Outcome(previousCaption: current)
        }
    }

    func startRevisingBlog(eventID: Event.ID, feedback: String,
                           saveToBrandVoice: Bool, appState: AppState) {
        let key = Key(eventID: eventID, job: .reviseBlog)
        guard !tracker.isActive(key) else { return }
        guard let live = appState.events.first(where: { $0.id == eventID }),
              let current = live.weekResult?.blog else { return }

        run(key, brandVoiceNote: saveToBrandVoice ? feedback : nil,
            appState: appState) { [reviseBlog] in
            try await reviseBlog(live, feedback, current)
        } write: { [weak self] revised, state in
            // The pin comes from Python, which is the only half that knows
            // which text `check_blog` actually ran on: every blog path rewrites
            // the body after Claude answers (#974). This used to re-derive it
            // here as `revised.body`, which happened to agree and was a second
            // place for the answer to live (L41). `revised` carries both the
            // findings and their body already, so there is nothing to apply.
            let next = revised
            self?.writeWeek(to: eventID, in: state) { $0.blog = next }
            return Outcome(previousBlog: current)
        }
    }

    /// Rewrite the blog around a fresh set of photos.
    ///
    /// The paths live OUTSIDE `weekResult`, so both halves are written here. A
    /// swap that wrote only the body would leave the post describing photos the
    /// event does not have.
    func startSwappingBlogPhotos(eventID: Event.ID, urls: [URL], appState: AppState) {
        let key = Key(eventID: eventID, job: .swapBlogPhotos)
        guard !tracker.isActive(key) else { return }
        guard !urls.isEmpty else { return }
        guard let live = appState.events.first(where: { $0.id == eventID }),
              let current = live.weekResult?.blog else { return }

        run(key, brandVoiceNote: nil, appState: appState) { [swapBlogPhotos] in
            // `current` carries the stamps the incoming alt text was written
            // against (#1131). Without them the swap has no record to compare
            // each photograph against, every one reads as new, and it
            // re-uploads and re-describes six good alt texts to change one
            // picture. The failure is silent: the run succeeds, it just costs
            // what it always did.
            try await swapBlogPhotos(current.body, urls, live, current)
        } write: { [weak self] updated, state in
            var next = current
            next.body = updated.body
            next.photoCount = urls.count
            // Taken from the payload rather than from `updated.body`, so the
            // text the checks ran on is stated once, by the half that ran them
            // (#974). The swap rewrites every marker after Claude answers, so
            // the two are not interchangeable in principle even where they
            // agree in practice.
            next.applyFindings(updated.findings, checkedBody: updated.findingsBody)
            // The swap places a different set of photographs, so what the post
            // holds and what each one looked like are BOTH new (#1130). Kept
            // from `current` this would have described the old set forever.
            next.photoStamps = updated.photoStamps
            self?.writeWeek(to: eventID, in: state) { $0.blog = next }
            // Re-read after the week write so this lands on top of it rather
            // than on the copy taken before.
            guard var stored = state.events.first(where: { $0.id == eventID })
            else { return Outcome(previousBlog: current) }
            stored.blogPhotoPaths = urls
            state.updateEvent(stored)
            return Outcome(previousBlog: current)
        }
    }

    // MARK: - Retrying the repairs the pass could not finish (#1160)

    /// Re-run the alt text repair over `markers` only.
    ///
    /// A FRESH pass over just those, not a resumed one: the round cap is per
    /// pass and the pass is already re-entrant. Refused when it names nothing,
    /// because this control exists to redo a few markers and a bug that redid
    /// all of them would pay for the whole post again without being asked.
    func startRetryingBlogRepairs(eventID: Event.ID, markers: [String],
                                  appState: AppState) {
        let key = Key(eventID: eventID, job: .retryBlogRepairs)
        // Assume it runs twice (L33): two retries of one event write the same
        // blog, and the second would land on top of the first's result.
        guard !tracker.isActive(key) else { return }
        guard !markers.isEmpty else { return }
        guard let live = appState.events.first(where: { $0.id == eventID }),
              let current = live.weekResult?.blog else { return }
        let photos = live.blogPhotoPaths

        run(key, brandVoiceNote: nil, appState: appState) { [retryBlogRepairs] in
            try await retryBlogRepairs(current.body, markers, photos, live)
        } write: { [weak self] updated, state in
            var next = current
            next.body = updated.body
            // From the payload rather than from `updated.body`, so the text the
            // checks ran on is stated once, by the half that ran them (#974).
            next.applyFindings(updated.findings, checkedBody: updated.body)
            self?.writeWeek(to: eventID, in: state) { $0.blog = next }
            return Outcome(previousBlog: current, retryNote: updated.note)
        }
    }

    // MARK: - Learning from the edits (#526)

    /// Read Dan's hand edits and propose a line for his brand voice file.
    ///
    /// Deliberately not behind `try?`. A pass that FAILED used to return the
    /// same nil as one that succeeded with nothing to say, so a paid call that
    /// never ran looked exactly like a model with no note to add, and the week
    /// advanced either way. The three outcomes stay apart here and
    /// `LearnFromEditsOutcome` decides what the screen does with them.
    func startLearningFromEdits(eventID: Event.ID, appState: AppState) {
        let key = Key(eventID: eventID, job: .learnFromEdits)
        guard !tracker.isActive(key) else { return }
        guard let live = appState.events.first(where: { $0.id == eventID }),
              let week = live.weekResult else { return }

        outcomes[key] = nil
        tracker.begin(Run(startedAt: Date(), elapsedSeconds: 0), for: key)

        let learn = learnFromEdits
        let deadline = activeDeadline
        Task { @MainActor [weak self] in
            do {
                let suggestion = try await DeadlinedWork.run(within: deadline) {
                    try await learn(week)
                }
                let text = suggestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self?.finish(key, with: Outcome(
                    suggestion: text.isEmpty ? nil : suggestion))
            } catch {
                self?.finish(key, with: Outcome(
                    failure: LearnFromEditsOutcome.failureNotice(
                        Self.failureMessage(error))))
            }
        }
    }

    // MARK: - The one runner behind the revisions

    /// Start `work`, write what it produced, and record what happened.
    ///
    /// One implementation rather than three near-identical ones: they differ
    /// only in what they call and where the answer goes, and the parts that are
    /// easy to get subtly wrong, the deadline, the refusal to run twice, the
    /// order the note is written in, are the parts they share.
    private func run<Produced: Sendable>(
        _ key: Key,
        brandVoiceNote: String?,
        appState: AppState,
        work: @escaping @Sendable () async throws -> Produced,
        write: @escaping @MainActor (Produced, AppState) -> Outcome
    ) {
        outcomes[key] = nil
        tracker.begin(Run(startedAt: Date(), elapsedSeconds: 0), for: key)

        let deadline = activeDeadline
        let note = appendBrandVoiceNote
        Task { @MainActor [weak self] in
            do {
                let produced = try await DeadlinedWork.run(within: deadline) {
                    try await work()
                }
                guard !Task.isCancelled else { return }
                var outcome = write(produced, appState)
                // The note is written only AFTER the revision landed. A note
                // about a revision that never happened is a note about nothing,
                // and it would sit in the brand voice file permanently.
                if let brandVoiceNote {
                    do {
                        try await note(brandVoiceNote)
                    } catch {
                        outcome.noteFailure = BrandVoiceSaveText
                            .revisionLandedButNoteDidNot(error.localizedDescription)
                    }
                }
                self?.finish(key, with: outcome)
            } catch {
                self?.finish(key, with: Outcome(failure: Self.failureMessage(error)))
            }
        }
    }

    /// Change part of the stored week, leaving the rest of it alone.
    ///
    /// The live event, re-read rather than the copy the run started from: a
    /// paid call takes long enough for something else to have written.
    private func writeWeek(to eventID: Event.ID, in appState: AppState,
                           _ change: (inout WeekGenerationResult) -> Void) {
        guard var live = appState.events.first(where: { $0.id == eventID }),
              var week = live.weekResult else { return }
        change(&week)
        live.weekResult = week
        appState.updateEvent(live)
    }

    private func finish(_ key: Key, with outcome: Outcome) {
        outcomes[key] = outcome
        tracker.remove(key)
    }

    /// What Dan reads when a run did not work.
    ///
    /// The stall gets its own sentence: "it failed" and "it never came back"
    /// are different problems with different next steps (L11).
    private static func failureMessage(_ error: Error) -> String {
        if let stalled = error as? DeadlinedWork.Stalled {
            return "The run did not come back within "
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
extension CaptionWorkManager: BackgroundWork {
    var workPhrase: String { "a caption rerun is still running" }
}
