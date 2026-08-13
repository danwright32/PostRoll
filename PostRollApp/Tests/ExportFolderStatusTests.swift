import XCTest

/// #247: the export folder's completeness reaches the app.
///
/// #184 made the manifest the completion signal: written last, and only by a
/// run that lost nothing, so an interrupted run leaves none. `isComplete` and
/// `read` were then called by nothing, so only somebody standing in Finder
/// could use the record, and the field looked alive to any is-this-used check
/// while its purpose silently never happened (L46).
final class ExportFolderStatusTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeDay(_ name: String, files: [String]) throws {
        let dir = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            try Data("x".utf8).write(to: dir.appendingPathComponent(f))
        }
    }

    private func writeManifest(now: Date = Date()) {
        ExportManifest.write(
            ExportManifest.build(folder: folder, preset: .balanced, event: "Test", now: now),
            to: folder)
    }

    // ── the finished case ─────────────────────────────────────────────────────

    func testAFolderWithAManifestIsFinished() throws {
        try makeDay("1. Sunday", files: ["story.png"])
        try Data("captions".utf8).write(to: folder.appendingPathComponent("CAPTIONS.txt"))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        writeManifest(now: when)

        guard case .finished(let at, let count) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("a folder holding a manifest is a finished export")
        }
        XCTAssertEqual(at.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(count, 2)
    }

    func testAFinishedExportDoesNotAskForAttention() throws {
        try makeDay("1. Sunday", files: ["story.png"])
        writeManifest()
        XCTAssertFalse(ExportFolderStatus.of(folder: folder).needsAttention,
                       "a banner on every visit to a good export is how a real "
                       + "warning stops being read")
    }

    // ── the case the manifest exists for ──────────────────────────────────────

    func testAFolderWithNoManifestIsUnfinished() throws {
        try makeDay("1. Sunday", files: ["story.png"])

        guard case .unfinished = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("no manifest means the run that made this did not finish")
        }
        XCTAssertTrue(ExportFolderStatus.of(folder: folder).needsAttention)
    }

    func testItNamesTheEmptyDayFolders() throws {
        try makeDay("1. Sunday", files: ["story.png"])
        try makeDay("5. Thursday", files: [])
        try makeDay("6. Friday", files: [])

        guard case .unfinished(_, let empties, _) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("expected unfinished")
        }
        XCTAssertEqual(empties, ["5. Thursday", "6. Friday"],
                       "with no manifest there is no record of what was meant to "
                       + "be there, so it reports what is missing NOW")
    }

    func testItNoticesTheCaptionsFileIsAbsent() throws {
        try makeDay("1. Sunday", files: ["story.png"])

        guard case .unfinished(_, _, let hasCaptions) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("expected unfinished")
        }
        XCTAssertFalse(hasCaptions)
        let message = try XCTUnwrap(ExportFolderStatus.of(folder: folder).message)
        XCTAssertTrue(message.contains("CAPTIONS.txt"), message)
    }

    func testItCountsTheFilesThatAreThere() throws {
        try makeDay("1. Sunday", files: ["story.png", "cover.png"])
        try Data("captions".utf8).write(to: folder.appendingPathComponent("CAPTIONS.txt"))

        guard case .unfinished(let count, _, let hasCaptions) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("expected unfinished")
        }
        XCTAssertEqual(count, 3, "nearly-done and nearly-empty are different situations")
        XCTAssertTrue(hasCaptions)
    }

    // ── the folder itself ─────────────────────────────────────────────────────

    func testAFolderThatIsNoLongerThereIsItsOwnState() {
        let gone = folder.appendingPathComponent("moved-away")
        guard case .folderGone = ExportFolderStatus.of(folder: gone) else {
            return XCTFail("a missing folder is not an unfinished export")
        }
        XCTAssertTrue(ExportFolderStatus.of(folder: gone).needsAttention)
    }

    func testAnEventNeverExportedSaysNothing() {
        let event = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        XCTAssertEqual(ExportFolderStatus.of(event), .neverExported)
        XCTAssertNil(ExportFolderStatus.of(event).message)
        XCTAssertFalse(ExportFolderStatus.of(event).needsAttention)
    }

    func testItReadsTheFolderRecordedOnTheEvent() throws {
        try makeDay("1. Sunday", files: ["story.png"])
        writeManifest()
        var event = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        event.exportPath = folder

        guard case .finished = ExportFolderStatus.of(event) else {
            return XCTFail("the event's own folder is the one to read")
        }
    }

    // ── the message ───────────────────────────────────────────────────────────

    func testTheUnfinishedMessageSaysWhatToDo() throws {
        try makeDay("1. Sunday", files: [])
        let message = try XCTUnwrap(ExportFolderStatus.of(folder: folder).message)
        XCTAssertTrue(message.lowercased().contains("export again"), message)
    }

    func testTheMissingFolderMessageSaysWhereItWent() throws {
        let gone = folder.appendingPathComponent("Vocal Colors")
        let message = try XCTUnwrap(ExportFolderStatus.of(folder: gone).message)
        XCTAssertTrue(message.contains("Vocal Colors"), message)
        XCTAssertTrue(message.lowercased().contains("export again"), message)
    }

    // MARK: - #451: a folder that cannot be read is not one that never finished

    func testAnUnreadableFolderIsNotReportedAsAnUnfinishedExport() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }

        guard case .unreadable = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("an unreadable folder read as \(ExportFolderStatus.of(folder: folder))")
        }
    }

    func testTheUnreadableMessageDoesNotTellDanToExportAgain() {
        guard let message = ExportFolderStatus.unreadable("Permission denied").message else {
            return XCTFail("an unreadable folder says nothing")
        }
        XCTAssertTrue(message.contains("Permission denied"), message)
        XCTAssertTrue(message.lowercased().contains("privacy"),
                      "the message does not name the fix that would work: \(message)")
    }

    func testAnUnreadableFolderIsWorthShowing() {
        XCTAssertTrue(ExportFolderStatus.unreadable("Permission denied").needsAttention)
    }

    /// An empty folder is a real answer: that export genuinely never finished.
    func testAnEmptyReadableFolderStillReadsAsUnfinished() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        guard case .unfinished(let count, _, _) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("an empty folder did not read as unfinished")
        }
        XCTAssertEqual(count, 0)
    }
}
