import XCTest

/// #182: the export complete screen was a dead end, and #184: an export folder
/// could not say whether it had finished.
///
/// Three things stacked up on #182. "Skip, text export only" leaves the media
/// step running on purpose, so the milestone still gets stamped, but it did
/// that by keeping the run ACTIVE. That one flag drove three separate things:
/// the sidebar pill, whether Done could dismiss the run, and whether export was
/// considered in flight. So the sidebar said "Exporting…" while the pane said
/// "Export complete", and Done silently did nothing.
///
/// One flag answering three questions is the defect (L53). Finishing media in
/// the background is its own state, distinct from a run still exporting.
@MainActor
final class ExportCompletionTests: XCTestCase {

    private var destination: URL!

    override func setUpWithError() throws {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: destination)
    }

    // MARK: - #182: the sidebar and the screen must agree

    func testAnEventFinishingMediaIsNotLabelledAsExporting() {
        // The pane says "Export complete" at this point, so the sidebar must
        // not contradict it.
        let state = StagePillState.resolve(
            stage: .exported, isGenerating: false, generationFailed: false,
            isExporting: false, isFinishingMedia: true,
            awaitingGeneration: false, awaitingExport: false)

        XCTAssertNotEqual(state.label, "Exporting…")
    }

    func testFinishingMediaStillSaysSomethingIsHappening() {
        // Going silent would be the opposite failure: assets are still being
        // written and the folder is not finished yet.
        let state = StagePillState.resolve(
            stage: .exported, isGenerating: false, generationFailed: false,
            isExporting: false, isFinishingMedia: true,
            awaitingGeneration: false, awaitingExport: false)

        XCTAssertEqual(state.label, "Finishing assets…")
        XCTAssertTrue(state.isBusy)
    }

    func testARunStillExportingIsStillLabelledExporting() {
        let state = StagePillState.resolve(
            stage: .exported, isGenerating: false, generationFailed: false,
            isExporting: true, isFinishingMedia: false,
            awaitingGeneration: false, awaitingExport: false)

        XCTAssertEqual(state.label, "Exporting…")
    }

    func testExportingWinsOverFinishingMedia() {
        // Both true should never happen, but if it does the more urgent state
        // is the one that is genuinely still in flight.
        let state = StagePillState.resolve(
            stage: .exported, isGenerating: false, generationFailed: false,
            isExporting: true, isFinishingMedia: true,
            awaitingGeneration: false, awaitingExport: false)

        XCTAssertEqual(state.label, "Exporting…")
    }

    // MARK: - #182: Done must actually dismiss

    private func makeEvent() -> Event {
        Event(name: "Music From Inside", org: "Decoda", venue: "Hall",
              date: Date(timeIntervalSince1970: 1_700_000_000), shootType: .fullShow)
    }

    func testDoneClearsARunThatSkippedMedia() {
        // The reported case: press "Skip, text export only", then Done, and
        // nothing happened at all.
        let manager = ExportManager()
        let id = UUID()
        manager.setRunForTesting(phase: .generatingMedia(destination), for: id)

        manager.skipMedia(eventID: id)
        manager.clear(eventID: id)

        XCTAssertNil(manager.run(for: id),
                     "Done must dismiss a run whose media is finishing in the background")
    }

    func testSkippingMediaStopsTheRunCountingAsExporting() {
        let manager = ExportManager()
        let id = UUID()
        manager.setRunForTesting(phase: .generatingMedia(destination), for: id)

        manager.skipMedia(eventID: id)

        XCTAssertFalse(manager.isExporting(id))
        XCTAssertTrue(manager.isFinishingMedia(id),
                      "the work is still happening and must remain visible")
    }

    func testSkippingMediaLeavesTheDoneScreenShowing() {
        let manager = ExportManager()
        let id = UUID()
        manager.setRunForTesting(phase: .generatingMedia(destination), for: id)

        manager.skipMedia(eventID: id)

        guard case .done? = manager.run(for: id)?.phase else {
            return XCTFail("skipping media must show the done screen")
        }
    }

    func testSkipDoesNothingWhenTheRunIsNotGeneratingMedia() {
        // Nothing to skip before the media step starts, and pretending
        // otherwise would show a done screen over an unfinished text export.
        let manager = ExportManager()
        let id = UUID()
        manager.setRunForTesting(phase: .exportingText, for: id)

        manager.skipMedia(eventID: id)

        XCTAssertFalse(manager.isFinishingMedia(id))
        guard case .exportingText? = manager.run(for: id)?.phase else {
            return XCTFail("the phase must be left alone")
        }
    }

    func testAFinishedRunIsNeitherExportingNorFinishingMedia() {
        let manager = ExportManager()

        XCTAssertFalse(manager.isExporting(UUID()))
        XCTAssertFalse(manager.isFinishingMedia(UUID()))
    }
}
