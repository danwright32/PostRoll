import AppKit
import XCTest

/// One way to launch PostRoll for a UI test, pointed away from real data.
///
/// A UI test launches the SHIPPING app, which resolves its own data location,
/// so without this every run reads and writes the events.json belonging to
/// whoever is running it. On a fresh CI runner that is harmless and invisible,
/// which is exactly what makes it dangerous: the first person to run the GUI
/// suite on the development Mac would have had a test create events in the real
/// library, and #848 is a test whose whole purpose is to press Return and see
/// whether an event was created.
///
/// `POSTROLL_DATA_DIR` is honoured by `AppPaths.resolveRoot` before anything
/// else and unconditionally, so a launch through here is structurally unable to
/// reach live data (L2). It is set here rather than remembered per test,
/// because a rule that has to be repeated at every call site is one that will
/// be missed at the call site that matters.
enum LaunchedApp {

    /// The bundle identifier every copy of PostRoll shares. Named once here so
    /// the checks below cannot end up asking about two different spellings.
    static let bundleID = "com.dwphotony.PostRoll"

    /// A scratch data root for one test, and the app pointed at it.
    ///
    /// The folder is created rather than merely named, because the app treats a
    /// missing root and an empty one differently and only one of those is the
    /// state a test means to be in.
    @discardableResult
    static func launch(dataRoot: URL,
                       projectRoot: URL? = nil,
                       file: StaticString = #filePath,
                       line: UInt = #line) throws -> XCUIApplication {
        try FileManager.default.createDirectory(at: dataRoot,
                                                withIntermediateDirectories: true)

        // Deliberately NOT terminating any running copy here first.
        //
        // That was tried, because since #847 PostRoll no longer quits when its
        // last window closes and a windowless copy can outlive the test that
        // left it. It made things worse: `XCUIApplication.launch()` already
        // terminates a running instance, and racing it with a second
        // termination produced launches with no window at all and copies that
        // "would not die". Ending the app is teardown's job, where nothing is
        // waiting on the result.
        let app = XCUIApplication()
        app.launchEnvironment["POSTROLL_DATA_DIR"] = dataRoot.path
        if let projectRoot {
            app.launchEnvironment["POSTROLL_PROJECT_DIR"] = projectRoot.path
        }
        app.launch()

        // 120s, not 30. The FIRST launch of a session, straight after a build,
        // was measured at over 41 seconds on this machine while every later one
        // in the same run took about two: the cold cost is signature checking
        // and first-run work, and it lands entirely on whichever test happens to
        // run first. A 30 second limit failed that test and nothing else, which
        // reads as "the app is broken" rather than "the clock was too tight"
        // (L224: a fixed number measures what else the machine is doing).
        // Brought to the front deliberately. A launch alone leaves PostRoll
        // behind whatever else is on screen, and its window CONTENTS are then
        // not exposed: the accessibility tree comes back with a menu bar, the
        // application marked Disabled, and no window at all, so every query for
        // a control inside it finds nothing and reads as the control missing.
        //
        // Measured while building #848: the test that fired a postroll:// link
        // could read the form, and the one that only launched could not. Opening
        // a URL activates the app, which was the whole of the difference.
        app.activate()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 120),
                      "PostRoll did not reach the foreground, so nothing after "
                      + "this is about a running app. State: \(app.state.rawValue)",
                      file: file, line: line)
        return app
    }

    /// End every running copy and wait until none are left.
    ///
    /// Polite first, then forced. `terminate()` is a request an app may decline
    /// or simply be slow to honour, and one with a menu open has been seen to
    /// take long enough that the next launch landed on top of it. A wait that
    /// gives up quietly would leave the very state this exists to prevent, so it
    /// fails rather than returning (L98).
    /// Best effort, and deliberately silent about what it could not end.
    ///
    /// This runs in teardown, where a failure reports against the test that just
    /// finished and hides whatever that test actually found. A copy that will
    /// not die is a problem for the NEXT launch, and that launch says so itself.
    static func terminateEveryCopy(within seconds: TimeInterval = 15) {
        for copy in runningCopies { copy.terminate() }

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !runningCopies.isEmpty {
            usleep(200_000)
        }
        if !runningCopies.isEmpty {
            for copy in runningCopies { copy.forceTerminate() }
            let forced = Date().addingTimeInterval(5)
            while Date() < forced, !runningCopies.isEmpty {
                usleep(200_000)
            }
        }
    }

    /// A scratch folder under the system temporary directory, unique per call.
    static func scratchRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PostRollUI-\(label)-\(UUID().uuidString)")
    }

    /// Every running copy of PostRoll, according to the operating system.
    ///
    /// Asked of the OS rather than of the thing that launched it, so the two
    /// sides of any check built on this do not come from one lookup (L70).
    static var runningCopies: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
    }

    /// The one running copy, refusing when there is not exactly one.
    ///
    /// Fourteen PostRoll.app bundles have been registered with macOS on the
    /// development machine and several still exist, so "a PostRoll is running"
    /// is not the same statement as "the PostRoll under test is running". Two
    /// copies is the situation where every later check agrees with itself and
    /// is still about the wrong process.
    static func theRunningCopy(file: StaticString = #filePath,
                               line: UInt = #line) throws -> NSRunningApplication {
        let copies = runningCopies
        let paths = copies.map { $0.bundleURL?.path ?? "(no bundle)" }
        XCTAssertEqual(copies.count, 1,
                       "\(copies.count) copies of PostRoll are running, so which "
                       + "one this is about is undecided: \(paths)",
                       file: file, line: line)
        return try XCTUnwrap(copies.first, "no PostRoll is running at all",
                             file: file, line: line)
    }
}
