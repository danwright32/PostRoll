import XCTest

/// #925: the stale design sweep walks every day folder under the preview root
/// and reports every one whose cached assets are behind the current design. It
/// has no idea which of those days are finished with, and regenerating a day
/// that has already gone out changes nothing anyone will see.
///
/// The record has to live somewhere that survives. `ExportManifest` is a real
/// per day fact the app already writes, but it lives INSIDE the export folder,
/// and that folder is reached through `event.exportPath`. Measured on Dan's Mac
/// on 2026-08-31: nine of twenty one events record an export path and ZERO of
/// those nine folders are where the record says, because he files each export
/// into one of his own To Do / Not in Metricool / Done folders afterwards. A
/// sweep built on that lookup would find nothing exported, ever, which is the
/// clean bill of health nobody measured that L98 is about.
///
/// So the record is written into the PREVIEW day folder instead: the folder the
/// scan already walks, that nothing moves, beside the design stamp that answers
/// the neighbouring question about the same day.
final class DayExportRecordTests: XCTestCase {

    private var root: URL!
    private let exportedAt = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayExportRecordTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dayFolder(_ name: String = "5. Thursday") throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - The record itself

    func testADayNothingHasExportedCarriesNoDate() throws {
        XCTAssertNil(DayExportRecord.read(in: try dayFolder()))
    }

    func testAWrittenRecordReadsBackTheDateItWasWritten() throws {
        let dir = try dayFolder()
        XCTAssertTrue(DayExportRecord.write(exportedAt: exportedAt, in: dir))
        XCTAssertEqual(DayExportRecord.read(in: dir), exportedAt)
    }

    /// A write that failed must not be treated as written, the same way
    /// `ExportManifest.write` reports its own (#452). The absence of this record
    /// is what makes a day read as work still worth doing, so a silent failure
    /// leaves a finished day padding the list forever with nothing saying why.
    func testAWriteIntoAFolderThatIsNotThereReportsFailure() {
        XCTAssertFalse(DayExportRecord.write(
            exportedAt: exportedAt, in: root.appendingPathComponent("no-such-day")))
    }

    /// Half a file is not a date. Read as one it would mark a day finished on
    /// evidence nobody wrote (L50).
    func testARecordThatIsNotJSONIsNotADate() throws {
        let dir = try dayFolder()
        try Data("{ truncated".utf8)
            .write(to: dir.appendingPathComponent(DayExportRecord.filename))
        XCTAssertNil(DayExportRecord.read(in: dir))
    }

    func testTheLatestExportIsWhatTheDayReports() throws {
        let dir = try dayFolder()
        let later = exportedAt.addingTimeInterval(86_400)
        XCTAssertTrue(DayExportRecord.write(exportedAt: exportedAt, in: dir))
        XCTAssertTrue(DayExportRecord.write(exportedAt: later, in: dir))
        XCTAssertEqual(DayExportRecord.read(in: dir), later,
                       "a day exported twice went out most recently on the second run")
    }

    // MARK: - Finding the folder to stamp

    /// The folder name is Python's to choose, so it is taken from a path the
    /// run itself produced rather than rebuilt from the event and the day. One
    /// derivation, shared with the review strip that already did this, so a
    /// change to Python's naming cannot leave the two disagreeing (L263).
    func testThePreviewFolderIsTakenFromAPathTheRunProduced() throws {
        let dir = try dayFolder()
        let asset = dir.appendingPathComponent("collage.png")
        try Data("png".utf8).write(to: asset)
        // Compared by path: a folder URL built by dropping a last component
        // carries a trailing slash and one built by appending does not, and the
        // two are the same folder.
        XCTAssertEqual(
            PreviewDayFolder.url(paths: ["collage": asset.path])?.path, dir.path)
    }

    /// A recorded path whose file is gone names no folder to stamp. Stamping
    /// the parent anyway would write the record into whatever is at that path
    /// now, which is a claim about a folder nothing was read from.
    func testAPathWhoseFileIsGoneNamesNoFolder() {
        XCTAssertNil(PreviewDayFolder.url(
            paths: ["collage": root.appendingPathComponent("gone/collage.png").path]))
    }

    func testADayWithNoRecordedPathsNamesNoFolder() {
        XCTAssertNil(PreviewDayFolder.url(paths: nil))
        XCTAssertNil(PreviewDayFolder.url(paths: [:]))
    }

    // MARK: - Stamping an export

    private func eventWithAssets(on days: [DayName]) throws -> Event {
        var event = Event(name: "Perpetual Light", org: "DCINY",
                          venue: "Carnegie Hall", date: Date(), shootType: .fullShow)
        for day in days {
            let dir = try dayFolder(day.folderName)
            let asset = dir.appendingPathComponent("collage.png")
            try Data("png".utf8).write(to: asset)
            event.previewMediaPaths[day.rawValue] = ["collage": asset.path]
        }
        return event
    }

    func testStampingWritesTheRecordIntoEveryDayItNames() throws {
        let event = try eventWithAssets(on: [.wednesday, .thursday])
        let missed = DayExportRecord.stamp(days: [.wednesday, .thursday],
                                           in: event, at: exportedAt)
        XCTAssertEqual(missed, [], "both days had a folder to stamp")
        XCTAssertEqual(DayExportRecord.read(in: root.appendingPathComponent("4. Wednesday")),
                       exportedAt)
        XCTAssertEqual(DayExportRecord.read(in: root.appendingPathComponent("5. Thursday")),
                       exportedAt)
    }

    /// A single day re-export is not a claim about the rest of the week.
    func testStampingLeavesEveryDayItWasNotToldAbout() throws {
        let event = try eventWithAssets(on: [.wednesday, .thursday])
        _ = DayExportRecord.stamp(days: [.thursday], in: event, at: exportedAt)
        XCTAssertNil(DayExportRecord.read(in: root.appendingPathComponent("4. Wednesday")))
    }

    /// Named, not swallowed. A day the export wrote but PostRoll could not
    /// record goes on reading as one that never went out, and the caller is the
    /// only thing in a position to say so.
    func testADayWithNoFolderToStampIsReportedBack() throws {
        let event = try eventWithAssets(on: [.thursday])
        XCTAssertEqual(DayExportRecord.stamp(days: [.wednesday, .thursday],
                                             in: event, at: exportedAt),
                       [.wednesday])
    }

    // MARK: - What the export screen says when the record did not land

    func testAnExportThatRecordedEveryDaySaysNothing() {
        XCTAssertNil(DayExportRecord.recordFailureNotice([]))
    }

    /// The files ARE exported, which is the part to say first, and the
    /// consequence is specific rather than vague: those days go on being listed
    /// as outdated work worth doing every time Dan opens the sweep, because the
    /// absence of the record is exactly what puts them there.
    func testTheNoticeNamesTheDaysAndWhatGoesWrongBecauseOfIt() {
        let notice = DayExportRecord.recordFailureNotice([.wednesday, .thursday])

        XCTAssertNotNil(notice)
        XCTAssertTrue(notice?.contains("Wednesday") ?? false, notice ?? "")
        XCTAssertTrue(notice?.contains("Thursday") ?? false, notice ?? "")
        XCTAssertTrue(notice?.lowercased().contains("nothing is missing") ?? false,
                      "the export itself is fine and has to say so: \(notice ?? "")")
        XCTAssertTrue(notice?.lowercased().contains("outdated") ?? false,
                      "name the surface this actually affects: \(notice ?? "")")
    }

    /// One day reads as one day. A sentence that says "1 days" in the ordinary
    /// single day re-export is the commonest case reading like a bug.
    func testTheNoticeReadsForASingleDay() {
        let notice = DayExportRecord.recordFailureNotice([.friday]) ?? ""

        XCTAssertFalse(notice.contains("days"), notice)
        XCTAssertTrue(notice.contains("Friday"), notice)
    }
}
