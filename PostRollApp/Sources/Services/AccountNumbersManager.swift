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
        didSet { onNoteChanged?(failureNote) }
    }

    /// Told whenever the note changes, so a surface that copies its inputs
    /// before detaching has the current one (#1004).
    var onNoteChanged: ((String?) -> Void)?

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

    private func run(_ handles: [String], asOf now: Date) async {
        guard !running else { return }
        let due = AccountFetchDue.handles(from: handles,
                                          stats: { self.book.stats(for: $0) },
                                          asOf: now)
        // Nothing to ask about starts nothing. A run that shells out to Python
        // to ask about no accounts still pays for the interpreter, and this
        // fires on every settle.
        guard !due.isEmpty else { return }

        running = true
        defer { running = false }
        do {
            let answers = try await fetch(due)
            for answer in answers {
                book.merge(answer.stats(recordedOn: now), for: answer.handle, on: now)
            }
            failureNote = nil
        } catch {
            // Said out loud rather than swallowed. A background fetch that
            // failed silently is indistinguishable from one that never ran, and
            // the ranking then quietly goes on using whatever it had (L12).
            failureNote = Self.note(for: error)
        }
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
