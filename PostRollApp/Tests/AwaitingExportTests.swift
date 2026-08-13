import XCTest

/// #455: two surfaces treated an event Dan had approved but never exported as
/// exported, and one of them started the clock that deletes its media.
///
/// `stage == .exported` is a navigation router, not a milestone: approving the
/// captions flips it purely to open the Export screen. `isExported` is the
/// refined answer, and everything acting on "is this exported" has to go
/// through it (L16).
final class AwaitingExportTests: XCTestCase {

    private func anEvent(stage: EventStage = .exported,
                         exportPath: URL? = nil,
                         archivedAt: Date? = nil) -> Event {
        var event = Event(name: "Show", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        event.stage = stage
        event.exportPath = exportPath
        event.archivedAt = archivedAt
        return event
    }

    func testApprovedButNeverExportedIsNotExported() {
        let event = anEvent()
        XCTAssertTrue(event.isAwaitingExport)
        XCTAssertFalse(event.isExported,
                       "an event whose export has never run reads as exported")
    }

    func testAnEventWithFilesOnDiskIsExported() {
        XCTAssertTrue(anEvent(exportPath: URL(fileURLWithPath: "/tmp/export")).isExported)
    }

    func testALegacyEventWithOnlyAnArchiveStampIsExported() {
        // Events exported before exportPath was recorded carry only archivedAt.
        XCTAssertTrue(anEvent(archivedAt: Date()).isExported)
    }

    func testAnEventEarlierInTheWeekIsNeitherAwaitingNorExported() {
        let event = anEvent(stage: .assetsGenerated)
        XCTAssertFalse(event.isExported)
        XCTAssertFalse(event.isAwaitingExport)
    }

    // MARK: - The sweep

    func testTheLaunchSweepDoesNotStartTheArchiveClockOnAnUnexportedEvent() throws {
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AwaitingExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        var events = [anEvent()]
        ArchiveCleanup.sweep(events: &events, dataRoot: dataRoot, audit: { _ in })

        // Stamping archivedAt here starts the 60 day countdown that reclaims
        // this event's preview media and program scans, for an export that has
        // never run and that Dan still owes.
        XCTAssertNil(events[0].archivedAt,
                     "the archive clock was started on an event that was never exported")
    }

    func testTheSweepStillStampsARealExportThatCarriesNoStampYet() throws {
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AwaitingExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        var events = [anEvent(exportPath: URL(fileURLWithPath: "/tmp/export"))]
        ArchiveCleanup.sweep(events: &events, dataRoot: dataRoot, audit: { _ in })

        XCTAssertNotNil(events[0].archivedAt,
                        "a genuinely exported event never gets its grace period started")
    }
}
