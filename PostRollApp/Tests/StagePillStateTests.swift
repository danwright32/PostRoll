import XCTest

/// Pins the sidebar pill's precedence now that background work (generation,
/// OCR, export) survives event switches and must surface in the sidebar even
/// when the user is off working on a different event.
final class StagePillStateTests: XCTestCase {

    func testGeneratingOverridesEverything() {
        let s = StagePillState.resolve(
            stage: .assetsGenerated, isGenerating: true, generationFailed: false,
            isReading: false, readingFailed: false, isExporting: false,
            awaitingGeneration: true, awaitingExport: false)
        XCTAssertEqual(s, .generating)
        XCTAssertEqual(s.label, "Generating…")
        XCTAssertTrue(s.isBusy)
    }

    func testReadingShows() {
        let s = StagePillState.resolve(
            stage: .programUploaded, isGenerating: false, generationFailed: false,
            isReading: true, readingFailed: false, isExporting: false,
            awaitingGeneration: false, awaitingExport: false)
        XCTAssertEqual(s, .reading)
        XCTAssertEqual(s.label, "Reading…")
        XCTAssertTrue(s.isBusy)
    }

    func testExportingShows() {
        let s = StagePillState.resolve(
            stage: .exported, isGenerating: false, generationFailed: false,
            isReading: false, readingFailed: false, isExporting: true,
            awaitingGeneration: false, awaitingExport: true)
        XCTAssertEqual(s, .exporting)
        XCTAssertEqual(s.label, "Exporting…")
        XCTAssertTrue(s.isBusy)
    }

    func testLiveWorkBeatsFailureFlags() {
        // A fresh run started after a prior failure: the live state wins.
        let s = StagePillState.resolve(
            stage: .assetsGenerated, isGenerating: true, generationFailed: true,
            isReading: false, readingFailed: false, isExporting: false,
            awaitingGeneration: false, awaitingExport: false)
        XCTAssertEqual(s, .generating)
    }

    func testGenerationFailedSurfacesWhenIdle() {
        let s = StagePillState.resolve(
            stage: .assetsGenerated, isGenerating: false, generationFailed: true,
            isReading: false, readingFailed: false, isExporting: false,
            awaitingGeneration: false, awaitingExport: false)
        XCTAssertEqual(s, .generationFailed)
        XCTAssertEqual(s.label, "Needs Attention")
        XCTAssertFalse(s.isBusy)
    }

    func testFallsBackToAwaitingAndStage() {
        let awaiting = StagePillState.resolve(
            stage: .assetsGenerated, isGenerating: false, generationFailed: false,
            isReading: false, readingFailed: false, isExporting: false,
            awaitingGeneration: true, awaitingExport: false)
        XCTAssertEqual(awaiting, .awaitingGeneration)

        let plain = StagePillState.resolve(
            stage: .photosAssigned, isGenerating: false, generationFailed: false,
            isReading: false, readingFailed: false, isExporting: false,
            awaitingGeneration: false, awaitingExport: false)
        XCTAssertEqual(plain, .stage(.photosAssigned))
        XCTAssertFalse(plain.isBusy)
    }
}
