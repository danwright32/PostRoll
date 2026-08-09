import XCTest

/// #101: after the data root moved to Application Support, four user-facing
/// strings still told Dan to check ~/Documents/PostRoll/logs. He would open a
/// folder with nothing in it and conclude the app had logged nothing, which is
/// the worst possible answer for a message whose entire job is "here is where
/// to look when this keeps failing".
///
/// The path is derived from AppPaths now, so it cannot drift from the real one
/// a second time.
///
/// These assert the DERIVATION, never that the path is not in Documents. An
/// earlier version asserted the latter and failed in CI, correctly: AppPaths'
/// root is gated on a migration marker, so on a machine that has not migrated
/// the logs genuinely are in Documents and naming it is the right answer. The
/// assertion had encoded one developer machine's state as a universal truth.
final class LogPathMessagingTests: XCTestCase {

    func testTheDisplayPathPointsAtTheRealLogsFolder() {
        let shown = AppPaths.logsDirDisplayPath
        let real = (AppPaths.logsDir.path as NSString).abbreviatingWithTildeInPath
        XCTAssertEqual(shown, real)
    }

    func testTheDisplayPathFollowsTheRootWhereverItIs() {
        // The property that matters and holds on every machine: the string
        // tracks the real root, migrated or not. A hardcoded literal would
        // stop matching the moment the root differs from it.
        XCTAssertTrue(AppPaths.logsDirDisplayPath.hasSuffix("PostRoll/logs"),
                      AppPaths.logsDirDisplayPath)
        XCTAssertTrue(AppPaths.logsDir.path.hasSuffix(
            AppPaths.logsDirDisplayPath.replacingOccurrences(of: "~", with: "")))
    }

    func testTheDisplayPathIsAbbreviatedRatherThanTheFullHomePath() {
        // "~/Library/..." is readable in a one-line error; the full
        // /Users/<name>/... is not.
        XCTAssertTrue(AppPaths.logsDirDisplayPath.hasPrefix("~/"),
                      AppPaths.logsDirDisplayPath)
    }

    func testUnreadableOutputPointsAtTheRealLogsFolder() {
        let message = PythonBridgeError.invalidOutput("boom").errorDescription ?? ""
        XCTAssertTrue(message.contains(AppPaths.logsDirDisplayPath), message)
    }

    func testAnUnrecognisedFailurePointsAtTheRealLogsFolder() {
        // Falls through humanise() to the generic branch, which is the one
        // carrying the log hint.
        let message = PythonBridgeError
            .scriptFailed(exitCode: 1, stderr: "something nobody has classified")
            .errorDescription ?? ""
        XCTAssertTrue(message.contains(AppPaths.logsDirDisplayPath), message)
    }

    func testAClassifiedFailureStillGetsItsOwnMessage() {
        // The log hint must not have displaced the specific diagnoses: a
        // distinct cause keeps its distinct message.
        let message = PythonBridgeError
            .scriptFailed(exitCode: 1, stderr: "ffmpeg: command not found")
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("brew install ffmpeg"), message)
    }
}
