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
