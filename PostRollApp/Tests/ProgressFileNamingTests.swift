import XCTest

/// #234 gave the media run its own progress file, so the sweep has two names to
/// know about. A sweep that knew only `<uuid>.json` would leave every media
/// file behind forever, which is the defect this whole file exists to fix.
final class ProgressFileNamingTests: XCTestCase {

    func testItRecognisesTheCaptionRunsFile() {
        let id = UUID()
        XCTAssertEqual(ProgressFileCleanup.eventID(fromFileNamed: id.uuidString), id)
    }

    func testItRecognisesTheMediaRunsFile() {
        let id = UUID()
        XCTAssertEqual(ProgressFileCleanup.eventID(fromFileNamed: "\(id.uuidString)-media"), id)
    }

    func testItDoesNotClaimAFileThatIsNotOurs() {
        XCTAssertNil(ProgressFileCleanup.eventID(fromFileNamed: "notes"))
        XCTAssertNil(ProgressFileCleanup.eventID(fromFileNamed: "notes-media"))
    }

    func testTheTwoRunsGetDifferentFiles() {
        // The whole reason for the second name: they run at the same time, so
        // one file would have each overwrite the other's label.
        let id = UUID()
        XCTAssertNotEqual(AppPaths.progressFile(forEventID: id),
                          AppPaths.mediaProgressFile(forEventID: id))
    }

    func testAMediaProgressFileOfADeadEventIsSweptToo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("progress-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let orphan = dir.appendingPathComponent("\(UUID().uuidString)-media.json")
        try Data("{}".utf8).write(to: orphan)

        ProgressFileCleanup.sweep(events: [], progressDir: dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}
