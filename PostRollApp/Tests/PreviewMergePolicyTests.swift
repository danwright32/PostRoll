import XCTest

/// Cover for the generation run's preview-graphics decisions, extracted from
/// GenerationManager. The partial-retry merge in particular is the fix that lets
/// a preset switch rebuild only the affected days' previews without wiping the
/// rest.
final class PreviewMergePolicyTests: XCTestCase {

    // MARK: - shouldRenderGraphics

    func testFullRunRendersGraphicsByDefault() {
        XCTAssertTrue(PreviewMergePolicy.shouldRenderGraphics(regenerateGraphics: nil, isFullRun: true))
    }

    func testPartialRetrySkipsGraphicsByDefault() {
        XCTAssertFalse(PreviewMergePolicy.shouldRenderGraphics(regenerateGraphics: nil, isFullRun: false))
    }

    func testRegenerateGraphicsOverridesPartialRetry() {
        XCTAssertTrue(PreviewMergePolicy.shouldRenderGraphics(regenerateGraphics: true, isFullRun: false))
        XCTAssertFalse(PreviewMergePolicy.shouldRenderGraphics(regenerateGraphics: false, isFullRun: true))
    }

    // MARK: - merge

    func testFullRunReplacesEntireMap() {
        let existing = ["sunday": ["story": "/old/sun.png"], "tuesday": ["reel": "/old/tue.mp4"]]
        let fresh = ["sunday": ["collage": "/new/sun.png"]]
        let merged = PreviewMergePolicy.merge(existing: existing, fresh: fresh, isFullRun: true)
        XCTAssertEqual(merged, fresh, "a full run replaces all previews")
    }

    func testPartialRetryMergesOnlyRegeneratedDays() {
        let existing = ["sunday": ["story": "/old/sun.png"], "tuesday": ["reel": "/old/tue.mp4"]]
        let fresh = ["sunday": ["collage": "/new/sun.png"]]
        let merged = PreviewMergePolicy.merge(existing: existing, fresh: fresh, isFullRun: false)
        XCTAssertEqual(merged["sunday"], ["collage": "/new/sun.png"], "regenerated day is updated")
        XCTAssertEqual(merged["tuesday"], ["reel": "/old/tue.mp4"], "untouched day's preview survives")
    }

    func testEmptyOrNilFreshLeavesExistingUntouched() {
        let existing = ["sunday": ["story": "/old/sun.png"]]
        XCTAssertEqual(PreviewMergePolicy.merge(existing: existing, fresh: nil, isFullRun: false), existing)
        XCTAssertEqual(PreviewMergePolicy.merge(existing: existing, fresh: [:], isFullRun: true), existing)
    }

    // MARK: - copyPreviewAssetsIfComplete (#142)

    // ExportManager's fast-copy-from-preview path is the only place any
    // day's rendered graphics reach the exported folder without a Python
    // regen. Extracted here so it's testable with real files instead of
    // Task/AppState/security-scoped URLs. Generic over asset key by
    // construction, proving "cover" (#141) copies exactly like "reel" or
    // "story", no exclusions needed.

    private var root: URL!
    private var sourceDir: URL!
    private var dayDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewmergepolicy-test-\(UUID().uuidString)")
        sourceDir = root.appendingPathComponent("_source")
        dayDir = root.appendingPathComponent("6. Friday")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String) -> URL {
        let url = sourceDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("data".utf8))
        return url
    }

    func testCopiesCoverAlongsideOtherAssetsWhenAllExist() throws {
        let reel = makeFile("reel_clip.mp4")
        let cover = makeFile("cover.png")

        let copied = PreviewMergePolicy.copyPreviewAssetsIfComplete(
            assets: ["reel": reel.path, "cover": cover.path], to: dayDir
        )

        XCTAssertTrue(copied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dayDir.appendingPathComponent("reel_clip.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dayDir.appendingPathComponent("cover.png").path))
    }

    func testReturnsFalseAndCopiesNothingWhenAnyAssetIsMissing() throws {
        let reel = makeFile("reel_clip.mp4")
        let missingCoverPath = sourceDir.appendingPathComponent("cover.png").path

        let copied = PreviewMergePolicy.copyPreviewAssetsIfComplete(
            assets: ["reel": reel.path, "cover": missingCoverPath], to: dayDir
        )

        XCTAssertFalse(copied, "a day with any stale/missing asset must fall through to Python, not copy a partial set")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dayDir.appendingPathComponent("reel_clip.mp4").path))
    }

    func testReturnsFalseWhenAssetsIsNilOrEmpty() {
        XCTAssertFalse(PreviewMergePolicy.copyPreviewAssetsIfComplete(assets: nil, to: dayDir))
        XCTAssertFalse(PreviewMergePolicy.copyPreviewAssetsIfComplete(assets: [:], to: dayDir))
    }

    func testCoverOnlyAssetCopiesJustAsAnyOtherKeyWould() throws {
        // Isolates the #141 case: a day whose only rendered asset (this
        // run) is cover.png must still copy, proving no key is special-cased.
        let cover = makeFile("cover.png")

        let copied = PreviewMergePolicy.copyPreviewAssetsIfComplete(assets: ["cover": cover.path], to: dayDir)

        XCTAssertTrue(copied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dayDir.appendingPathComponent("cover.png").path))
    }
}

/// The graphics step of a generation run reports per-day failures the same way
/// the caption step does, but the run used to read only the rendered paths out of
/// the result and drop `errors` on the floor (behind a `try?` that also swallowed
/// an outright crash). A failed Wednesday collage therefore reported success and
/// simply left the day with no story. These pin the failure path: a graphics
/// failure has to survive into the event, and only a run that actually re-rendered
/// a day may clear that day's recorded failure.
final class MediaErrorMergeTests: XCTestCase {

    // MARK: - mergeMediaErrors

    func testFullRunReplacesAllRecordedMediaErrors() {
        let existing = ["wednesday": "collage failed: old", "thursday": "reel failed"]
        let fresh = ["wednesday": "collage failed: new"]

        let merged = PreviewMergePolicy.mergeMediaErrors(
            existing: existing, fresh: fresh, renderedDays: nil)

        XCTAssertEqual(merged, fresh, "a full run re-rendered everything, so it owns the whole error set")
    }

    func testRetryClearsOnlyTheDaysItRendered() {
        let existing = ["wednesday": "collage failed", "thursday": "reel failed"]

        let merged = PreviewMergePolicy.mergeMediaErrors(
            existing: existing, fresh: [:], renderedDays: ["wednesday"])

        XCTAssertNil(merged["wednesday"], "Wednesday rendered cleanly this time")
        XCTAssertEqual(merged["thursday"], "reel failed",
                       "Thursday was never re-attempted, so its failure must not be silently cleared")
    }

    func testCaptionOnlyRetryKeepsGraphicsFailuresIntact() {
        // A partial retry skips graphics entirely (shouldRenderGraphics == false),
        // so it renders no days and must leave every recorded failure standing.
        let existing = ["wednesday": "collage failed"]

        let merged = PreviewMergePolicy.mergeMediaErrors(
            existing: existing, fresh: [:], renderedDays: [])

        XCTAssertEqual(merged, existing)
    }

    func testRetryThatFailsAgainRecordsTheNewMessage() {
        let merged = PreviewMergePolicy.mergeMediaErrors(
            existing: ["wednesday": "collage failed: old"],
            fresh: ["wednesday": "collage failed: still broken"],
            renderedDays: ["wednesday"])

        XCTAssertEqual(merged["wednesday"], "collage failed: still broken")
    }

    // MARK: - retryPlan

    func testRetryOfAGraphicsFailureRerendersThatDaysGraphics() {
        // The default partial retry skips graphics, which would make the retry
        // button look like it did nothing for a collage failure.
        let plan = PreviewMergePolicy.retryPlan(
            failedKeys: ["wednesday"], mediaErrorKeys: ["wednesday"])

        XCTAssertEqual(plan.days, ["wednesday"])
        XCTAssertEqual(plan.regenerateGraphics, true)
    }

    func testRetryOfACaptionOnlyFailureLeavesGraphicsAlone() {
        let plan = PreviewMergePolicy.retryPlan(
            failedKeys: ["monday", "blog"], mediaErrorKeys: [])

        XCTAssertEqual(plan.days, ["monday", "blog"])
        XCTAssertNil(plan.regenerateGraphics, "no graphics failure, so keep the cheap caption-only retry")
    }

    func testWholeGraphicsRunCrashRetriesAsAFullRun() {
        // The crash key names no day, so it cannot be passed to --only-days.
        let plan = PreviewMergePolicy.retryPlan(
            failedKeys: [PreviewMergePolicy.graphicsRunKey],
            mediaErrorKeys: [PreviewMergePolicy.graphicsRunKey])

        XCTAssertNil(plan.days, "nothing day-shaped to retry, so re-run the whole thing")
        XCTAssertNil(plan.regenerateGraphics, "a full run renders graphics anyway")
    }

    func testGraphicsCrashAlongsideADayFailureStillRetriesThatDay() {
        let plan = PreviewMergePolicy.retryPlan(
            failedKeys: ["wednesday", PreviewMergePolicy.graphicsRunKey],
            mediaErrorKeys: ["wednesday", PreviewMergePolicy.graphicsRunKey])

        XCTAssertEqual(plan.days, ["wednesday"], "the non-day crash key must be filtered out")
        XCTAssertEqual(plan.regenerateGraphics, true)
    }

    // MARK: - Persistence

    func testMediaErrorsSurviveASaveAndReload() throws {
        var event = Event(name: "Spring Concert", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        event.mediaErrors = ["wednesday": "collage failed: no such file"]

        let data = try JSONEncoder().encode(event)
        let reloaded = try JSONDecoder().decode(Event.self, from: data)

        XCTAssertEqual(reloaded.mediaErrors, ["wednesday": "collage failed: no such file"])
    }

    func testMediaErrorsDefaultToEmptyForEventsSavedBeforeTheFieldExisted() throws {
        let legacy = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Old Show","org":"Org",
         "venue":"Hall","date":0,"shootType":"Performance"}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(Event.self, from: legacy)

        XCTAssertEqual(event.mediaErrors, [:])
    }
}
