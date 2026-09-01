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

    // #1128: the suffix list was written out by hand in two places and had
    // already drifted. `ocrProgressFile` has written `<uuid>-ocr.json` since
    // #467 and the sweep never recognised one, so every OCR progress file of
    // every deleted event is still on disk. Phase 0d adds a fourth run to the
    // same shape, so the list is DERIVED from AppPaths rather than maintained
    // beside it (L41, L96): a run this test forgot to name would otherwise be
    // exempt from the very sweep meant to catch it.

    func testEveryRunThisAppWritesGetsItsOwnFile() {
        // One file per run because they overlap in time: sharing a path would
        // have each overwrite the other's label, and neither surface could
        // trust what it read.
        let id = UUID()
        let files = AppPaths.everyProgressFile(forEventID: id)
        XCTAssertEqual(Set(files).count, files.count,
                       "two runs share a progress file: \(files.map(\.lastPathComponent))")
        XCTAssertTrue(files.contains(AppPaths.progressFile(forEventID: id)))
        XCTAssertTrue(files.contains(AppPaths.mediaProgressFile(forEventID: id)))
        XCTAssertTrue(files.contains(AppPaths.ocrProgressFile(forEventID: id)))
        XCTAssertTrue(files.contains(AppPaths.blogProgressFile(forEventID: id)))
        XCTAssertTrue(files.contains(AppPaths.blogPhotoSwapProgressFile(forEventID: id)))
    }

    func testTheSweepRecognisesEveryFileTheAppItselfWrites() {
        // The check that keeps the two halves from drifting again. Derived from
        // the writers, so adding a fifth run cannot leave the sweep behind.
        let id = UUID()
        for file in AppPaths.everyProgressFile(forEventID: id) {
            let stem = file.deletingPathExtension().lastPathComponent
            XCTAssertEqual(
                ProgressFileCleanup.eventID(fromFileNamed: stem), id,
                "the sweep does not recognise \(file.lastPathComponent), so every "
                + "one of those belonging to a deleted event stays on disk forever")
        }
    }

    func testEveryProgressFileHasARunThatCanReadIt() {
        // A file with a writer and no reader is not a progress signal (L46).
        // `LongRunIndicator.Run` is the only thing that turns a step file into
        // something on screen, so every file AppPaths can write needs a case,
        // and the check is derived from the writers rather than listing them.
        let id = UUID()
        let readable = Set(LongRunIndicator.Run.allCases.map { $0.file(forEventID: id) })
        for file in AppPaths.everyProgressFile(forEventID: id) {
            XCTAssertTrue(
                readable.contains(file),
                "\(file.lastPathComponent) is written by a run and no "
                + "LongRunIndicator.Run reads it, so whatever writes it shows "
                + "as a bare spinner however much it says")
        }
    }

    func testAProgressFileOfADeadEventIsSweptWhicheverRunWroteIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("progress-every-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dead = UUID()
        let orphans = AppPaths.everyProgressFile(forEventID: dead).map {
            dir.appendingPathComponent($0.lastPathComponent)
        }
        for orphan in orphans { try Data("{}".utf8).write(to: orphan) }

        ProgressFileCleanup.sweep(events: [], progressDir: dir)

        for orphan in orphans {
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path),
                           "\(orphan.lastPathComponent) survived the sweep")
        }
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
