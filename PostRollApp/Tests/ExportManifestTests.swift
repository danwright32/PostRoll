import XCTest

/// #184: an export folder must be able to say whether it finished.
///
/// The folder is the handoff to actually posting, and an interrupted run left
/// one that differed from a complete export only by having fewer files in it.
/// The app may have been restarted since, so the folder is the only place left
/// to catch it, and checking by hand meant listing 33 files across seven day
/// folders.
final class ExportManifestTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeFile(_ path: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
    }

    // MARK: - Presence is the completion signal

    func testAFolderWithNoManifestIsNotComplete() {
        // The honest state for a run that was interrupted.
        XCTAssertFalse(ExportManifest.isComplete(folder: folder))
    }

    func testAFolderWithAManifestIsComplete() throws {
        try makeFile("wednesday/carousel-1.jpg")

        ExportManifest.write(
            ExportManifest.build(folder: folder, preset: .balanced, event: "E"), to: folder)

        XCTAssertTrue(ExportManifest.isComplete(folder: folder))
    }

    func testAnUnreadableManifestCountsAsIncomplete() throws {
        // Half-written or corrupt is not an answer, and treating it as one
        // would vouch for a folder nobody checked.
        try Data("{ not json".utf8)
            .write(to: folder.appendingPathComponent(ExportManifest.filename))

        XCTAssertFalse(ExportManifest.isComplete(folder: folder))
    }

    // MARK: - It records what is actually there

    func testEveryDayFolderIsListedWithItsFiles() throws {
        try makeFile("wednesday/carousel-1.jpg")
        try makeFile("wednesday/carousel-2.jpg")
        try makeFile("thursday/reel.mp4")

        let contents = ExportManifest.build(folder: folder, preset: .balanced, event: "E")

        XCTAssertEqual(contents.filesByDay["wednesday"], ["carousel-1.jpg", "carousel-2.jpg"])
        XCTAssertEqual(contents.filesByDay["thursday"], ["reel.mp4"])
    }

    func testRootFilesAreCountedToo() throws {
        // CAPTIONS.txt is the thing actually pasted when posting, so a total
        // that ignored it would under-report the folder.
        try makeFile("CAPTIONS.txt")
        try makeFile("thursday/reel.mp4")

        let contents = ExportManifest.build(folder: folder, preset: .balanced, event: "E")

        XCTAssertEqual(contents.totalFiles, 2)
        XCTAssertEqual(contents.filesByDay[""], ["CAPTIONS.txt"])
    }

    func testTheManifestDoesNotCountItself() throws {
        try makeFile("thursday/reel.mp4")
        ExportManifest.write(
            ExportManifest.build(folder: folder, preset: .balanced, event: "E"), to: folder)

        let rebuilt = ExportManifest.build(folder: folder, preset: .balanced, event: "E")

        XCTAssertEqual(rebuilt.totalFiles, 1,
                       "the manifest is a record of the export, not part of it")
    }

    func testItReadsTheDiskRatherThanWhatWasIntended() throws {
        // Built from what is actually there, so a file the copy step dropped is
        // absent from the manifest too. A manifest listing a file that is not
        // in the folder would vouch for exactly the failure it exists to catch.
        try makeFile("wednesday/carousel-1.jpg")

        let contents = ExportManifest.build(folder: folder, preset: .balanced, event: "E")

        XCTAssertEqual(contents.totalFiles, 1)
        XCTAssertNil(contents.filesByDay["friday"])
    }

    func testThePresetAndEventAreRecorded() {
        let contents = ExportManifest.build(folder: folder, preset: .classic,
                                            event: "Music From Inside")

        XCTAssertEqual(contents.preset, PostingPreset.classic.rawValue)
        XCTAssertEqual(contents.event, "Music From Inside")
    }

    func testTheTimestampIsRecorded() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        let contents = ExportManifest.build(folder: folder, preset: .balanced,
                                            event: "E", now: when)

        XCTAssertEqual(contents.exportedAt, when)
    }

    // MARK: - Round trip

    func testWhatIsWrittenIsWhatIsReadBack() throws {
        try makeFile("CAPTIONS.txt")
        try makeFile("wednesday/carousel-1.jpg")
        let built = ExportManifest.build(folder: folder, preset: .balanced, event: "E",
                                         now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(ExportManifest.write(built, to: folder))

        XCTAssertEqual(ExportManifest.read(folder: folder), built)
    }

    func testWritingToAFolderThatIsGoneReportsFailure() {
        // Its absence is what a later reader uses to conclude the export is
        // incomplete, so a silent failure would mark a good export as bad. The
        // caller has to be able to know.
        let missing = folder.appendingPathComponent("nope", isDirectory: true)

        XCTAssertFalse(ExportManifest.write(
            ExportManifest.build(folder: folder, preset: .balanced, event: "E"), to: missing))
    }
}
