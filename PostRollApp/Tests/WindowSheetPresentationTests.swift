import XCTest

/// One presenter for the window's sheets, so a collision is a decision (#846).
///
/// `MainWindowView` bound three separate `.sheet` modifiers to the same view:
/// the New Event form, the outdated designs list and the build behind warning.
/// SwiftUI presents at most one sheet per view, so when two were asked for at
/// once one of them silently did nothing, and nothing said which.
///
/// That was survivable while all three were things Dan opened himself, because
/// he could only ask for one at a time. #840 ended that: a `postroll://` link
/// can raise the New Event form at any moment, including while the build behind
/// warning is up. Both losers are bad in different ways. A swallowed form is a
/// link that appears to do nothing. A swallowed warning is the notice that
/// exists to stop a shipped fix looking like it never worked (#675), cleared by
/// an unrelated click.
///
/// The rule these tests hold the window to: what DAN asks for wins the screen,
/// and what a background check asks for waits its turn rather than being
/// thrown away. Nothing is ever silently dropped.
final class WindowSheetPresentationTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("WindowSheetPresentation-\(UUID().uuidString)")

    private let repo = URL(fileURLWithPath: "/tmp/PostRollWindowSheetPresentation")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func state() -> AppState {
        AppState(events: [],
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    private func draft(name: String) -> DeepLink.EventDraft {
        DeepLink.EventDraft(name: name, org: "Org", venue: "Venue",
                            venueContext: "Hall", date: Date(timeIntervalSince1970: 1),
                            bookingID: UUID())
    }

    private func behind(latestCommit: TimeInterval = 2_000) -> BuildFreshness.Verdict {
        .behind(builtAt: Date(timeIntervalSince1970: 1_000),
                latestCommit: Date(timeIntervalSince1970: latestCommit),
                remedy: .rebuild)
    }

    // MARK: - Only ever one

    @MainActor
    func testAskingForTwoSheetsLeavesExactlyOneOnScreen() {
        // The defect in one line: two requests, and SwiftUI decided which
        // modifier to honour. Now the window decides, and it can only ever be
        // showing one.
        let state = state()

        state.present(behind(), forRepo: repo)
        state.presentNewEvent()

        XCTAssertEqual(state.presentedSheet?.kind, .newEvent,
                       "the form Dan's link asked for is not the sheet on screen")
        XCTAssertEqual(state.waitingSheets.count, 1,
                       "the window is showing or holding \(state.waitingSheets.count + 1) "
                       + "sheets when at most one can be on screen")
    }

    // MARK: - What Dan asks for wins the screen

    @MainActor
    func testALinkRaisesTheFormOverTheBuildBehindWarning() {
        // The observed case from the 2026-08-22 hands off probe: a sheet was
        // already up at launch, a link fired, and the form was what ended up on
        // screen with nothing saying what happened to the other one.
        let state = state()
        state.present(behind(), forRepo: repo)

        state.presentNewEvent(prefill: nil)

        XCTAssertEqual(state.presentedSheet?.kind, .newEvent,
                       "the link opened no sheet, so it looks like it did nothing")
    }

    @MainActor
    func testTheDisplacedWarningIsKeptRatherThanThrownAway() {
        // A swallowed build behind warning is the #675 notice quietly cleared
        // by an unrelated click. Displacing it must not be the same as
        // dismissing it.
        let state = state()
        state.present(behind(), forRepo: repo)

        state.presentNewEvent()

        XCTAssertEqual(state.waitingSheets.map(\.kind), [.buildBehind],
                       "the out of date warning was thrown away by a link that "
                       + "had nothing to do with it")
    }

    @MainActor
    func testDismissingTheFormPutsTheWaitingWarningBackOnScreen() {
        // Waiting is only worth anything if something brings it back.
        let state = state()
        state.present(behind(), forRepo: repo)
        state.presentNewEvent()

        state.dismissPresentedSheet()

        XCTAssertEqual(state.presentedSheet?.kind, .buildBehind,
                       "the warning waited and then never came back, which is "
                       + "the same silence as dropping it")
        XCTAssertTrue(state.waitingSheets.isEmpty,
                      "the warning is on screen and still queued as waiting")
    }

    @MainActor
    func testADisplacedWarningIsNotRecordedAsDismissed() {
        // Dismissing remembers the verdict so it is not put back on
        // every activation. Being pushed aside by a link is not Dan waving it
        // away, and recording it as such would silence the real warning for the
        // rest of its life.
        let state = state()
        state.present(behind(), forRepo: repo)
        state.presentNewEvent()
        state.dismissPresentedSheet()
        state.dismissPresentedSheet()

        // Same verdict, offered again the way an activation offers it.
        state.present(behind(), forRepo: repo)

        XCTAssertNil(state.presentedSheet,
                     "a verdict Dan actually dismissed came straight back")
    }

    @MainActor
    func testDismissingTheWarningThroughTheWindowRecordsIt() {
        // The route the window actually takes. Every sheet now leaves through
        // one dismissal, so the recording that stops a waved away verdict
        // coming back on the next activation has to happen there rather than in
        // a method only the old per sheet binding called.
        let state = state()
        state.present(behind(), forRepo: repo)

        state.dismissPresentedSheet()
        state.present(behind(), forRepo: repo)

        XCTAssertNil(state.presentedSheet,
                     "a verdict Dan waved away came back on the next reading of "
                     + "the code folder, which is once per activation")
    }

    // MARK: - A background check waits its turn

    @MainActor
    func testABuildBehindVerdictNeverInterruptsWhatDanIsDoing() {
        // The freshness check runs on its own, on every activation. Ripping a
        // half typed New Event form off the screen is not a thing a background
        // reading gets to do.
        let state = state()
        state.presentNewEvent()

        state.present(behind(), forRepo: repo)

        XCTAssertEqual(state.presentedSheet?.kind, .newEvent,
                       "a background reading took the form away mid sentence")
        XCTAssertEqual(state.waitingSheets.map(\.kind), [.buildBehind],
                       "the warning was dropped instead of waiting")
    }

    @MainActor
    func testASecondVerdictReplacesTheWaitingOneRatherThanQueueingBehindIt() {
        // Every activation offers a verdict. Queueing each one would leave Dan
        // dismissing the same warning once per click into the app.
        let state = state()
        state.presentNewEvent()

        state.present(behind(latestCommit: 2_000), forRepo: repo)
        state.present(behind(latestCommit: 3_000), forRepo: repo)

        XCTAssertEqual(state.waitingSheets.count, 1,
                       "\(state.waitingSheets.count) warnings are queued, so Dan "
                       + "has to dismiss the same notice once per activation")
    }

    @MainActor
    func testCatchingUpTakesTheWaitingWarningAway() {
        // A rebuild while the app is open is exactly what the sheet asked for.
        // A warning still waiting afterwards says the fix did not work.
        let state = state()
        state.presentNewEvent()
        state.present(behind(), forRepo: repo)

        state.present(.current, forRepo: repo)

        XCTAssertTrue(state.waitingSheets.isEmpty,
                      "the app caught up and the out of date warning is still "
                      + "queued to be shown")
    }

    @MainActor
    func testAVerdictThatCouldNotBeReachedLeavesTheWaitingWarningAlone() {
        // Nothing was compared, so it can neither raise a warning nor take one
        // away. Clearing on it would be a clean bill of health nobody measured.
        let state = state()
        state.presentNewEvent()
        state.present(behind(), forRepo: repo)

        state.present(.cannotTell(reason: "no checkout"), forRepo: repo)

        XCTAssertEqual(state.waitingSheets.map(\.kind), [.buildBehind],
                       "a reading that compared nothing was allowed to clear a "
                       + "warning that was measured")
    }

    // MARK: - The same sheet asked for twice

    @MainActor
    func testAskingForTheFormTwiceDoesNotQueueItBehindItself() {
        // Two links in a row, or Cmd+N over an open form. The second is the one
        // that should be showing, and there should be nothing behind it.
        let state = state()
        state.presentNewEvent()

        state.presentNewEvent()

        XCTAssertEqual(state.presentedSheet?.kind, .newEvent)
        XCTAssertTrue(state.waitingSheets.isEmpty,
                      "the form is queued behind itself, so dismissing it opens "
                      + "it again")
    }

    @MainActor
    func testTheSecondLinksValuesAreTheOnesTheFormOpensWith() {
        // Replacing has to mean replacing. A second link whose prefill never
        // reaches the form is a link that appears to do nothing.
        let state = state()
        let first = draft(name: "First")
        let second = draft(name: "Second")
        state.presentNewEvent(prefill: first)

        state.presentNewEvent(prefill: second)

        XCTAssertEqual(state.newEventPrefill?.bookingID, second.bookingID,
                       "the form opened with the previous link's values")
    }

    // MARK: - The menu sheet is in the same queue

    @MainActor
    func testTheOutdatedDesignsListAndTheFormCannotBothBeOnScreen() {
        // The third sheet is on the same view and has the same collision. A
        // link arriving while the list is open is the everyday version of it.
        let state = state()
        state.presentOutdatedDesigns()

        state.presentNewEvent()

        XCTAssertEqual(state.presentedSheet?.kind, .newEvent)
        XCTAssertEqual(state.waitingSheets.map(\.kind), [.outdatedDesigns],
                       "the list Dan opened from the menu vanished with no way back")
    }
}
