import XCTest

/// Which accounts an automatic fetch should ask about (#1004).
///
/// The fetch fires when an event's handle list settles, and the question it has
/// to answer first is which of those handles are worth a call. Meta's allowance
/// is a rolling hour and asking about everything on every keystroke would spend
/// it on accounts nothing has changed about.
///
/// Pure, and tested alone, because everything else in this feature is a
/// debounce and a subprocess. This is the part with the decisions in it.
@MainActor
final class AccountFetchDueTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_775_000_000)

    private func measured(daysAgo: Int = 0) -> AccountStats {
        AccountStats(followers: 1_000, likes: 50, comments: 5,
                     recordedOn: now.addingTimeInterval(-Double(daysAgo) * 86_400),
                     followersSource: .measured, likesSource: .measured,
                     commentsSource: .measured, outcome: .measured)
    }

    private func due(_ handles: [String],
                     _ table: [String: AccountStats]) -> [String] {
        AccountFetchDue.handles(from: handles,
                                stats: { table[AccountBook.key($0)] },
                                asOf: now)
    }

    // MARK: - The archive's recurring accounts (#1268)
    //
    // The fetch is forward only: it fires when an event's handle list settles,
    // so nothing has ever asked about the events that were already in the store
    // when it shipped. Measured on the live store on 2026-09-03: 9 records, 0
    // of them rankable, and not one carrying a fetch outcome at all, so the
    // collaborator ranking those figures feed had nothing to rank on any real
    // day (L389).
    //
    // Scoped to the accounts that come back. Venues and orgs recur, one time
    // performers essentially never do, so a handle tagged once is a call spent
    // on a record nothing will read again.

    private func event(_ name: String, tagging handles: [String]) -> Event {
        var e = Event(name: name, org: "Org", venue: "Hall", date: now, shootType: .fullShow)
        var posting = PostingDay(day: .wednesday)
        posting.tagHandles = handles
        e.days[DayName.wednesday.rawValue] = posting
        return e
    }

    private func backfill(_ events: [Event], _ table: [String: AccountStats] = [:]) -> [String] {
        AccountFetchDue.archiveBackfill(events: events,
                                        stats: { table[AccountBook.key($0)] })
    }

    func testAnAccountTaggedOnOneEventOnlyIsNotBackfilled() {
        XCTAssertEqual(backfill([event("a", tagging: ["oneoff"])]), [])
    }

    func testAnAccountTaggedOnTwoEventsIsBackfilled() {
        XCTAssertEqual(backfill([event("a", tagging: ["carnegiehall"]),
                                 event("b", tagging: ["carnegiehall"])]),
                       ["carnegiehall"])
    }

    func testAnAccountAFetchHasAlreadyAnsweredIsNotAskedAgain() {
        // What makes this a backfill rather than a launch sweep. Refreshing a
        // figure that has aged stays with the forward path; this asks only
        // about accounts no fetch has ever reached.
        let events = [event("a", tagging: ["carnegiehall"]),
                      event("b", tagging: ["carnegiehall"])]
        XCTAssertEqual(backfill(events, ["carnegiehall": measured()]), [])
        XCTAssertEqual(backfill(events, ["carnegiehall": measured(daysAgo: 400)]), [],
                       "a stale figure is the forward path's job, not this one")
    }

    func testAnAccountDanTypedFiguresForIsStillBackfilled() {
        // Typed is not fetched. The call adds what typing cannot: the stable
        // Instagram id, the post mix, and whether Meta will answer at all.
        let typed = AccountStats(followers: 12_700, recordedOn: now, followersSource: .typed)
        XCTAssertEqual(backfill([event("a", tagging: ["batterydance"]),
                                 event("b", tagging: ["batterydance"])],
                                ["batterydance": typed]),
                       ["batterydance"])
    }

    func testTheAccountsTaggedMostAreAskedAboutFirst() {
        // The allowance is a rolling hour and a run can be cut short, so the
        // order decides which accounts got asked about (L343). A dictionary
        // has no order to inherit, so one has to be stated.
        // Named so that counting and the alphabet DISAGREE. With names whose
        // alphabetical order happens to match their tag counts, this passes
        // just as well with no ordering rule at all, which is what the first
        // version of it did (L48).
        let events = [event("a", tagging: ["ahandle", "mhandle", "zhandle"]),
                      event("b", tagging: ["mhandle", "zhandle"]),
                      event("c", tagging: ["zhandle"])]
        XCTAssertEqual(backfill(events), ["zhandle", "mhandle"],
                       "the most tagged account is not asked about first, so a run "
                       + "cut short by the allowance spent it on the rarer account")
    }

    func testAnEventListWithNothingRecurringAsksAboutNothing() {
        // Not an empty pass reported as a completed one: there is genuinely
        // nothing to ask, which is what a store of one-off performers looks
        // like, and it must not read the same as a pass that failed.
        XCTAssertEqual(backfill([event("a", tagging: ["x"]), event("b", tagging: ["y"])]), [])
    }

    // MARK: - What is worth a call

    func testAnAccountNobodyHasEverFetchedIsDue() {
        XCTAssertEqual(due(["newone"], [:]), ["newone"])
    }

    func testAnAccountMeasuredTodayIsNotAskedAgain() {
        XCTAssertEqual(due(["known"], ["known": measured()]), [])
    }

    func testAnAccountMeasuredLongAgoIsDueAgain() {
        // Figures age. Six months is the same line the freshness label uses,
        // named there rather than spelled again here.
        XCTAssertEqual(due(["old"], ["old": measured(daysAgo: AccountStats.staleAfterDays + 1)]),
                       ["old"])
    }

    func testAnAccountMetaWillNeverAnswerForIsNotAskedAgain() {
        // Terminal. A personal account does not become a professional one
        // because somebody tagged it again, and asking spends the allowance to
        // be told the same thing.
        for outcome in [AccountStats.FetchOutcome.notProfessional,
                        .noSuchAccount] {
            let stats = AccountStats(followers: 900, recordedOn: now, outcome: outcome)
            XCTAssertEqual(due(["terminal"], ["terminal": stats]), [],
                           "\(outcome) was asked about again")
        }
    }

    func testAFailedFetchIsDueAnotherAttempt() {
        // The reason this needs its own predicate rather than `freshness`.
        // `freshness` answers `.unknown` without engagement data, and `.unknown`
        // is not stale, so a record left by a network failure could never be
        // refetched by the staleness path and would be asked about never again.
        for outcome in [AccountStats.FetchOutcome.networkFailed,
                        .rateLimited, .couldNotClassify, .tokenRejected,
                        .handleChangedHands] {
            let stats = AccountStats(recordedOn: now, outcome: outcome)
            XCTAssertEqual(due(["failed"], ["failed": stats]), ["failed"],
                           "\(outcome) is not terminal but was never retried")
        }
    }

    func testARecordWithNoOutcomeAtAllIsDue() {
        // Figures Dan typed in by hand, and nothing has ever been fetched. The
        // fetch can still add the things typing cannot: the stable id, the post
        // mix, and whether Meta will answer at all.
        let typed = AccountStats(followers: 1_000, likes: 50, comments: 5,
                                 recordedOn: now, followersSource: .typed,
                                 likesSource: .typed, commentsSource: .typed)

        XCTAssertEqual(due(["typed"], ["typed": typed]), ["typed"])
    }

    // MARK: - What is not an account at all

    func testAValueThatIsNotAHandleIsNeverFetched() {
        // The same reader every other surface uses (#981), so a sentinel the
        // caption pipeline wrote cannot become a Meta call.
        XCTAssertEqual(due(["unknown", "", "  ", "real"], [:]), ["real"])
    }

    func testEverySpellingOfOneHandleIsOneCall() {
        XCTAssertEqual(due(["@jane", "jane", "https://instagram.com/JANE/"], [:]),
                       ["jane"])
    }

    // MARK: - Order and size

    func testTheOrderIsTheOrderTheHandlesArrivedIn() {
        // So a run that is cut short by the allowance has asked about the
        // accounts this event actually leads with, rather than an arbitrary
        // slice (L343).
        XCTAssertEqual(due(["zebra", "apple", "mango"], [:]), ["zebra", "apple", "mango"])
    }

    func testNothingDueIsAnEmptyListRatherThanEverything() {
        // The failure that would spend the whole hourly allowance on one
        // keystroke: a selection that fell back to "all of them" when it found
        // nothing to do.
        let table = ["a": measured(), "b": measured()]
        XCTAssertEqual(due(["a", "b"], table), [])
    }

    // MARK: - The retry is bounded (#1004)

    /// `COULD_NOT_CLASSIFY` and the transient failures are deliberately not
    /// terminal, because writing an account off on an error nobody understood
    /// has no way back. The cost is that a handle which always fails would be
    /// asked about on every settle forever, against an API metered by the hour.
    ///
    /// The bound lives here because this is the only side that has a history:
    /// the Python fetch answers about one account and remembers nothing.

    private func failed(attempts: Int, daysAgo: Int = 0) -> AccountStats {
        AccountStats(followers: 900,
                     recordedOn: now.addingTimeInterval(-Double(daysAgo) * 86_400),
                     outcome: .networkFailed, fetchAttempts: attempts)
    }

    func testAFailureIsRetriedWhileItIsUnderTheBound() {
        XCTAssertTrue(AccountFetchDue.isDue(failed(attempts: 1), asOf: now))
        XCTAssertTrue(AccountFetchDue.isDue(
            failed(attempts: AccountFetchDue.maximumAttempts - 1), asOf: now))
    }

    func testAFailureStopsBeingRetriedAtTheBound() {
        XCTAssertFalse(AccountFetchDue.isDue(
            failed(attempts: AccountFetchDue.maximumAttempts), asOf: now),
            "a handle that always fails is asked about on every settle forever, "
            + "and every attempt spends the hourly allowance to be told the same "
            + "thing")
    }

    func testTheBoundIsLiftedOnceTheRecordIsOld() {
        // Not a permanent refusal. Whatever was wrong may have been fixed, and
        // an account frozen out for good on three bad afternoons is the same
        // unrecoverable state the non terminal outcomes exist to avoid.
        XCTAssertTrue(AccountFetchDue.isDue(
            failed(attempts: AccountFetchDue.maximumAttempts,
                   daysAgo: AccountStats.staleAfterDays + 1), asOf: now))
    }

    func testATerminalOutcomeIgnoresTheAttemptCountEntirely() {
        // The positive control (L159): the bound is about failures. A measured
        // account has attempts on it too and must not be affected.
        let measured = AccountStats(followers: 1_000, likes: 50, comments: 5,
                                    recordedOn: now, outcome: .measured,
                                    fetchAttempts: 99)

        XCTAssertFalse(AccountFetchDue.isDue(measured, asOf: now))
    }

    func testTheCountIsCarriedForwardByAFailureAndClearedBySuccess() {
        // The count has to move, or the bound is a field nothing increments and
        // the retry is unbounded with a number beside it (L46).
        var stats = AccountStats(outcome: .networkFailed, fetchAttempts: 2)
        XCTAssertEqual(AccountFetchDue.attemptsAfter(stats.outcome, wasAt: 2), 3)

        stats.outcome = .measured
        XCTAssertEqual(AccountFetchDue.attemptsAfter(stats.outcome, wasAt: 2), 0,
                       "a success left the failure count standing, so the next "
                       + "failure starts from an old number")
    }
}
