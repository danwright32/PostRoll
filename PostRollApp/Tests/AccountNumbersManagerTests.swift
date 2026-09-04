import XCTest

/// The automatic figures fetch, and when it runs (#1004).
///
/// Its own manager rather than a third `Kind` on `PerformerLookupManager`.
/// #1049 made that lock opt in, so a third kind would no longer disable the two
/// buttons Dan did not press, but `workPhrase` and the unconditional failure
/// notification are still shared, and neither is right for a fetch nobody
/// asked for: "a performer lookup is still running" is not what this is, and a
/// system notification for a background refresh that failed is noise.
@MainActor
final class AccountNumbersManagerTests: XCTestCase {

    private var root: URL!
    private var book: AccountBook!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("numbers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        book = AccountBook(fileURL: root.appendingPathComponent("accounts.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let now = Date(timeIntervalSince1970: 1_775_000_000)

    nonisolated private static func figures(
        _ handle: String, outcome: String = "measured",
        followers: Int? = 1_000, likes: Int? = 50,
        comments: Int? = 5) -> PythonBridge.AccountFigures {
        PythonBridge.AccountFigures(
            handle: handle, outcome: outcome, followers: followers, likes: likes,
            comments: comments, likesHidden: false, followersFromPage: false,
            instagramID: "17841400000000000", reels: 2, feed: 4, detail: "",
            allowanceSpent: 3)
    }

    /// A manager with the subprocess replaced, so nothing here spends Dan's
    /// Meta allowance or waits on the network (L2).
    private func manager(_ answer: @escaping @Sendable ([String]) async throws
                         -> [PythonBridge.AccountFigures]) -> AccountNumbersManager {
        let made = AccountNumbersManager(book: book)
        made.fetch = answer
        // No wait at all by default. The two coalescing tests below install a
        // gate instead, because zeroing a delay removes the coalescing along
        // with it and the behaviour under test stops existing.
        made.waitForSettle = { }
        return made
    }

    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    // MARK: - What it asks about

    func testFiguresLandInTheBook() async {
        let m = manager { handles in handles.map { Self.figures($0) } }

        m.handlesSettled(["janecellist"], asOf: now)
        await settle()

        XCTAssertEqual(book.stats(for: "janecellist")?.followers, 1_000)
        XCTAssertEqual(book.stats(for: "janecellist")?.outcome, .measured)
    }

    func testAnAccountAlreadyMeasuredIsNotAskedAboutAgain() async {
        book.write(AccountStats(followers: 2_000, likes: 9, comments: 1, recordedOn: now,
                                followersSource: .measured, likesSource: .measured,
                                commentsSource: .measured, outcome: .measured),
                   for: "known")
        let asked = Counter()
        let m = manager { handles in asked.add(handles.count); return [] }

        m.handlesSettled(["known"], asOf: now)
        await settle()

        XCTAssertEqual(asked.value, 0, "the allowance was spent on an account nothing "
                       + "has changed about")
    }

    func testNothingDueStartsNoSubprocessAtAll() async {
        // A run that shells out to Python to ask about nothing still pays for
        // the interpreter, and it happens on every keystroke.
        let started = Counter()
        let m = manager { _ in started.add(1); return [] }
        book.write(AccountStats(followers: 2_000, likes: 9, comments: 1, recordedOn: now,
                                outcome: .measured), for: "known")

        m.handlesSettled(["known"], asOf: now)
        await settle()

        XCTAssertEqual(started.value, 0)
    }

    // MARK: - Coalescing, not refusing (#1004)

    func testSuggestionsAcceptedOneAtATimeAreOneFetch() async {
        // Dan accepts handle suggestions one at a time, and the median event
        // has six. Refusing the second onward would drop five of six with
        // nothing recording it, and they could never be recovered: an account
        // with no record has no stamp, so it can never be stale, so nothing
        // would ever refetch it.
        let batches = Batches()
        let m = manager { handles in batches.record(handles); return [] }
        let gate = Gate()
        m.waitForSettle = { await gate.held() }

        m.handlesSettled(["a"], asOf: now)
        m.handlesSettled(["a", "b"], asOf: now)
        m.handlesSettled(["a", "b", "c"], asOf: now)
        gate.open()
        await settle()

        XCTAssertEqual(batches.all.count, 1, "each acceptance started its own fetch")
        XCTAssertEqual(batches.all.first, ["a", "b", "c"],
                       "the coalesced fetch asked about the handles as they finally "
                       + "stood, not as they were when the first one arrived")
    }

    func testASecondSettleWhileAFetchIsRunningIsNotLost() async {
        // The other half of coalescing: a handle added while the first fetch is
        // in flight has to be picked up, or it is exactly the dropped account
        // the comment above describes.
        let batches = Batches()
        // Answers, so the first fetch's result is actually recorded. With a
        // fake that returned nothing, the second fetch would ask about "a"
        // again for a correct reason and the assertion would be about the
        // fake rather than about the manager.
        let m = manager { handles in
            batches.record(handles)
            return handles.map { Self.figures($0) }
        }

        m.handlesSettled(["a"], asOf: now)
        await settle()
        m.handlesSettled(["a", "b"], asOf: now)
        await settle()

        XCTAssertEqual(batches.all.count, 2)
        XCTAssertEqual(batches.all.last, ["b"], "the second fetch re-asked about an "
                       + "account the first had already answered for")
    }

    // MARK: - Failure is recorded, not swallowed

    func testAFailedFetchLeavesANoteRatherThanNothing() async {
        struct Boom: Error {}
        let m = manager { _ in throw Boom() }

        m.handlesSettled(["janecellist"], asOf: now)
        await settle()

        XCTAssertNotNil(m.failureNote, "a fetch that failed said nothing at all, which "
                        + "reads exactly like one that was never triggered")
    }

    func testASuccessfulFetchClearsTheNote() async {
        struct Boom: Error {}
        let m = manager { _ in throw Boom() }
        m.handlesSettled(["a"], asOf: now)
        await settle()
        XCTAssertNotNil(m.failureNote)

        m.fetch = { handles in handles.map { Self.figures($0) } }
        m.handlesSettled(["b"], asOf: now)
        await settle()

        XCTAssertNil(m.failureNote, "the note outlived the failure it described")
    }

    func testTheNoteIsNotTheBooksRecoveryNote() async {
        // Two independent conditions sharing one field means one silences the
        // other (L53). "The account file could not be read" and "the last fetch
        // failed" are different problems with different remedies.
        struct Boom: Error {}
        let m = manager { _ in throw Boom() }

        m.handlesSettled(["a"], asOf: now)
        await settle()

        XCTAssertNil(book.recoveryNote, "the book loaded fine")
        XCTAssertNotNil(m.failureNote, "and the fetch failure still has somewhere to go")
    }

    // MARK: - The archive's recurring accounts, at launch (#1268)

    private func event(_ name: String, tagging handles: [String]) -> Event {
        var e = Event(name: name, org: "Org", venue: "Hall", date: now, shootType: .fullShow)
        var posting = PostingDay(day: .wednesday)
        posting.tagHandles = handles
        e.days[DayName.wednesday.rawValue] = posting
        return e
    }

    private func owners(_ answer: @escaping @Sendable ([String]) async throws
                        -> [PythonBridge.AccountFigures]) -> AppOwners {
        var made = AppOwners()
        made.accountNumbers = manager(answer)
        return made
    }

    func testTheArchivesRecurringAccountsAreAskedAboutOnce() async {
        // Nothing had ever asked about them. The fetch fires when an event's
        // handles settle, so the events already in the store when it shipped
        // were never reached, and the ranking they feed had nothing to rank.
        let heard = Recorder()
        let owned = owners { handles in heard.saw(handles); return [] }

        owned.backfillTheArchive(events: [event("a", tagging: ["carnegiehall", "oneoff"]),
                                          event("b", tagging: ["carnegiehall"])],
                                 stats: { _ in nil }, asOf: now)
        await settle()

        XCTAssertEqual(heard.handles, ["carnegiehall"],
                       "either the recurring account was missed or the allowance "
                       + "was spent on a performer who never comes back")
    }

    func testALaunchWithNothingLeftToBackfillAsksAboutNothing() async {
        // Idempotent by construction rather than by a stored marker: the fetch
        // records an outcome, and an account carrying one is not asked again.
        // A marker would be written by a launch that fetched nothing and turn
        // a transient failure into permanent loss (L368).
        let heard = Recorder()
        let owned = owners { handles in heard.saw(handles); return [] }
        let answered = AccountStats(followers: 1_000, likes: 50, comments: 5, recordedOn: now,
                                    outcome: .measured)

        owned.backfillTheArchive(events: [event("a", tagging: ["carnegiehall"]),
                                          event("b", tagging: ["carnegiehall"])],
                                 stats: { _ in answered }, asOf: now)
        await settle()

        XCTAssertTrue(heard.handles.isEmpty, "the pass asked again about an account "
                      + "the fetch has already answered for")
    }

    func testALaunchThatCouldNotFetchLeavesTheWorkStillDue() async {
        // The failure path. The pass records nothing itself, so a launch where
        // the fetch throws leaves every handle exactly as due as it was, and
        // the next launch asks again.
        struct Refused: Error {}
        let heard = Recorder()
        let owned = owners { handles in heard.saw(handles); throw Refused() }
        let events = [event("a", tagging: ["carnegiehall"]), event("b", tagging: ["carnegiehall"])]

        owned.backfillTheArchive(events: events, stats: { self.book.stats(for: $0) }, asOf: now)
        await settle()

        // The attempt has to have HAPPENED, or "still due" is satisfied by a
        // fixture in which nothing could have marked it done anyway (L159).
        XCTAssertEqual(heard.handles, ["carnegiehall"], "the fetch was never attempted, "
                       + "so this says nothing about what a failure leaves behind")
        XCTAssertEqual(AccountFetchDue.archiveBackfill(events: events,
                                                       stats: { self.book.stats(for: $0) }),
                       ["carnegiehall"],
                       "a failed launch left the account looking done, so nothing "
                       + "will ever ask about it again")
    }

    // MARK: - Saying whether the launch pass actually ran (#1277)

    /// The pass said nothing at all either way before this.
    ///
    /// A launch whose token was rejected and a launch with nothing left to ask
    /// about both left the ranking empty and neither said why, so the only way
    /// to tell them apart was to open `accounts.json` by hand (L98, L11). Every
    /// one of these asserts a DISTINCTION rather than a sentence, so the wording
    /// can be improved without a guard defending the old copy (L103).

    private func recurring(_ handle: String) -> [Event] {
        [event("a", tagging: [handle]), event("b", tagging: [handle])]
    }

    func testALaunchWithNothingLeftToAskAboutSaysItLooked() async {
        let owned = owners { _ in [] }
        let answered = AccountStats(followers: 1_000, likes: 50, comments: 5,
                                    recordedOn: now, outcome: .measured)

        owned.backfillTheArchive(events: recurring("carnegiehall"),
                                 stats: { _ in answered }, asOf: now)
        await settle()

        XCTAssertNotNil(owned.accountNumbers.backfillNote,
                        "a launch with nothing to ask about said nothing at all, which "
                        + "reads exactly like a launch that could not ask")
    }

    func testALaunchNamesHowManyItAskedAboutAndHowManyCameBack() async {
        // Three recurring accounts, one of which Meta would not answer for.
        // Both numbers, because "asked about three" alone reads as success and
        // a run where nothing came back is the failure this exists to catch.
        let owned = owners { handles in
            handles.map { Self.figures($0, outcome: $0 == "cityopera" ? "network_failed"
                                                                     : "measured") }
        }
        let events = ["carnegiehall", "dciny", "cityopera"].flatMap { recurring($0) }

        owned.backfillTheArchive(events: events, stats: { _ in nil }, asOf: now)
        await settle()

        let note = try! XCTUnwrap(owned.accountNumbers.backfillNote)
        XCTAssertTrue(note.contains("3"), "the note does not say how many accounts the "
                      + "pass asked about: \(note)")
        XCTAssertTrue(note.contains("2"), "the note does not say how many came back, so "
                      + "a run that answered for none of them reads the same: \(note)")
    }

    func testALaunchThatGotNothingBackDoesNotReadAsSuccess() async {
        // The saturation case. Every account refused is the state milestone 23
        // actually fails in, and a proportion is not what tells it apart from a
        // healthy run: the count of figures is (L139).
        let owned = owners { handles in
            handles.map { Self.figures($0, outcome: "token_rejected") }
        }

        owned.backfillTheArchive(events: recurring("carnegiehall"),
                                 stats: { _ in nil }, asOf: now)
        await settle()

        let refused = try! XCTUnwrap(owned.accountNumbers.backfillNote)
        let healthy = AccountNumbersManager.launchNote(for: .asked(asked: 1, measured: 1))
        XCTAssertNotEqual(refused, healthy,
                          "a launch Meta answered for nobody says the same thing as one "
                          + "that worked, so the ranking staying empty explains itself "
                          + "as normal")
    }

    func testALaunchThatCouldNotRunSaysSoAndSaysWhy() async {
        // Two notes, not one. This one answers "has the archive ever been
        // counted", which outlives the attempt; the failure note answers "what
        // went wrong just now". Different questions, different remedies, so a
        // shared field would have one silence the other (L53).
        struct Refused: Error {}
        let owned = owners { _ in throw Refused() }

        owned.backfillTheArchive(events: recurring("carnegiehall"),
                                 stats: { _ in nil }, asOf: now)
        await settle()

        XCTAssertNotNil(owned.accountNumbers.backfillNote,
                        "a launch that could not ask at all said nothing about the "
                        + "archive, so the empty ranking has no cause anywhere")
        XCTAssertNotNil(owned.accountNumbers.failureNote,
                        "and the reason the backfill note points at is not there, so "
                        + "the note names an explanation nobody can read (L111)")
    }

    func testTheFourLaunchStatesDoNotShareWording() {
        // Distinct causes get distinct messages (L11). Only two of these ask
        // anything of Dan, and a shared sentence is what makes the other two
        // indistinguishable from them.
        let said = [
            AccountNumbersManager.launchNote(for: .nothingDue),
            AccountNumbersManager.launchNote(for: .alreadyRunning),
            AccountNumbersManager.launchNote(for: .couldNotRun),
            AccountNumbersManager.launchNote(for: .asked(asked: 4, measured: 4)),
            AccountNumbersManager.launchNote(for: .asked(asked: 4, measured: 1)),
            AccountNumbersManager.launchNote(for: .asked(asked: 4, measured: 0)),
        ]

        XCTAssertEqual(Set(said).count, said.count,
                       "two launch states say the same thing, so one of them cannot be "
                       + "told from the other on any screen: \(said)")
    }

    func testTheLaunchNoteReachesTheSurfacesBesideTheFailureNote() async {
        // The note existing is not the note reaching anybody (L3, L46). Both
        // notes travel as elements of one list rather than as two parallel
        // fields, so a surface cannot pick up one and miss the other.
        struct Refused: Error {}
        let owned = owners { _ in throw Refused() }
        owned.connectTheHandleTrigger()

        owned.backfillTheArchive(events: recurring("carnegiehall"),
                                 stats: { _ in nil }, asOf: now)
        await settle()

        XCTAssertEqual(owned.export.accountNumbersNotes.count, 2,
                       "the export copies its inputs before detaching, and it did not "
                       + "get both notes: \(owned.export.accountNumbersNotes)")
        XCTAssertEqual(Set(owned.export.accountNumbersNotes),
                       Set(owned.accountNumbers.notes),
                       "the export is carrying something other than what the manager "
                       + "actually said")
    }

    // MARK: - Helpers

    /// Remembers which handles reached the fetch, from whichever thread asked.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func saw(_ handles: [String]) { lock.withLock { seen += handles } }
        var handles: [String] { lock.withLock { seen } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add(_ n: Int) { lock.withLock { count += n } }
        var value: Int { lock.withLock { count } }
    }

    /// Holds the settle wait open until the test lets go.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var opened = false

        func held() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened { lock.unlock(); continuation.resume() }
                else { waiting = continuation; lock.unlock() }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let continuation = waiting
            waiting = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private final class Batches: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[String]] = []
        func record(_ handles: [String]) { lock.withLock { batches.append(handles) } }
        var all: [[String]] { lock.withLock { batches } }
    }

    // MARK: - A spent allowance is said out loud (#1207)

    /// `RATE_LIMITED` is an expected failure, so the code waving it through has
    /// no notion of volume: one blip and a systemic limit arrive on exactly the
    /// same path (L77). Measured on 2026-09-01, sweeping the 122 real handles
    /// twice put the app 275% over its hourly allowance and 82 of the 122 came
    /// back limited, and none of that reached a surface Dan passes.
    ///
    /// Classified by FREQUENCY, not only by kind: normal below a threshold,
    /// worth saying above it.

    nonisolated private static func limited(_ handle: String,
                                            spent: Double? = 275) -> PythonBridge.AccountFigures {
        PythonBridge.AccountFigures(
            handle: handle, outcome: "rate_limited", followers: nil, likes: nil,
            comments: nil, likesHidden: false, followersFromPage: false,
            instagramID: nil, reels: nil, feed: nil, detail: "", allowanceSpent: spent)
    }

    func testARunThatWasMostlyRefusedSaysTheAllowanceIsGone() async throws {
        let m = manager { handles in handles.map { Self.limited($0) } }

        m.handlesSettled(["a", "b", "c", "d"], asOf: now)
        await settle()

        // `try` rather than `try!`. A forced unwrap turns this assertion
        // failing into a TRAP, which kills the process and reports zero tests
        // executed rather than one named failure, and a run that executed
        // nothing is not a run that passed (L98).
        let note = try XCTUnwrap(m.failureNote)
        XCTAssertTrue(note.lowercased().contains("allowance")
                      || note.lowercased().contains("limit"), note)
        XCTAssertTrue(note.lowercased().contains("hour"),
                      "the note has to say roughly how long, or it names no way out "
                      + "of the state it reports (L111): \(note)")
    }

    func testOneRefusedAccountAmongManyIsNotReportedAsAnOutage() async {
        // The positive control (L159), and the more important direction: a note
        // on every rate limit is noise on an ordinary run, and noise is how a
        // real one stops being read (L36).
        let m = manager { handles in
            handles.map { $0 == "a" ? Self.limited($0) : Self.figures($0) }
        }

        m.handlesSettled(["a", "b", "c", "d"], asOf: now)
        await settle()

        XCTAssertNil(m.failureNote)
    }

    func testTheNoteNamesHowMuchOfTheAllowanceIsGoneWhenMetaSaidSo() async {
        let m = manager { handles in handles.map { Self.limited($0, spent: 275) } }

        m.handlesSettled(["a", "b"], asOf: now)
        await settle()

        XCTAssertTrue((m.failureNote ?? "").contains("275"),
                      "Meta gave a reading and it is not shown: \(m.failureNote ?? "")")
    }

    func testARunRefusedWithNoReadingStillSaysSo() async {
        // The reading is Meta's and it may not come. The refusal happened
        // either way, and reporting nothing because one field was missing is
        // how a real outage stays invisible (L530).
        let m = manager { handles in handles.map { Self.limited($0, spent: nil) } }

        m.handlesSettled(["a", "b"], asOf: now)
        await settle()

        XCTAssertNotNil(m.failureNote)
        XCTAssertFalse((m.failureNote ?? "").contains("%"),
                       "a percentage was reported that nobody measured: "
                       + (m.failureNote ?? ""))
    }

    // MARK: - The trigger is actually connected (#1004, L3)

    func testAcceptingAHandleSuggestionTellsTheFetch() async {
        // Through the real lookup manager, not a stub of it: this is the
        // moment the issue names first, and a callback nothing invokes is
        // indistinguishable from one that works (L46).
        let event = Event(name: "Spring Gala", org: "Decoda", venue: "Merkin Hall",
                          date: Date(), shootType: .fullShow)
        var seeded = event
        seeded.ocrResult = OCRResult(performers: [Performer(name: "Jenna Robison")])
        let state = AppState(events: [seeded],
                             storeURL: root.appendingPathComponent("events.json"),
                             dataRoot: root)
        let lookup = PerformerLookupManager()
        let told = Told()
        lookup.onHandlesSettled = { told.record($0) }

        lookup.apply(PythonBridge.HandleSuggestion(
            name: "Jenna Robison", handle: "@jennarobison", profileURL: nil,
            confidence: "high", note: nil), to: seeded.id, in: state)

        XCTAssertTrue(told.handles.contains { $0.contains("jennarobison") },
                      "accepting a suggestion did not tell the fetch: \(told.handles)")
    }

    func testTheAppJoinsTheLookupToTheFetch() {
        // The wiring itself. Both managers are correct in isolation and the
        // feature does nothing at all unless somebody connects them, which is
        // one line in one place and therefore one line to forget.
        let owners = AppOwners()
        XCTAssertNil(owners.lookup.onHandlesSettled,
                     "something else already connected this, so the assertion "
                     + "below would pass whether connectTheHandleTrigger works or not")

        owners.connectTheHandleTrigger()

        XCTAssertNotNil(owners.lookup.onHandlesSettled)
        XCTAssertNotNil(owners.accountNumbers.onNoteChanged)
    }

    func testSavingATokenAsksAgainAboutEverythingThatFailed() async {
        // The remedy `token_rejected` names has to change the state Dan is
        // stuck in, or it is a message he can obey with no effect (L111).
        book.write(AccountStats(followers: 900, recordedOn: now, outcome: .tokenRejected),
                   for: "stuck")
        let batches = Batches()
        let m = manager { handles in batches.record(handles); return [] }

        m.credentialChanged(asOf: now)
        await settle()

        XCTAssertEqual(batches.all.first, ["stuck"])
    }

    func testSavingATokenDoesNotReaskAboutTerminalAccounts() {
        // The positive control (L159). A refetch of everything would spend the
        // whole allowance on accounts Meta will never answer differently for.
        book.write(AccountStats(followers: 900, recordedOn: now, outcome: .notProfessional),
                   for: "personal")

        XCTAssertFalse(AccountFetchDue.isDue(book.stats(for: "personal"), asOf: now))
    }

    func testBothSurfacesCarryTheFetchNotesAsTheirOwnElements() {
        // The note existing is not the note reaching anybody (L3, L46). Both
        // surfaces build a notes ARRAY, and #1004 is explicit that these go in
        // as their own elements rather than being folded into the book's own
        // note, because conditions sharing one field means one silences the
        // other (L53).
        //
        // The anchor is the manager's whole LIST rather than one note by name,
        // so a surface that named only `failureNote` and so dropped the launch
        // note #1277 added fails this rather than passing on the half it kept.
        for (file, needle) in [
            ("Views/CaptionReviewView.swift", "accountNumbers.notes"),
            ("Services/ExportManager.swift", "accountNumbersNotes"),
        ] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/\(file)")
            let code = SwiftSourceText.withoutComments(
                try! String(contentsOf: url, encoding: .utf8))

            XCTAssertTrue(code.contains(needle),
                          "\(file) does not carry the fetch's notes, so a fetch that "
                          + "failed and a launch that never counted the archive both "
                          + "say nothing there and read exactly like a healthy run")
            XCTAssertTrue(code.contains("recoveryNote"),
                          "\(file) no longer carries the book's own note either, so "
                          + "this check would pass on a surface that says nothing at all")
        }
    }

    private final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [[String]] = []
        func record(_ handles: [String]) { lock.withLock { seen.append(handles) } }
        var handles: [[String]] { lock.withLock { seen } }
    }
}
