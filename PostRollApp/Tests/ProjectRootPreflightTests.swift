import XCTest

/// The bridge refuses to launch anything when it cannot reach the Python
/// checkout, and says which folder it looked in (#648).
///
/// Before this, the run went ahead: the launch script's `cd` failed, the shell
/// carried on, and `python3 -m postroll...` ran from whatever the app's working
/// directory happened to be. What came back was the shell's own `cd` line,
/// which the classifier read as a missing FILE, so Dan was told to check that
/// his photos had not moved.
///
/// Refusing before the launch rather than classifying the wreckage afterwards
/// is what makes the cause nameable: at this point we still know the difference
/// between "no folder was ever recorded", "the recorded folder is gone" and
/// "that folder is not a PostRoll checkout".
final class ProjectRootPreflightTests: XCTestCase {

    /// A directory that looks like the checkout, which is the presence of the
    /// `postroll` package the app runs with `-m`.
    private func makeCheckout() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("postroll"), withIntermediateDirectories: true)
        return dir
    }

    func testAUsableCheckoutIsHandedBack() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        XCTAssertEqual(try PythonBridge.preflight(projectRoot: checkout), checkout)
    }

    /// Asserting on the SPECIFIC failure, not merely that something threw: any
    /// throw satisfies a bare `XCTAssertThrowsError`, including one raised by
    /// the test's own setup (L140).
    func testAnAbsentCheckoutIsRefusedByName() {
        let gone = URL(fileURLWithPath: "/tmp/postroll-gone-\(UUID().uuidString)")
        XCTAssertThrowsError(try PythonBridge.preflight(projectRoot: gone)) { error in
            guard case PythonBridgeError.projectRootUnavailable(let problem) = error else {
                return XCTFail("expected projectRootUnavailable, got \(error)")
            }
            XCTAssertEqual(problem, .missing(gone))
        }
    }

    func testABuildThatRecordedNoCheckoutIsRefusedByName() {
        XCTAssertThrowsError(try PythonBridge.preflight(projectRoot: nil)) { error in
            guard case PythonBridgeError.projectRootUnavailable(let problem) = error else {
                return XCTFail("expected projectRootUnavailable, got \(error)")
            }
            XCTAssertEqual(problem, .notRecorded)
        }
    }

    /// What Dan is shown. It names the folder it looked in, and it does not
    /// send him to re-check his photos, which is what the old sentence did.
    ///
    /// The photo check is on the ADVICE, not on the word: this message says his
    /// photos are NOT affected, which is worth telling someone who has just
    /// read that the app cannot find part of itself.
    func testTheRefusalNamesThePathAndNotThePhotos() {
        let gone = URL(fileURLWithPath: "/Volumes/Work/Apps/PostRoll")
        let text = PythonBridgeError.projectRootUnavailable(.missing(gone))
            .message(whileDoing: .generation)
        XCTAssertTrue(text.contains("/Volumes/Work/Apps/PostRoll"), text)
        for advice in ["re-assign", "reassign", "original locations", "photo screen"] {
            XCTAssertFalse(text.lowercased().contains(advice), text)
        }
    }
}
