import Foundation
import Observation

/// Fetches audience figures when an event's handle list settles (#1004).
///
/// Its own manager rather than a third `Kind` on `PerformerLookupManager`.
/// #1049 made that exclusion lock opt in, so a third kind would no longer
/// disable the two buttons Dan did not press, but `workPhrase` and the
/// unconditional failure notification are still shared and neither is right
/// here: "a performer lookup is still running" is not what this is, and a
/// system notification for a background refresh nobody asked for is noise.
///
/// Forward only. No backfill of the archive: the figures are for ranking
/// collaborators on posts still to go out, and asking about every account ever
/// tagged would spend the hourly allowance on events that shipped months ago.
@MainActor
@Observable
final class AccountNumbersManager {

    /// How long to wait for the handle list to stop changing.
    ///
    /// Dan accepts handle suggestions one at a time, and the median event has
    /// six, so the trigger fires six times. It COALESCES rather than refusing:
    /// dropping five of six would lose them permanently, because an account
    /// with no record has no stamp, so it can never be stale, so nothing would
    /// ever refetch it.
    ///
    /// Three seconds, which is longer than the gap between two clicks and
    /// shorter than the pause before moving on to another part of the screen.
    static let settleDelay: TimeInterval = 3

    /// The wait itself, injectable.
    ///
    /// A seam rather than a number the tests set to zero: zeroing it removes
    /// the coalescing along with the delay, so the behaviour under test stops
    /// existing. A test holds this open, queues the settles it wants to
    /// coalesce, and lets go, which asserts the coalescing rather than a
    /// stopwatch (L290, L524).
    var waitForSettle: @Sendable () async -> Void = {
        try? await Task.sleep(for: .seconds(AccountNumbersManager.settleDelay))
    }

    /// The subprocess, injectable so the suite never spends the Meta allowance
    /// or waits on the network (L2). Defaults to the real one so no call site
    /// can accidentally get a fake (L196).
    var fetch: @Sendable ([String]) async throws -> [PythonBridge.AccountFigures] = {
        try await PythonBridge.shared.fetchAccountNumbers(handles: $0)
    }

    /// What to say when the last fetch failed, or nil.
    ///
    /// Its OWN field, deliberately not folded into `AccountBook.recoveryNote`,
    /// which is a computed property over `LoadStatus` answering "did the file
    /// load". Two independent conditions sharing one field means one silences
    /// the other (L53), and "the account file could not be read" and "the last
    /// fetch failed" are different problems with different remedies.
    private(set) var failureNote: String? {
        didSet { onNoteChanged?(notes) }
    }

    /// What the launch pass over the archive did, or nil before one has run.
    ///
    /// Its OWN field beside `failureNote` for the same reason that one is its
    /// own field beside `AccountBook.recoveryNote` (L53). Three independent
    /// conditions: "the account file could not be read", "the last fetch
    /// failed", and "the archive has never been counted". The third outlives
    /// the attempt that produced it and has its own remedy, and a field shared
    /// with the second would have one silence the other.
    ///
    /// Written on EVERY launch, including the ones with nothing to do, because
    /// a pass that found nothing and a pass that could not run are the two
    /// states this exists to tell apart, and only one of them says nothing
    /// (L98, L11).
    private(set) var backfillNote: String? {
        didSet { onNoteChanged?(notes) }
    }

    /// Everything this owner has to say, in a stable order.
    ///
    /// A LIST rather than one field, because the conditions are independent
    /// and a shared field means one silences the other (L53). A list rather
    /// than two properties a consumer reads separately, because every consumer
    /// wants all of them, and two parallel pipes is two things to keep in step
    /// and one to forget (L41).
    var notes: [String] { [failureNote, backfillNote].compactMap { $0 } }

    /// Told whenever anything it says changes, so a surface that copies its
    /// inputs before detaching has the current list (#1004, #1277).
    var onNoteChanged: (([String]) -> Void)?

    private let book: AccountBook
    private var pending: Task<Void, Never>?
    private var running = false

    /// Whether a fetch is going, or one is waiting for the list to settle.
    ///
    /// Both, because a settle that has been queued and not yet fired is work
    /// this owner started: reporting only the running half would say nothing is
    /// happening for the three seconds when something is about to.
    var hasWorkInFlight: Bool { running || pending?.isCancelled == false }

    init(book: AccountBook = .shared) {
        self.book = book
    }

    /// The handle list for an event has stopped changing.
    ///
    /// Called after a handle lookup suggestion is accepted, after a web fetch
    /// replaces the list, and after a handle is typed by hand.
    func handlesSettled(_ handles: [String], asOf now: Date = Date()) {
        // Replaces any wait already in flight, so the fetch asks about the
        // handles as they finally stand rather than as they were when the
        // first of six acceptances arrived.
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            await waitForSettle()
            guard !Task.isCancelled else { return }
            await run(handles, asOf: now)
        }
    }

    /// Every non terminal record is worth another attempt now.
    ///
    /// Saving a token in Settings is the remedy `token_rejected` names, so it
    /// has to actually change the state Dan is stuck in: without this the
    /// records that failed for want of a credential sit there until something
    /// else happens to re-tag those accounts.
    func credentialChanged(asOf now: Date = Date()) {
        handlesSettled(book.all.map(\.handle), asOf: now)
    }

    /// The launch pass over the archive's recurring accounts (#1268), saying
    /// what it did (#1277).
    ///
    /// Its own entry point rather than a flag on `handlesSettled`, because the
    /// two differ in exactly one way and it is the reporting: a settle fires on
    /// every accepted suggestion and a note on each would be noise, while the
    /// launch pass runs once and its silence is the whole defect. Everything
    /// else, the debounce, the due filter and the merge, is shared rather than
    /// written twice.
    ///
    /// An empty list is reported here rather than run through the debounce for
    /// nothing: both branches phrase it with the one `launchNote`, so there is
    /// one sentence for the state however it was reached (L70).
    func backfill(_ handles: [String], asOf now: Date = Date()) {
        guard !handles.isEmpty else {
            backfillNote = Self.launchNote(for: .nothingDue)
            return
        }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            await waitForSettle()
            guard !Task.isCancelled else { return }
            backfillNote = Self.launchNote(for: await run(handles, asOf: now))
        }
    }

    /// What one pass of the fetch did, for a caller that has to say so (#1277).
    ///
    /// Returned rather than written to a field by `run` itself, because only
    /// the launch pass reports it: the forward path fires several times a
    /// minute while Dan accepts suggestions and a sentence per settle is the
    /// noise that stops the real one being read (L36).
    enum PassOutcome: Equatable {
        /// Every handle already carried a fetch result, so nothing was asked.
        /// The one state that needs nothing from anybody.
        case nothingDue
        /// A fetch was already going, so this pass did nothing. The handles are
        /// exactly as due as they were.
        case alreadyRunning
        /// `asked` accounts were asked about and `measured` came back carrying
        /// figures. `measured` counts figures rather than answers: Meta
        /// refusing an account is a reply, and calling it one would let a run
        /// that counted nobody read as a full success.
        case asked(asked: Int, measured: Int)
        /// The call could not be made at all. The reason is on `failureNote`,
        /// which the same pass writes.
        case couldNotRun
    }

    /// What the launch pass says, in one sentence.
    ///
    /// Six sentences for six states, because they are currently one silence:
    /// an empty collaborator ranking after a launch with nothing to ask about
    /// and after one whose token was rejected look identical on every screen
    /// (L98, L11). Two of the six need action and each says which.
    ///
    /// Plain about what is lost, because the honest answer is usually "nothing,
    /// it asks again next launch": `AccountFetchDue.archiveBackfill` derives
    /// what is still due from the outcomes themselves, so a pass that failed
    /// leaves every handle exactly as due as it found them.
    static func launchNote(for outcome: PassOutcome) -> String {
        let opening = "The launch check of the archive's recurring accounts "
        switch outcome {
        case .nothingDue:
            return opening + "found nothing to ask about, because every one of "
                 + "them already carries a result. Nothing to do."
        case .alreadyRunning:
            return opening + "did not run, because a figures fetch was already "
                 + "going. They are still due, so the next launch asks again."
        case .couldNotRun:
            return opening + "could not run, so nothing from the archive has "
                 + "been counted and the collaborator ranking has nothing from "
                 + "it to rank. The fetch failure note says why."
        case .asked(let asked, 0):
            return opening + "asked Meta about \(asked) of them and got figures "
                 + "for none, so the collaborator ranking still has nothing "
                 + "from the archive to rank."
        case .asked(let asked, let measured) where measured == asked:
            return opening + "asked Meta about \(asked) of them and got figures "
                 + "for all \(asked)."
        case .asked(let asked, let measured):
            return opening + "asked Meta about \(asked) of them and got figures "
                 + "for \(measured). The rest are still due, so the next launch "
                 + "asks about them again."
        }
    }

    @discardableResult
    private func run(_ handles: [String], asOf now: Date) async -> PassOutcome {
        guard !running else { return .alreadyRunning }
        let due = AccountFetchDue.handles(from: handles,
                                          stats: { self.book.stats(for: $0) },
                                          asOf: now)
        // Nothing to ask about starts nothing. A run that shells out to Python
        // to ask about no accounts still pays for the interpreter, and this
        // fires on every settle.
        guard !due.isEmpty else { return .nothingDue }

        running = true
        defer { running = false }
        // The call spends Meta's allowance BEFORE anything is recorded, so a
        // crash between the two loses the recording and not the cost (L33).
        // That is inherent to a metered API and it is survivable here rather
        // than merely tolerated: an account with nothing merged stays due, so
        // the next settle asks again, and `AccountFetchDue.maximumAttempts`
        // stops that becoming a loop. What is NOT covered is noticing that the
        // allowance is going, which is #1207.
        do {
            let answers = try await fetch(due)
            for answer in answers {
                book.merge(answer.stats(recordedOn: now), for: answer.handle, on: now)
            }
            // A rate limit is an EXPECTED failure, so nothing above it has any
            // notion of volume: one account hitting a limit and the whole
            // allowance being gone arrive on exactly the same path and are
            // indistinguishable (L77, #1207). Classified by frequency here:
            // normal below the threshold, said out loud above it.
            failureNote = Self.allowanceNote(answers)
            // Figures, not replies. An account Meta refused answered the call
            // and carries no numbers, so counting it would let a pass that
            // measured nobody report as a full success (L540, L67).
            return .asked(asked: due.count,
                          measured: answers.filter { $0.outcome == "measured" }.count)
        } catch {
            // Said out loud rather than swallowed. A background fetch that
            // failed silently is indistinguishable from one that never ran, and
            // the ranking then quietly goes on using whatever it had (L12).
            failureNote = Self.note(for: error)
            return .couldNotRun
        }
    }

    /// What share of a run has to come back refused before it is an outage
    /// rather than contention.
    ///
    /// Half. Measured on 2026-09-01: sweeping the 122 real handles twice put
    /// the app 275% over its hourly allowance and 82 of the 122, two thirds,
    /// came back limited. One or two refusals in a run of twenty is ordinary
    /// and a note on those would be noise, and noise is how a real one stops
    /// being read (L36).
    static let outageShare = 0.5

    /// Said when most of a run came back rate limited.
    ///
    /// Nil when it did not, which is the important half: a note on every rate
    /// limit is noise on an ordinary run.
    static func allowanceNote(_ answers: [PythonBridge.AccountFigures]) -> String? {
        guard !answers.isEmpty else { return nil }
        let limited = answers.filter { $0.outcome == "rate_limited" }
        guard Double(limited.count) / Double(answers.count) >= outageShare else { return nil }

        // Meta's own reading, when it sent one. A percentage nobody measured
        // must not be reported, so the sentence is built either way and only
        // carries the number when there is one (L530, L11).
        let spent = limited.compactMap(\.allowanceSpent).max()
        let reading = spent.map { " Meta says \(Int($0.rounded()))% of the hourly "
                                + "allowance is used." } ?? ""
        return "Audience figures were not fetched for \(limited.count) of "
             + "\(answers.count) accounts because Meta is rate limiting."
             + reading
             + " The allowance is a rolling hour, so this clears on its own; the "
             + "ranking is running on the numbers it already had until it does."
    }

    /// What a failed fetch says, as a second element of the notes arrays the
    /// caption and export surfaces already carry.
    static func note(for error: Error) -> String {
        "Audience figures could not be fetched, so the collaborator ranking is "
        + "running on the numbers it already had. "
        + ProgramNotesMerge.failureMessage(error)
    }
}

/// Asked whenever PostRoll is about to quit or install an update (#862).
///
/// Reports honestly that it is running, and the phrase says what losing it
/// costs, which is nothing: every record it would have written stays
/// non terminal, so the next time those handles settle it asks again. That is
/// worth saying rather than leaving Dan to weigh an unexplained "still
/// running" against closing his laptop.
extension AccountNumbersManager: BackgroundWork {
    var workPhrase: String {
        "audience figures are still being fetched, and nothing is lost if they are not"
    }
}
