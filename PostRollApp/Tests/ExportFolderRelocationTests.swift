import XCTest

/// #1110: the export screen stops calling a filed export a lost one, and gives
/// Dan a way to say where it went.
///
/// Both halves of that are pulled out of the view so they can be checked
/// without launching one: how a status draws, and what pointing at a folder
/// does to the record.
final class ExportFolderRelocationTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("relocate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func exportedEvent(at path: URL) -> Event {
        var e = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        e.exportPath = path
        return e
    }

    // ── how the screen draws each status ─────────────────────────────────────

    func testAFiledExportDrawsAsInformationNotAWarning() throws {
        let banner = try XCTUnwrap(
            ExportFolderBanner.of(.lostTrack(folder.appendingPathComponent("filed"))))
        XCTAssertEqual(banner.style, .info,
                       "this fires on every export Dan has, so drawing it in the fault "
                     + "style is what taught him to skip the whole banner (L36)")
        XCTAssertNotEqual(banner.icon, "exclamationmark.triangle",
                          "the icon is the part read before the words, so it must not "
                        + "say fault while the sentence says nothing is wrong")
    }

    func testAnUnfinishedExportStillDrawsAsAWarning() throws {
        let banner = try XCTUnwrap(
            ExportFolderBanner.of(.unfinished(fileCount: 0, emptyDayFolders: ["1. Sunday"],
                                              hasCaptions: false)))
        XCTAssertEqual(banner.style, .warning)
        XCTAssertEqual(banner.icon, "exclamationmark.triangle")
    }

    func testAFinishedExportDrawsNoBannerAtAll() {
        XCTAssertNil(ExportFolderBanner.of(.finished(exportedAt: Date(), fileCount: 12)),
                     "a banner on every visit to a good export is how a real one stops "
                   + "being read")
        XCTAssertNil(ExportFolderBanner.of(.neverExported))
    }

    // ── pointing PostRoll at the folder again ────────────────────────────────

    func testPointingAtTheFolderRecordsWhereItWent() throws {
        let event = exportedEvent(at: folder.appendingPathComponent("gone"))
        let moved = try XCTUnwrap(
            ExportFolderRelocation.applying(folder, toEventWithID: event.id, in: [event]))
        XCTAssertEqual(moved.exportPath, folder)
    }

    func testItRefusesAFolderThatIsNotThereEither() {
        let event = exportedEvent(at: folder.appendingPathComponent("gone"))
        let alsoGone = folder.appendingPathComponent("not-here-either")
        XCTAssertNil(
            ExportFolderRelocation.applying(alsoGone, toEventWithID: event.id, in: [event]),
            "recording a second path that is already wrong replaces one lost record "
          + "with another while reading as a repair (L5)")
    }

    func testItRefusesAFileThatIsNotAFolder() throws {
        let file = folder.appendingPathComponent("CAPTIONS.txt")
        try Data("x".utf8).write(to: file)
        let event = exportedEvent(at: folder.appendingPathComponent("gone"))
        XCTAssertNil(
            ExportFolderRelocation.applying(file, toEventWithID: event.id, in: [event]),
            "an export folder is a folder, and recording a file as one would have "
          + "every later read report an export that never finished")
    }

    func testItRefusesAnEventItCannotFind() {
        let event = exportedEvent(at: folder.appendingPathComponent("gone"))
        XCTAssertNil(
            ExportFolderRelocation.applying(folder, toEventWithID: UUID(), in: [event]),
            "writing the path onto whatever event happened to be at hand is worse "
          + "than doing nothing")
    }

    func testTheRepairActuallyClearsTheState() throws {
        let event = exportedEvent(at: folder.appendingPathComponent("gone"))
        XCTAssertEqual(ExportFolderStatus.of(event).attention, .informational)
        let moved = try XCTUnwrap(
            ExportFolderRelocation.applying(folder, toEventWithID: event.id, in: [event]))
        XCTAssertNotEqual(ExportFolderStatus.of(moved).attention, .informational,
                          "a remedy that leaves the same message standing is a step "
                        + "that cannot change the state he is in (L111)")
    }
}
