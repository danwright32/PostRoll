import XCTest

/// Waving the code folder notice away, and what brings it back (#696).
///
/// The notice is deliberately persistent, and the verdict is recomputed from a
/// fresh git reading on every activation (#668), so a dismissal that only
/// cleared the sentence would be undone by the next reading: the banner would
/// return every time Dan came back from the terminal, which is precisely how a
/// warning becomes something to click away on reflex (L36).
///
/// So a dismissal is recorded against the STATE it was given for, the same
/// shape the out of date sheet already uses. A different branch, or the folder
/// becoming dirty, is a different thing to say and has not been dismissed.
///
/// Both halves are needed and they fail in opposite directions: the first test
/// alone is satisfied by a dismissal that hides the notice forever, and the
/// second alone by one that does not work at all.
@MainActor
final class CheckoutNoticeDismissalTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CheckoutDismiss-\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func state() -> AppState {
        AppState(events: [],
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    private func onBranch(_ branch: String, dirty: Bool = false,
                          commit: String = "1a2b3c4") -> CheckoutRevision.Reading {
        .known(commit: commit, branch: branch, dirty: dirty)
    }

    // MARK: - It stays away for the state it was dismissed for

    func testTheNoticeStaysHiddenWhileTheCheckoutIsAsItWas() {
        let state = state()
        state.apply(onBranch("wip/fonts"))
        XCTAssertNotNil(state.checkoutNotice, "the fixture did not take")

        state.dismissCheckoutNotice()
        state.apply(onBranch("wip/fonts"))

        XCTAssertNil(state.checkoutNotice,
                     "the notice came back on the next reading of the same "
                     + "checkout, so coming back from the terminal puts it "
                     + "straight in front of Dan again")
    }

    func testANewCommitOnTheSameBranchIsNotANewThingToSay() {
        // Committing is what he is doing on that branch. If every commit
        // resurrected the banner, dismissing it would mean nothing.
        let state = state()
        state.apply(onBranch("wip/fonts", commit: "1111111"))
        state.dismissCheckoutNotice()

        state.apply(onBranch("wip/fonts", commit: "2222222"))

        XCTAssertNil(state.checkoutNotice)
    }

    // MARK: - It comes back when the state changes

    func testAnotherBranchIsANewThingToSay() throws {
        let state = state()
        state.apply(onBranch("wip/fonts"))
        state.dismissCheckoutNotice()

        state.apply(onBranch("wip/collage"))

        let notice = try XCTUnwrap(state.checkoutNotice,
                                   "switching branch says nothing, so the "
                                   + "dismissal silenced every later state too")
        XCTAssertTrue(notice.contains("wip/collage"), notice)
    }

    func testTheFolderBecomingDirtyIsANewThingToSay() {
        let state = state()
        state.apply(onBranch("wip/fonts", dirty: false))
        state.dismissCheckoutNotice()

        state.apply(onBranch("wip/fonts", dirty: true))

        XCTAssertNotNil(state.checkoutNotice,
                        "unsaved changes appeared and the banner stayed hidden")
    }

    func testLeavingABranchAltogetherIsANewThingToSay() {
        let state = state()
        state.apply(onBranch("wip/fonts"))
        state.dismissCheckoutNotice()

        state.apply(onBranch(CheckoutRevision.detachedBranch))

        XCTAssertNotNil(state.checkoutNotice)
    }

    func testGoingBackToACleanMainAndAwayAgainReArmsIt() {
        // Dismissing says "not now" about one state, not "never again". The
        // episode ends when there is nothing to say, so the next time the
        // checkout moves it is news again.
        let state = state()
        state.apply(onBranch("wip/fonts"))
        state.dismissCheckoutNotice()

        state.apply(onBranch("main"))          // nothing to say
        XCTAssertNil(state.checkoutNotice)
        state.apply(onBranch("wip/fonts"))     // the same branch again, later

        XCTAssertNotNil(state.checkoutNotice,
                        "the checkout went back to clean and off again in one "
                        + "session and said nothing the second time")
    }

    // MARK: - What it must not touch

    func testDismissingTheNoticeLeavesTheSaveFailureBannerAlone() {
        // The save failure banner is undismissable on purpose: it says the work
        // on screen exists nowhere else, and it clears itself when a save
        // succeeds. One dismissal must not reach it.
        let state = state()
        state.apply(onBranch("wip/fonts"))
        state.saveFailure = "Could not save"

        state.dismissCheckoutNotice()

        XCTAssertEqual(state.saveFailure, "Could not save")
    }

    // MARK: - Wired into the window

    func testTheBannerCarriesTheControlThatDismissesIt() throws {
        // A control that exists in the state layer and nowhere on screen is a
        // dismissal Dan cannot perform (L3).
        let code = try MainWindowSource.stripped()
        let strip = try XCTUnwrap(
            MainWindowSource.block(openedBy: ".bottomBanners", in: code),
            "the window has no banner strip, so this guard has nothing to read")
        let flattened = MainWindowSource.flattened(strip)

        XCTAssertTrue(flattened.contains("dismissCheckoutNotice"),
                      "nothing in the banner strip dismisses the notice: \(flattened)")
        XCTAssertTrue(flattened.contains("CheckoutNotice.dismissLabel"),
                      "the dismiss control has no label from the one place that "
                      + "spells it, so the button and its test can disagree")
    }

    func testTheSaveFailureBannerHasNoDismissControl() throws {
        // The control for the guard above: a check that something dismissable
        // exists would be satisfied by making everything dismissable, including
        // the one banner that must not be (L159).
        let code = try MainWindowSource.stripped()
        let strip = try XCTUnwrap(
            MainWindowSource.block(openedBy: ".bottomBanners", in: code))
        let failureBlock = try XCTUnwrap(
            MainWindowSource.block(openedBy: "if let failure = appState.saveFailure",
                                   in: strip),
            "the save failure banner is no longer drawn in the strip")

        XCTAssertFalse(failureBlock.contains("dismiss"),
                       "the save failure banner can be waved away, and it is the "
                       + "one saying the work on screen exists nowhere else")
    }
}
