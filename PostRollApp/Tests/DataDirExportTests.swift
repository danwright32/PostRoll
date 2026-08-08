import XCTest

/// Python has no way to find the app's data root on its own. `AppPaths` picks
/// between Documents and Application Support behind a migration marker, and
/// nothing in the Python package can reproduce that decision.
///
/// So the app exports it. Without this the AI usage log (#207) lands wherever
/// Python's own fallback guesses, which on a pre-migration Mac is a different
/// folder from the one holding the rest of the app's data, and the spend
/// figure the app reads back would be missing every call.
final class DataDirExportTests: XCTestCase {

    func testTheExportNamesTheResolvedDataRoot() {
        let root = URL(fileURLWithPath: "/tmp/PostRollTestRoot", isDirectory: true)

        let line = PythonBridge.dataDirExport(root)

        XCTAssertTrue(line.contains("POSTROLL_DATA_DIR"))
        XCTAssertTrue(line.contains("/tmp/PostRollTestRoot"),
                      "Python would fall back to a different folder than the app uses")
    }

    func testAPathWithASingleQuoteCannotBreakOutOfTheScript() {
        // The export is interpolated into a shell script handed to zsh, so an
        // apostrophe in a home folder name (Dan's Mac, O'Brien) would otherwise
        // terminate the quoted string and run the rest as commands.
        let root = URL(fileURLWithPath: "/Users/dan's mac/Data", isDirectory: true)

        let line = PythonBridge.dataDirExport(root)

        XCTAssertTrue(line.contains("'\"'\"'"),
                      "an unescaped apostrophe turns a path into shell commands")
        XCTAssertFalse(line.contains("dan's mac"),
                       "the raw apostrophe survived into the script")
    }

    func testAPathWithSpacesStaysOneArgument() {
        let root = URL(fileURLWithPath: "/Users/dan/Application Support/PostRoll",
                       isDirectory: true)

        let line = PythonBridge.dataDirExport(root)

        XCTAssertTrue(line.hasPrefix("export POSTROLL_DATA_DIR='"))
        XCTAssertTrue(line.hasSuffix("'"))
    }
}
