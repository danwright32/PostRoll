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
}
