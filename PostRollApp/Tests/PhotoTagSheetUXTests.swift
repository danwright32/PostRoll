import XCTest

/// Three small defects in the per-photo tagging sheet, all of which cost time
/// on every photo rather than once per day (#192, #193, #194).
final class PhotoTagSheetUXTests: XCTestCase {

    // MARK: - #194: the last photo must not end on a dead control

    func testThePrimaryActionStepsForwardWhileThereAreMorePhotos() {
        XCTAssertEqual(
            PhotoTagSheetNavigation.primaryAction(index: 0, count: 4), .next)
        XCTAssertEqual(
            PhotoTagSheetNavigation.primaryAction(index: 2, count: 4), .next)
    }

    func testThePrimaryActionFinishesOnTheLastPhoto() {
        // Reaching the last photo is exactly the moment the work is done, so
        // the button the eye goes to should complete it rather than refuse.
        XCTAssertEqual(
            PhotoTagSheetNavigation.primaryAction(index: 3, count: 4), .done)
    }

    func testASinglePhotoOffersDoneImmediately() {
        // One photo means there is nowhere to step to, and a disabled button
        // would be the only thing on offer.
        XCTAssertEqual(
            PhotoTagSheetNavigation.primaryAction(index: 0, count: 1), .done)
    }

    func testAnOutOfRangeIndexStillOffersAWayOut() {
        // The sheet clamps its index, but the action must never come back as
        // something the person cannot press.
        XCTAssertEqual(
            PhotoTagSheetNavigation.primaryAction(index: 99, count: 4), .done)
        XCTAssertEqual(
            PhotoTagSheetNavigation.primaryAction(index: 0, count: 0), .done)
    }

    func testTheActionCarriesItsOwnLabel() {
        XCTAssertEqual(PhotoTagSheetNavigation.PrimaryAction.next.label, "Next photo")
        XCTAssertEqual(PhotoTagSheetNavigation.PrimaryAction.done.label, "Done")
    }

    func testEveryPrimaryActionIsPressable() {
        // The point of #194: whatever the state, the prominent button does
        // something. A control may only refuse when the system genuinely
        // cannot act, and there is always either a next photo or a way out.
        for count in 0...6 {
            for index in 0..<max(count, 1) {
                let action = PhotoTagSheetNavigation.primaryAction(index: index, count: count)
                XCTAssertTrue(action == .next || action == .done,
                              "index \(index) of \(count) left no pressable action")
            }
        }
    }

    // MARK: - #193: the confirmation must read as transient

    private let shown = Date(timeIntervalSince1970: 1_000_000)

    func testTheConfirmationIsVisibleJustAfterItIsShown() {
        XCTAssertTrue(PhotoTagSheetNavigation.confirmationVisible(
            shownAt: shown, now: shown.addingTimeInterval(1)))
    }

    func testTheConfirmationStaysLongEnoughToRead() {
        // It was added because the button gave no feedback at all, so it must
        // not flick away before it has been read.
        XCTAssertTrue(PhotoTagSheetNavigation.confirmationVisible(
            shownAt: shown, now: shown.addingTimeInterval(3)))
    }

    func testTheConfirmationGoesAwayOnItsOwn() {
        // A message about a finished action that sits there indefinitely stops
        // reading as "that just happened" and starts reading as current state.
        XCTAssertFalse(PhotoTagSheetNavigation.confirmationVisible(
            shownAt: shown, now: shown.addingTimeInterval(30)))
    }

    func testNothingShownIsNotVisible() {
        XCTAssertFalse(PhotoTagSheetNavigation.confirmationVisible(
            shownAt: nil, now: shown))
    }

    func testTheWindowIsSecondsNotMinutes() {
        XCTAssertGreaterThanOrEqual(PhotoTagSheetNavigation.confirmationLifetime, 3)
        XCTAssertLessThanOrEqual(PhotoTagSheetNavigation.confirmationLifetime, 15)
    }

    // MARK: - #191 and #192: the suggestion list

    private func suggestions(_ names: [String]) -> [PhotoTagSuggestion] {
        names.map { PhotoTagSuggestion(token: $0, display: $0) }
    }

    func testAnEmptyQueryShowsEverything() {
        let all = suggestions(["Safa", "Taylor Fagins", "Ladibree"])

        XCTAssertEqual(
            PhotoTagSheetNavigation.filtered(all, query: "").count, 3)
    }

    func testTypingNarrowsTheList() {
        // Nine performers plus producers already fills the panel, and the list
        // is worked through once per photo rather than once per day.
        let all = suggestions(["Safa", "Taylor Fagins", "Ladibree"])

        let hits = PhotoTagSheetNavigation.filtered(all, query: "tay")

        XCTAssertEqual(hits.map(\.token), ["Taylor Fagins"])
    }

    func testMatchingIgnoresCase() {
        let all = suggestions(["Safa", "Taylor Fagins"])

        XCTAssertEqual(
            PhotoTagSheetNavigation.filtered(all, query: "SAFA").map(\.token), ["Safa"])
    }

    func testASurnameMatchesToo() {
        // The prose and Dan both routinely reach for a surname alone.
        let all = suggestions(["Taylor Fagins", "Alex Manuel"])

        XCTAssertEqual(
            PhotoTagSheetNavigation.filtered(all, query: "fagins").map(\.token),
            ["Taylor Fagins"])
    }

    func testAHandleIsMatchedWithoutTypingTheAtSign() {
        let all = suggestions(["@safa.wav", "@rowanmercer"])

        XCTAssertEqual(
            PhotoTagSheetNavigation.filtered(all, query: "safa").map(\.token), ["@safa.wav"])
    }

    func testNoMatchReturnsNothingRatherThanEverything() {
        // Falling back to the full list on no match would make the filter look
        // broken exactly when it is working.
        let all = suggestions(["Safa", "Taylor Fagins"])

        XCTAssertTrue(PhotoTagSheetNavigation.filtered(all, query: "zzz").isEmpty)
    }

    func testWhitespaceOnlyCountsAsNoQuery() {
        let all = suggestions(["Safa", "Taylor Fagins"])

        XCTAssertEqual(PhotoTagSheetNavigation.filtered(all, query: "   ").count, 2)
    }

    func testTheOriginalOrderIsKept() {
        // Performers seen in this day's photos are listed first by the caller,
        // and filtering must not reshuffle that.
        let all = suggestions(["Safa Adams", "Ben Brook", "Sasha Cole"])

        XCTAssertEqual(
            PhotoTagSheetNavigation.filtered(all, query: "sa").map(\.token),
            ["Safa Adams", "Sasha Cole"])
    }
}
