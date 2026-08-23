import XCTest

/// The code folder warning keeps up with the code folder (#856).
///
/// `checkTheCodeFolder` reported an unreachable checkout at launch and nothing
/// ever took that report away. So PostRoll could open while the folder was
/// missing, say so, have the folder put back while it sat there, and go on
/// saying something that had stopped being true for the rest of the session.
///
/// That is the case the notice exists for. The folder moving while PostRoll is
/// open is exactly what happens when a session moves the checkout in the
/// terminal, which is what #668 and #675 each fixed for their own notices, both
/// writing down the same reason: clearing is as much the job as setting, and a
/// warning still standing after the thing it asked for has been done says the
/// fix did not work.
///
/// The dismissal half is the same shape as the out of date sheet's. Asking again
/// on every activation means a warning Dan waved away would be put straight back
/// in front of him, which is how a warning becomes something to dismiss on
/// reflex, taking the real one with it (L36). So a verdict he has seen and waved
/// away stays away, a DIFFERENT verdict is new news, and the folder coming back
/// ends the episode and re-arms the whole thing.
final class ProjectRootRefreshTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProjectRootRefresh-\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func state() -> AppState {
        AppState(events: [],
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    private let checkout = URL(fileURLWithPath: "/tmp/PostRollProjectRootRefresh")

    // MARK: - A folder that came back

    @MainActor
    func testAFolderThatCameBackTakesTheWarningAway() {
        // The whole point. A reading that finds the checkout must be able to
        // take away a warning an earlier reading put up, or the notice is only
        // ever true of the folder as it was at launch.
        let state = state()
        state.applyProjectRoot(.unreachable(.missing(checkout)))
        XCTAssertNotNil(state.projectRootProblem, "the warning must appear first")

        state.applyProjectRoot(.ready(checkout))

        XCTAssertNil(state.projectRootProblem,
                     "the checkout came back and PostRoll went on saying it "
                     + "cannot generate anything")
    }

    @MainActor
    func testAFolderStillMissingKeepsTheWarningUp() {
        // The mirror. A rule only seen to take a warning away has not been shown
        // to leave one standing, and a check that clears unconditionally would
        // pass the test above while reporting a clean bill of health nobody
        // measured (L159, L98).
        let state = state()
        state.applyProjectRoot(.unreachable(.missing(checkout)))

        state.applyProjectRoot(.unreachable(.missing(checkout)))

        XCTAssertNotNil(state.projectRootProblem,
                        "the checkout is still missing and the warning about it "
                        + "is gone")
    }

    // MARK: - Waved away stays away

    @MainActor
    func testAWavedAwayWarningDoesNotComeBackOnTheNextReading() {
        // Asked on every activation, so without this every click into the app
        // puts the same alert back in front of him.
        let state = state()
        state.applyProjectRoot(.unreachable(.missing(checkout)))
        state.dismissPresentedAlert()

        state.applyProjectRoot(.unreachable(.missing(checkout)))

        XCTAssertNil(state.presentedAlert,
                     "a warning Dan waved away was put back the next time the "
                     + "folder was read, which is once per activation")
    }

    @MainActor
    func testADifferentProblemAfterADismissalIsSaidAgain() {
        // Dismissing says "not now" about one verdict, not "never again about
        // this folder". A checkout that is present but has no Python
        // environment is a different thing to say, and a different fix.
        let state = state()
        state.applyProjectRoot(.unreachable(.missing(checkout)))
        state.dismissPresentedAlert()

        state.applyProjectRoot(.unreachable(.notACheckout(checkout)))

        XCTAssertEqual(state.presentedAlert?.kind, .projectRoot,
                       "a second, different fault with the code folder was "
                       + "silenced by a dismissal of the first one")
    }

    @MainActor
    func testAFolderComingBackRearmsTheWarningForNextTime() {
        // Catching up ends the whole episode, so the next time the folder goes
        // it is news again even though it is the same words.
        let state = state()
        state.applyProjectRoot(.unreachable(.missing(checkout)))
        state.dismissPresentedAlert()

        state.applyProjectRoot(.ready(checkout))
        state.applyProjectRoot(.unreachable(.missing(checkout)))

        XCTAssertEqual(state.presentedAlert?.kind, .projectRoot,
                       "the folder went missing, came back and went again in "
                       + "one session, and PostRoll said nothing the second time")
    }

    // MARK: - Wired into the window

    func testTheWindowAsksAgainWhenTheAppComesForward() throws {
        // A rule nothing calls is worth nothing (L3). The reading that already
        // goes out on activation is where this belongs, rather than a second
        // reader of the same folder, which would be a second chance to read a
        // different one or to forget (#668).
        let code = try MainWindowSource.stripped()
        let onActive = try XCTUnwrap(
            MainWindowSource.block(openedBy: "didBecomeActiveNotification", in: code),
            "the window no longer does anything when the app comes forward, so "
            + "there is nothing here to check and this guard would otherwise "
            + "pass having read nothing")

        XCTAssertTrue(
            MainWindowSource.flattened(onActive).contains("applyProjectRoot"),
            "the window does not re-ask whether the code folder is reachable "
            + "when the app comes forward, so a folder put back while PostRoll "
            + "sits there leaves the warning standing: \(onActive)")
    }
}
