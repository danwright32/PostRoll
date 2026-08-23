import AppKit
import XCTest

/// Something that can actually RUN the app entry point (#849).
///
/// `PostRollApp.swift` is excluded from `PostRollTests` on purpose and for a
/// good reason: a test bundle is loaded into a host that already has an entry
/// point and must not carry a second. So nothing in the unit suite can run it,
/// and the only cover it had was guards that match its TEXT.
///
/// That is exactly where #842 hid. Every unit test passed while one
/// `postroll://` link left an extra window behind and put a duplicate New Event
/// sheet on each one, because the defect lived in which scene type the app
/// declares and in how many windows exist, and a text match cannot see either.
/// It was found by installing the build and counting windows by hand.
///
/// A deliberate exemption with no reviewer named in the same change has no
/// reviewer at all (L129), and that exemption is right, so the gap was invisible
/// precisely because the decision was correct. This target is the reviewer.
///
/// It does NOT run on pull requests. UI tests are slow and flaky by nature, and
/// the macOS runner already carries about eleven minutes of work; see
/// `.github/workflows/ui.yml` for what does trigger it.
final class AppEntryPointUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - One launch for the whole class (#864)

    /// Launching costs about 42 seconds and testing costs almost none of it.
    ///
    /// Measured on the runner on 2026-08-23, from a run of this file as it
    /// stood: 43.6 seconds for the first test and 41.1 seconds for the second,
    /// of the SAME binary built by the same job. So the cost is per LAUNCH, not
    /// per build, and #864's first suggestion, a single warm-up launch before
    /// the suite, would have paid it once and then paid it again for every test
    /// anyway. That direction is dead, and it was the plausible one.
    ///
    /// What is left is the other direction in the same issue: share one app
    /// where the tests do not need a fresh one. Neither of these does. Both only
    /// READ, one the accessibility tree's window count and one the operating
    /// system's list of running processes, and neither clicks, types or closes
    /// anything, so the second inherits exactly the state the first found.
    ///
    /// A test that DOES need a cold start must say so and launch its own, and
    /// `TestTargetHygieneTests` holds this file to launching once so that adding
    /// one is a decision somebody takes rather than a cost that creeps back.
    private static var sharedLaunch: Result<XCUIApplication, Error>?

    private static let dataRoot = LaunchedApp.scratchRoot("entry-point")

    /// The app, launched once and given long enough to draw.
    ///
    /// Every assertion below is about the running application, so a launch that
    /// did not happen has to fail here rather than leaving the assertions to
    /// report about nothing (L98). The failure is REMEMBERED rather than
    /// retried, so a launch that cannot work fails both tests with the same
    /// reason instead of costing another 42 seconds to fail again.
    private func launched() throws -> XCUIApplication {
        if Self.sharedLaunch == nil {
            Self.sharedLaunch = Result { try LaunchedApp.launch(dataRoot: Self.dataRoot) }
        }
        return try XCTUnwrap(Self.sharedLaunch,
                             "the shared launch was never attempted").get()
    }

    /// Ends the app once the whole class is done, not once per test.
    ///
    /// Per test was what made the second launch necessary. It is still ended:
    /// since #847 PostRoll does not quit when its window closes, so a copy left
    /// behind outlives the run that made it and the next launch lands on top of
    /// it.
    override class func tearDown() {
        LaunchedApp.terminateEveryCopy()
        try? FileManager.default.removeItem(at: dataRoot)
        sharedLaunch = nil
        super.tearDown()
    }

    // MARK: - The app under test is the one built from this checkout

    func testTheAppUnderTestIsTheOneThisRunBuilt() throws {
        // Fourteen PostRoll.app bundles have been registered with macOS on the
        // development machine and four of them still exist, so "a PostRoll
        // launched" is not the same statement as "the PostRoll this run built
        // launched". The answer is taken from the operating system's record of
        // what is running rather than from anything this test asked for, so the
        // two sides of the check do not come from one lookup (L70).
        _ = try launched()

        // The products folder this run built into, taken from the RUNNER app
        // this code is executing inside. In a UI test `Bundle.main` is
        // PostRollUITests-Runner.app, which xcodebuild puts beside PostRoll.app,
        // so its parent is the folder both were built into.
        //
        // Not `Bundle(for: type(of: self))`, which was tried first and is
        // wrong: the test bundle is nested at
        // PostRollUITests-Runner.app/Contents/PlugIns, three levels down, and
        // comparing against that folder failed while the app was in exactly the
        // right place. Measured on the runner on 2026-08-23.
        let runner = Bundle.main.bundleURL
        XCTAssertEqual(runner.pathExtension, "app",
                       "the test runner is not an app bundle at \(runner.path), "
                       + "so the folder derived from it is not the products "
                       + "folder and the comparison below means nothing")
        let products = runner.deletingLastPathComponent()

        let copies = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.dwphotony.PostRoll"
        }
        let paths = copies.map { $0.bundleURL?.path ?? "(no bundle)" }

        // Exactly one, before asking where it is. Two copies answering to one
        // bundle identifier is the situation where every later check agrees
        // with itself and is still about the wrong process, and it is the
        // situation this machine is actually in.
        XCTAssertEqual(copies.count, 1,
                       "\(copies.count) copies of PostRoll are running, so which "
                       + "one the assertions below are about is undecided: "
                       + "\(paths)")

        let bundle = try XCTUnwrap(copies.first?.bundleURL,
                                   "the running PostRoll has no bundle at all")
        XCTAssertEqual(bundle.deletingLastPathComponent().standardizedFileURL.path,
                       products.standardizedFileURL.path,
                       "the app under test is \(bundle.path), which is not the "
                       + "one this run built in \(products.path). Every "
                       + "assertion in this target would be about a copy of "
                       + "PostRoll that nobody here made")
    }

    // MARK: - One window (#842)

    func testTheAppOpensExactlyOneWindow() throws {
        // The #842 defect in one assertion. PostRoll was a `WindowGroup`, which
        // SwiftUI answers an incoming URL open event from by opening a NEW
        // window: one window, two after a link, three after a quit and another
        // link, since window restoration brings the extras back. The cost was
        // not the clutter. Which sheet is showing is one piece of shared state
        // and every window bound to it, so a single link put a New Event sheet
        // on all of them and cancelling one left the others standing.
        //
        // No unit test could see this, and no text guard could either: the
        // defect was the scene TYPE and the window COUNT.
        let app = try launched()

        let windows = app.windows.count
        XCTAssertEqual(windows, 1,
                       "PostRoll opened \(windows) windows rather than one. "
                       + "What the accessibility tree holds:\n"
                       + app.debugDescription)
    }
}
