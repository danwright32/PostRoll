import XCTest

/// Pins the sidebar pill honesty contract: `Event.stage` doubles as a
/// navigation router and flips to `.assetsGenerated` the moment the user hits
/// "Continue to Generation", before any assets are actually produced. The pill
/// must not claim "Assets Generated" until `weekResult` is populated.
final class StagePillDisplayTests: XCTestCase {

    private func makeEvent() -> Event {
        Event(name: "Music from Inside", org: "Decoda", venue: "Hall",
              date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
    }

    func testAwaitingGenerationWhenStageAdvancedButNoResult() {
        var event = makeEvent()
        event.stage = .assetsGenerated
        event.weekResult = nil
        XCTAssertTrue(event.isAwaitingGeneration,
                      "Reaching the generation screen must not read as generated.")
    }

    func testNotAwaitingOnceAssetsExist() {
        var event = makeEvent()
        event.stage = .assetsGenerated
        event.weekResult = WeekGenerationResult()
        XCTAssertFalse(event.isAwaitingGeneration,
                       "A populated weekResult means assets truly exist.")
    }

    func testEarlierStagesAreNeverAwaitingGeneration() {
        var event = makeEvent()
        for stage in [EventStage.created, .programUploaded, .ocrDone, .photosAssigned] {
            event.stage = stage
            event.weekResult = nil
            XCTAssertFalse(event.isAwaitingGeneration,
                           "\(stage) precedes the generation screen entirely.")
        }
    }

    func testAwaitingExportRightAfterApproval() {
        var event = makeEvent()
        event.stage = .exported
        event.exportPath = nil
        event.archivedAt = nil
        XCTAssertTrue(event.isAwaitingExport,
                      "Opening the Export screen must not read as exported.")
    }

    func testNotAwaitingExportOnceFilesWritten() {
        var event = makeEvent()
        event.stage = .exported
        event.exportPath = URL(fileURLWithPath: "/tmp/out")
        event.archivedAt = Date()
        XCTAssertFalse(event.isAwaitingExport,
                       "A stamped exportPath means the export actually ran.")
    }

    func testLegacyExportedEventReadsAsExported() {
        // Events exported before exportPath was recorded still carry archivedAt.
        var event = makeEvent()
        event.stage = .exported
        event.exportPath = nil
        event.archivedAt = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(event.isAwaitingExport,
                       "Legacy exported events must not regress to 'Ready to Export'.")
    }
}
