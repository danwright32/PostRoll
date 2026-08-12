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

        let result = PreviewMergePolicy.copyPreviewAssetsIfComplete(
            assets: ["reel": reel.path, "cover": cover.path], to: dayDir, label: "Friday"
        )

        XCTAssertTrue(result.satisfied)
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dayDir.appendingPathComponent("reel_clip.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dayDir.appendingPathComponent("cover.png").path))
    }

    func testReturnsFalseAndCopiesNothingWhenAnyAssetIsMissing() throws {
        let reel = makeFile("reel_clip.mp4")
        let missingCoverPath = sourceDir.appendingPathComponent("cover.png").path

        let result = PreviewMergePolicy.copyPreviewAssetsIfComplete(
            assets: ["reel": reel.path, "cover": missingCoverPath], to: dayDir, label: "Friday"
        )

        XCTAssertFalse(result.satisfied, "a day with any stale/missing asset must fall through to Python, not copy a partial set")
        XCTAssertFalse(result.attempted, "the fast path never ran, so there is nothing to report as dropped")
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dayDir.appendingPathComponent("reel_clip.mp4").path))
    }

    func testReturnsFalseWhenAssetsIsNilOrEmpty() {
        XCTAssertFalse(PreviewMergePolicy.copyPreviewAssetsIfComplete(assets: nil, to: dayDir, label: "Friday").satisfied)
        XCTAssertFalse(PreviewMergePolicy.copyPreviewAssetsIfComplete(assets: [:], to: dayDir, label: "Friday").satisfied)
    }

    func testCoverOnlyAssetCopiesJustAsAnyOtherKeyWould() throws {
        // Isolates the #141 case: a day whose only rendered asset (this
        // run) is cover.png must still copy, proving no key is special-cased.
        let cover = makeFile("cover.png")

        let result = PreviewMergePolicy.copyPreviewAssetsIfComplete(assets: ["cover": cover.path], to: dayDir, label: "Friday")

        XCTAssertTrue(result.satisfied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dayDir.appendingPathComponent("cover.png").path))
    }

    // MARK: - a copy that fails is not a success (#357)

    // The pre-check above proves every SOURCE exists. Nothing proved the copies
    // themselves worked: they ran behind `try?` and the function returned true
    // regardless, so ExportManager recorded the day as "copied directly, no
    // Python needed" and the export finished clean with the folder short a file.
    // The sibling loop in the same function (ExportManager's Python-regenerated
    // days) has caught this since #79; only the fast path missed it.

    func testAFailedCopyIsReportedRatherThanCountedAsSuccess() throws {
        let reel = makeFile("reel_clip.mp4")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        // A day folder that cannot be written to, the way a permissions problem
        // or a volume that went away presents.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dayDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dayDir.path) }
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: dayDir.path),
                       "precondition: the day folder has to be genuinely unwritable for this to test anything")

        let result = PreviewMergePolicy.copyPreviewAssetsIfComplete(
            assets: ["reel": reel.path], to: dayDir, label: "Friday")

        XCTAssertTrue(result.attempted, "every source existed, so the fast path did run")
        XCTAssertFalse(result.satisfied, "nothing reached the folder, so the day is not done")
        XCTAssertEqual(result.dropped.count, 1)
        XCTAssertEqual(result.dropped.first?.source, reel)
        XCTAssertTrue(result.dropped.first?.label.contains("Friday") == true,
                      "the warning has to name the day, not just say something went wrong")
    }

    func testAnAlreadyExportedFileSurvivesACopyThatCannotRun() throws {
        // The damaging half: the destination was deleted on the line before the
        // copy, so a copy that then failed left the folder worse off than not
        // exporting at all, and still reported success.
        let reel = makeFile("reel_clip.mp4")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let existing = dayDir.appendingPathComponent("reel_clip.mp4")
        try Data("a good file from the previous export".utf8).write(to: existing)

        // The source passes the existence check and still cannot be read.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: reel.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reel.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: reel.path),
                      "precondition: the pre-check has to pass, or this tests the wrong branch")
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: reel.path),
                       "precondition: the source has to be genuinely unreadable")

        let result = PreviewMergePolicy.copyPreviewAssetsIfComplete(
            assets: ["reel": reel.path], to: dayDir, label: "Friday")

        XCTAssertFalse(result.satisfied)
        XCTAssertEqual(result.dropped.count, 1)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8),
                       "a good file from the previous export",
                       "a replacement that never arrived must not take the existing file with it")
    }

    func testASuccessfulCopyStillReplacesAnOlderExportedFile() throws {
        // The guard above must not turn into "never overwrite": re-exporting a
        // day whose graphic changed has to end with the NEW file in the folder.
        let reel = makeFile("reel_clip.mp4")
        try Data("fresh render".utf8).write(to: reel)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let existing = dayDir.appendingPathComponent("reel_clip.mp4")
        try Data("stale render".utf8).write(to: existing)

        let result = PreviewMergePolicy.copyPreviewAssetsIfComplete(
            assets: ["reel": reel.path], to: dayDir, label: "Friday")

        XCTAssertTrue(result.satisfied)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "fresh render")
    }

    func testNoTemporaryFileIsLeftBehindInTheDayFolder() throws {
        let reel = makeFile("reel_clip.mp4")

        _ = PreviewMergePolicy.copyPreviewAssetsIfComplete(
            assets: ["reel": reel.path], to: dayDir, label: "Friday")

        let names = try FileManager.default.contentsOfDirectory(atPath: dayDir.path)
        XCTAssertEqual(names, ["reel_clip.mp4"],
                       "the swap must not leave scratch files for Dan to upload")
    }
    // MARK: - An approval that was not there to be used (#377)

    /// A day whose approved previews could not all be found is regenerated by
    /// Python, and the approved files that DO exist are copied back over the
    /// fresh ones. The ones that do not exist were skipped in silence, so that
    /// day shipped the machine's version of an image Dan had approved his own
    /// edit of, and the export reported success.
    func testAnApprovedPreviewThatIsNotThereIsReported() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let story = try makeFile("story.png", in: dir)
        let vanished = dir.appendingPathComponent("collage.png").path

        let absent = PreviewMergePolicy.absentApprovals(
            assets: ["story": story.path, "collage": vanished],
            label: "Wednesday"
        )

        XCTAssertEqual(absent.map(\.fileName), ["collage.png"])
        XCTAssertEqual(absent.first?.label, "Wednesday collage.png")
    }

    func testEveryApprovalPresentReportsNothing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let assets = try ["story.png", "reel.mp4"].map { try makeFile($0, in: dir) }
        let absent = PreviewMergePolicy.absentApprovals(
            assets: ["story": assets[0].path, "reel": assets[1].path],
            label: "Thursday"
        )

        XCTAssertTrue(absent.isEmpty)
        XCTAssertNil(PreviewMergePolicy.substitutionNotice(absent),
                     "a clean run must not render an empty notice")
    }

    /// The words matter as much as the reporting. The day folder is NOT short a
    /// file here: the freshly generated version is sitting in it. Saying the
    /// file is missing from the export would send Dan looking for something
    /// that is there, so the notice may only claim what actually happened,
    /// which is that his approved version was not the one used.
    func testTheNoticeSaysTheApprovalWasNotUsedNotThatAFileIsMissing() throws {
        let notice = try XCTUnwrap(PreviewMergePolicy.substitutionNotice([
            PreviewMergePolicy.AbsentApproval(label: "Wednesday collage.png",
                                              fileName: "collage.png")
        ]))

        XCTAssertTrue(notice.contains("collage.png"), notice)
        XCTAssertTrue(notice.lowercased().contains("approved"), notice)
        XCTAssertFalse(notice.lowercased().contains("missing from"),
                       "the folder is not short a file, so the notice must not say it is: \(notice)")
    }

    func testADayWithNoApprovedPreviewsAtAllReportsNothing() {
        XCTAssertTrue(PreviewMergePolicy.absentApprovals(assets: nil, label: "Friday").isEmpty)
        XCTAssertTrue(PreviewMergePolicy.absentApprovals(assets: [:], label: "Friday").isEmpty)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-merge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("asset".utf8).write(to: url)
        return url
    }
}
