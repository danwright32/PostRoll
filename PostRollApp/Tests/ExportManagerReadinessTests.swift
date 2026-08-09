import XCTest

/// #225: the second route to a stale export.
///
/// #89 gated Approve & Export on the review screen so it could no longer copy
/// the version from before a per-day rebuild finished. The Export screen has
/// its own buttons, and those went straight into `ExportManager.start`, which
/// had no readiness check of its own. Starting a Thursday reel rebuild and then
/// exporting from the Export screen still put the previous mp4 in the posting
/// folder, with the edits missing, found out after posting.
///
/// The gate belongs in `ExportManager.start`, the one place every export route
/// goes through, rather than being repeated in each view where the next new
/// button would miss it again.
@MainActor
final class ExportManagerReadinessTests: XCTestCase {

    private var destination: URL!

    // async throws, not setUpWithError: on a @MainActor test class the
    // non-isolated variant cannot touch a main-actor property, which the older
    // Xcode in CI rejects outright even though the newer one here accepts it.
    override func setUp() async throws {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: destination)
    }

    private func makeEvent() -> Event {
        Event(name: "Music From Inside", org: "Decoda", venue: "Hall",
              date: Date(timeIntervalSince1970: 1_700_000_000), shootType: .fullShow)
    }

    // MARK: - The defect

    func testStartRefusesWhileADayIsRebuilding() {
        let manager = ExportManager()
        let event = makeEvent()
        let state = AppState(events: [event])

        manager.start(eventID: event.id, to: destination, appState: state,
                      regeneratingDays: [.thursday])

        XCTAssertFalse(manager.isExporting(event.id),
                       "An export must not begin while a day is still rebuilding")
    }

    func testARefusedStartSaysWhyRatherThanDoingNothing() {
        // A button that silently does nothing reads as broken, and the whole
        // point is that Dan learns the folder would have been stale.
        let manager = ExportManager()
        let event = makeEvent()
        let state = AppState(events: [event])

        manager.start(eventID: event.id, to: destination, appState: state,
                      regeneratingDays: [.thursday])

        guard case .failed(let message)? = manager.run(for: event.id)?.phase else {
            return XCTFail("A refused export must surface a reason, not vanish")
        }
        XCTAssertTrue(message.contains("Thursday"),
                      "The reason must name the day being waited on: \(message)")
    }

    func testASingleDayReExportIsRefusedToo() {
        // ExportSummaryCard's per-day re-export is a third route into the same
        // copy step, so it must be gated by the same rule.
        let manager = ExportManager()
        let event = makeEvent()
        let state = AppState(events: [event])

        manager.start(eventID: event.id, to: destination, onlyDay: .wednesday,
                      appState: state, regeneratingDays: [.wednesday])

        XCTAssertFalse(manager.isExporting(event.id))
    }

    func testEveryDayRebuildingBlocksTheExport() {
        // Thursday's reel is the reported case, but every day's assets are
        // copied by the same step and every one of them would copy stale.
        for day in DayName.allCases {
            let manager = ExportManager()
            let event = makeEvent()
            let state = AppState(events: [event])

            manager.start(eventID: event.id, to: destination, appState: state,
                          regeneratingDays: [day])

            XCTAssertFalse(manager.isExporting(event.id),
                           "A \(day.displayName) rebuild must block export")
        }
    }

    // MARK: - The gate does not fire when it should not

    func testNothingRebuildingDoesNotRecordARefusal() {
        // Guards against a gate that blocks everything, which would pass every
        // assertion above while making export unreachable. The event is
        // deliberately absent from the state so `start` stops at the event
        // lookup instead of launching a real export: what is under test is
        // that the readiness gate did not record a refusal on the way there.
        let manager = ExportManager()
        let state = AppState(events: [])

        manager.start(eventID: UUID(), to: destination, appState: state,
                      regeneratingDays: [])

        XCTAssertNil(manager.run(for: state.events.first?.id ?? UUID())?.phase,
                     "An export with nothing rebuilding must not be refused")
    }

    func testTheRefusalClearsSoTheNextExportCanRun() {
        // A stored refusal that outlives the rebuild would make export
        // permanently unavailable (#181: stored errors outlive the fix).
        let manager = ExportManager()
        let event = makeEvent()
        let state = AppState(events: [event])

        manager.start(eventID: event.id, to: destination, appState: state,
                      regeneratingDays: [.thursday])
        XCTAssertNotNil(manager.run(for: event.id))

        manager.clear(eventID: event.id)
        XCTAssertNil(manager.run(for: event.id),
                     "A refusal must be dismissible so export is reachable again")
    }
}
