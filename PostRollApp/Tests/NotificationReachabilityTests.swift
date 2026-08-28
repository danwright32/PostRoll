import XCTest
import UserNotifications

/// Whether a banner can arrive at all, and whether anybody is told when it
/// cannot (#893, #894, #895).
///
/// These three are one surface. Every notification PostRoll sends exists for
/// the case where Dan is not looking at the app, so each way the surface can
/// fail is a feature that fails only in the situation it was built for, and
/// says nothing while it does.
final class NotificationReachabilityTests: XCTestCase {

    // MARK: - #893 asked once the app is up

    /// `requestPermission()` was called from `PostRollApp.init()`, which runs
    /// before the app has finished launching. On the development machine on
    /// 2026-08-24 PostRoll had no entry in macOS Notification settings and no
    /// delivered notification on record, which is what a request that never
    /// completed looks like from outside.
    ///
    /// Driven through a seam rather than by calling the real thing:
    /// `UNUserNotificationCenter` raises rather than failing when there is no
    /// real app around it (#707), so a test that called it would report the
    /// harness rather than the app.
    @MainActor
    func testTheAppAsksOnceItHasFinishedLaunching() {
        let delegate = DeepLinkDelegate()
        let counter = AskCounter()
        delegate.askForNotificationPermission = { counter.times += 1 }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(counter.times, 1,
                       "nothing asks for permission once the app is up, so the "
                       + "request only ever happens where it was suspected of "
                       + "never completing")
    }

    /// A box for the count, so the closure captures a reference rather than a
    /// local: a captured `var` is what Swift 6 refuses to send into a
    /// non-isolated closure.
    @MainActor private final class AskCounter { var times = 0 }

    // That the default is the REAL request, rather than a seam left unwired, is
    // asserted in `tests/test_permission_is_asked_after_launch.py`. It cannot
    // be asserted here: calling the default reaches UNUserNotificationCenter,
    // which raises rather than failing with no real app around it (#707), and
    // the test that stood here checked a non-optional closure was not nil,
    // which is true of every closure ever written (L1).

    // MARK: - #894 the window says when nothing can arrive

    func testNothingIsSaidBeforeTheAppHasAsked() {
        XCTAssertNil(NotificationNotice.message(permission: .notAsked, hasAsked: false),
                     "the state at launch is not a verdict, and a banner on "
                     + "every launch is the false alarm that teaches somebody "
                     + "to ignore this one")
    }

    func testARequestThatNeverCameBackIsSaid() {
        XCTAssertNotNil(NotificationNotice.message(permission: .notAsked, hasAsked: true),
                        "the app asked and never heard, which is the reported "
                        + "symptom itself, and it read as an ordinary launch")
    }

    func testARefusalIsSaidAndNamesTheRemedy() throws {
        let message = try XCTUnwrap(
            NotificationNotice.message(permission: .refused, hasAsked: true))

        XCTAssertTrue(message.contains("System Settings"), message)
        XCTAssertEqual(message.first, "N",
                       "the sentence is written to follow a log prefix, so it "
                       + "starts mid sentence unless the window capitalises it")
    }

    func testAFailedRequestSaysSoInItsOwnWords() throws {
        let message = try XCTUnwrap(
            NotificationNotice.message(permission: .failed("no bundle"), hasAsked: true))

        XCTAssertTrue(message.contains("no bundle"), message)
        XCTAssertFalse(message.contains("Turn PostRoll on"),
                       "a request that FAILED is not a refusal, and sending "
                       + "somebody to a switch that is not the problem is a "
                       + "remedy that cannot work (L11, L111). The sentence "
                       + "may NAME System Settings, and does, to say that is "
                       + "not where this one shows up.")
    }

    func testAWorkingAppSaysNothing() {
        XCTAssertNil(NotificationNotice.message(permission: .granted, hasAsked: true))
    }

    // MARK: - #895 a finished run banners while PostRoll is in front

    /// Dan, 2026-08-27, choosing between this and the failure rule: completions
    /// keep bannering while PostRoll is frontmost, and the difference from
    /// `notifyWorkFailed` gets written down rather than quietly evened out.
    ///
    /// The reasoning, recorded because it is not obvious from either side: a
    /// failure is already on the screen he is looking at, so a banner over it
    /// is noise. A completion is news he may want while looking at a different
    /// part of the app, and the Export page cannot show that Thursday finished
    /// while he is on Sunday.
    func testAFinishedRunIsShownEvenWhilePostRollIsInFront() {
        XCTAssertTrue(
            NotificationService.presentationWhileActive.contains(.banner),
            "a completion is silent while PostRoll is in front, which is the "
            + "failure rule rather than the one that was chosen")
    }
}
