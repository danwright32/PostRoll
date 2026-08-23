import XCTest

/// One presenter for the window's alerts too (#846).
///
/// The three sheets were the observed defect. #846 also asked whether the three
/// alerts below them had the same shape, and they do: they are three separate
/// `.alert` modifiers on the same view, and two of the three are raised by
/// launch checks that both run every single launch. That the two can want the
/// screen at the same instant is what these tests measure, and it is measurable
/// here because it is a fact about the state rather than about SwiftUI.
///
/// What is deliberately NOT claimed here is which modifier SwiftUI would have
/// honoured. That needs a running window, and it does not need settling: one
/// presenter is right either way. Three alerts stacked on top of each other at
/// launch is not a better outcome than one, and with a presenter the order is a
/// decision written down rather than an accident of which modifier came last.
final class WindowAlertPresentationTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("WindowAlertPresentation-\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func state() -> AppState {
        AppState(events: [],
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    private let unreadableStore = "PostRoll could not read your events."

    // MARK: - Two launch checks, one screen

    @MainActor
    func testBothLaunchChecksCanWantTheScreenAtOnce() {
        // The reachability this rests on. `loadStore` runs as the state is
        // built and the code folder is read on the window's first `task`, so
        // both answers land within a launch and neither waits for the other.
        let state = state()

        state.reportProjectRootProblem(.notRecorded)
        state.reportStoreUnavailable(unreadableStore)

        XCTAssertNotNil(state.presentedAlert,
                        "two launch checks each asked for an alert and the "
                        + "window is showing neither")
        XCTAssertEqual(state.waitingAlerts.count, 1,
                       "one of the two launch answers was thrown away rather "
                       + "than shown after the other")
    }

    @MainActor
    func testTheRefusalToOpenTheStoreIsTheOneOnScreen() {
        // Order must not decide this. The events being unreachable is the one
        // that makes the app unusable, and it is the one that refuses to let
        // Dan carry on, so it wins the screen whichever check finished first.
        let state = state()

        state.reportProjectRootProblem(.notRecorded)
        state.reportStoreUnavailable(unreadableStore)

        XCTAssertEqual(state.presentedAlert?.kind, .storeUnavailable,
                       "Dan is looking at a notice about the code folder while "
                       + "the app cannot open his events at all")
    }

    @MainActor
    func testTheRefusalStillWinsWhenItIsAskedForFirst() {
        // The same assertion from the other side. A rule that only holds in the
        // order the fixture happens to use is not a rule (L159).
        let state = state()

        state.reportStoreUnavailable(unreadableStore)
        state.reportProjectRootProblem(.notRecorded)

        XCTAssertEqual(state.presentedAlert?.kind, .storeUnavailable)
        XCTAssertEqual(state.waitingAlerts.map(\.kind), [.projectRoot])
    }

    // MARK: - The refusal refuses

    @MainActor
    func testTheRefusalToOpenTheStoreCannotBeDismissed() {
        // Its binding has always ignored dismissal, and that is the whole point
        // of it: the events are still there, saving is refused, and letting Dan
        // past would leave him in an app that looks empty and quietly discards
        // what he types.
        let state = state()
        state.reportStoreUnavailable(unreadableStore)

        state.dismissPresentedAlert(.storeUnavailable)

        XCTAssertEqual(state.presentedAlert?.kind, .storeUnavailable,
                       "the refusal was waved away, so the app is now showing "
                       + "an empty library over events that are still on disk")
    }

    @MainActor
    func testNothingElseCanTakeTheScreenFromTheRefusal() {
        // A warning about the code folder must not push the refusal aside.
        let state = state()
        state.reportStoreUnavailable(unreadableStore)

        state.reportProjectRootProblem(.notRecorded)

        XCTAssertEqual(state.presentedAlert?.kind, .storeUnavailable)
    }

    @MainActor
    func testOpeningTheStoreShowsWhatWasWaitingBehindTheRefusal() {
        // Try Again succeeding is what ends the refusal, and the launch warning
        // queued behind it has not stopped being true.
        let state = state()
        state.reportProjectRootProblem(.notRecorded)
        state.reportStoreUnavailable(unreadableStore)

        state.clearStoreUnavailable()

        XCTAssertEqual(state.presentedAlert?.kind, .projectRoot,
                       "the store opened and the launch warning behind it was "
                       + "never shown, so it is silently gone")
    }

    // MARK: - The window is told WHICH alert, not just that there is one

    func testTheAlertIsPresentedWithTheValueItIsAbout() throws {
        // #855. The sheets above are keyed on identity: `.sheet(item:)` takes a
        // value, `WindowSheet.id` differs per case, so replacing one sheet with
        // another tells SwiftUI the content changed and it rebuilds.
        //
        // `.alert(_:isPresented:)` takes a Bool and carries no identity at all.
        // When the refusal to open the events displaces the code folder warning,
        // which is the case `ModalQueue` exists for and which happens at launch,
        // `isPresented` never leaves true, so nothing tells SwiftUI the content
        // changed and the previous alert's buttons can stay on screen under the
        // new one's title. Two halves of one screen disagreeing is worse than
        // either condition alone, because each half reads as correct.
        //
        // `presenting:` is the form built for this: the value reaches the
        // actions and the message, so they are rebuilt with it.
        //
        // Read from the ONE `.alert(` in the file rather than by searching the
        // whole of it, because a whole-file search for `presenting:` would be
        // answered by any occurrence anywhere (L135). That the file holds
        // exactly one is asserted first, so there is no second candidate for
        // the window below to be about, and a window that found nothing to read
        // fails rather than passing quietly (L98).
        let code = MainWindowSource.flattened(try MainWindowSource.stripped())

        let presenters = code.components(separatedBy: ".alert(").count - 1
        XCTAssertEqual(presenters, 1,
                       "MainWindowView presents \(presenters) alerts. One is the "
                       + "whole point of #846, and zero means this guard is "
                       + "reading nothing at all")

        let opening = String(code.components(separatedBy: ".alert(")[1].prefix(300))
        XCTAssertTrue(opening.contains("isPresented:"),
                      "the alert is not presented from the window's alert state "
                      + "at all: \(opening)")
        XCTAssertTrue(
            opening.contains("presenting:"),
            "the window's alert is presented from a flag alone, so swapping one "
            + "alert for another while one is on screen leaves the previous "
            + "one's buttons and message under the new one's title (#855). "
            + "What it says instead: \(opening)")
    }

    // MARK: - Waving one away shows the next

    @MainActor
    func testWavingAwayOneLaunchWarningShowsTheOther() {
        let state = state()
        state.reportProjectRootProblem(.notRecorded)
        state.reportDataLoadWarning("The saved events were unreadable.")

        state.dismissPresentedAlert(.projectRoot)

        XCTAssertNotNil(state.presentedAlert,
                        "dismissing the first alert took the second one with it")
        XCTAssertTrue(state.waitingAlerts.isEmpty)
    }

    @MainActor
    func testTheSameCheckAskingTwiceDoesNotQueueBehindItself() {
        // The code folder is read again on every activation, so this answer
        // arrives over and over. Queueing each one would leave Dan dismissing
        // the same notice once per click into the app (L36).
        let state = state()

        state.reportProjectRootProblem(.notRecorded)
        state.reportProjectRootProblem(.notACheckout(URL(fileURLWithPath: "/tmp/x")))

        XCTAssertEqual(state.presentedAlert?.kind, .projectRoot)
        XCTAssertTrue(state.waitingAlerts.isEmpty,
                      "\(state.waitingAlerts.count) copies of the same launch "
                      + "warning are queued behind the one on screen")
    }

    // MARK: - A dismissal belongs to the alert it was about

    /// #855, measured on the real app.
    ///
    /// Reproduction: make `events.json` unreadable and point the code folder
    /// somewhere that is not a checkout. Both launch checks fire, the refusal to
    /// open the events wins the screen and the code folder warning waits behind
    /// it. Fix the permissions, press Try Again, and the refusal clears with no
    /// alert appearing at all. Dan fixes one fault and never learns about the
    /// other.
    ///
    /// The cause is not that SwiftUI failed to redraw, which is what the issue
    /// first assumed. It is that ONE button press makes TWO changes: the
    /// button's own action opens the store, which promotes the code folder
    /// warning onto the screen, and then SwiftUI reports the alert it just tore
    /// down by writing `isPresented` false. That write was a decision about the
    /// refusal. It arrives addressed to nothing, so it lands on whatever is
    /// presented NOW, which is the alert nobody has seen yet (L166).
    ///
    /// So a dismissal names the alert it is about, and one for an alert that has
    /// already left the screen does nothing.
    @MainActor
    func testRecoveringFromTheRefusalDoesNotWaveAwayWhatWasBehindIt() {
        let state = state()
        state.reportProjectRootProblem(.notRecorded)
        state.reportStoreUnavailable(unreadableStore)

        // The button's action. The store opened, so the refusal is withdrawn and
        // the code folder warning behind it takes the screen.
        state.clearStoreUnavailable()
        // SwiftUI, reporting the alert it tore down when the button was pressed.
        state.dismissPresentedAlert(.storeUnavailable)

        XCTAssertEqual(state.presentedAlert?.kind, .projectRoot,
                       "pressing Try Again cleared the refusal AND took the "
                       + "code folder warning queued behind it, so Dan fixed "
                       + "one fault and was never told about the other")
    }

    /// The second half of the same defect, and the worse half.
    ///
    /// `dismissPresentedAlert` records what it took away, so that a warning Dan
    /// waved away is not put back on the next activation. A dismissal landing on
    /// the wrong alert therefore does not merely hide it once: it writes down
    /// that he waved away a warning he was never shown, and the check that runs
    /// on every activation then refuses to raise it for the rest of the session.
    @MainActor
    func testTheWarningNobodySawIsNotRecordedAsWavedAway() {
        let state = state()
        state.reportProjectRootProblem(.notRecorded)
        state.reportStoreUnavailable(unreadableStore)

        state.clearStoreUnavailable()
        state.dismissPresentedAlert(.storeUnavailable)
        // Every activation reads the code folder again and reports what it finds.
        state.applyProjectRoot(.unreachable(.notRecorded))

        XCTAssertEqual(state.presentedAlert?.kind, .projectRoot,
                       "the code folder warning was recorded as waved away by a "
                       + "dismissal meant for the refusal, so it stayed silent "
                       + "for the rest of the session")
    }

    /// The guard must not swallow the ordinary case it sits in front of.
    @MainActor
    func testADismissalForTheAlertOnScreenStillTakesItAway() {
        let state = state()
        state.reportDataLoadWarning("The saved events were unreadable.")

        state.dismissPresentedAlert(.dataLoad)

        XCTAssertNil(state.presentedAlert,
                     "the alert on screen was named in its own dismissal and "
                     + "stayed up anyway")
    }
}
