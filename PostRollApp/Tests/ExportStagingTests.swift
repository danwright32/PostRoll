import XCTest

/// #442: a re-export deleted the whole previous export folder before a single
/// replacement file existed, so any failure partway through had already
/// destroyed the last complete uploadable export (L5).
final class ExportStagingTests: XCTestCase {
    private var root: URL!
    private var final: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportStaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        final = root.appendingPathComponent("Org_Show_2026-01-01")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// A complete previous export: a day folder with a reel in it, plus the
    /// week's captions.
    private func writePreviousExport() throws {
        let day = final.appendingPathComponent("3. Wednesday")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data("the reel Dan already uploaded".utf8)
            .write(to: day.appendingPathComponent("reel.mp4"))
        try "the captions".write(to: final.appendingPathComponent("CAPTIONS.txt"),
                                 atomically: true, encoding: .utf8)
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func entries(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: - The previous export survives until the new one exists

    func testTheOldExportIsStillThereWhileTheNewOneIsBeingBuilt() throws {
        try writePreviousExport()

        let staging = try ExportStaging.begin(finalFolder: final)
        try Data("half a reel".utf8)
            .write(to: staging.workingFolder.appendingPathComponent("partial.mp4"))

        // The moment that matters: the new export is half written and the old
        // one is complete and untouched. This is what a crash here leaves.
        XCTAssertEqual(try contents(final.appendingPathComponent("3. Wednesday/reel.mp4")),
                       "the reel Dan already uploaded")
        XCTAssertEqual(try contents(final.appendingPathComponent("CAPTIONS.txt")), "the captions")
    }

    func testAnAbandonedRunLeavesTheOldExportAndNoDebris() throws {
        try writePreviousExport()

        let staging = try ExportStaging.begin(finalFolder: final)
        try Data("half a reel".utf8)
            .write(to: staging.workingFolder.appendingPathComponent("partial.mp4"))
        staging.abandon()

        XCTAssertEqual(try contents(final.appendingPathComponent("CAPTIONS.txt")), "the captions")
        // Debris here is debris in the folder Dan picked, and it would sit
        // beside the export he is about to upload.
        XCTAssertEqual(entries(of: root), ["Org_Show_2026-01-01"])
    }

    func testCommitSwapsTheNewExportInAndClearsUpAfterItself() throws {
        try writePreviousExport()

        let staging = try ExportStaging.begin(finalFolder: final)
        try "the new captions".write(to: staging.workingFolder.appendingPathComponent("CAPTIONS.txt"),
                                     atomically: true, encoding: .utf8)
        try staging.commit()

        XCTAssertEqual(try contents(final.appendingPathComponent("CAPTIONS.txt")), "the new captions")
        XCTAssertEqual(entries(of: root), ["Org_Show_2026-01-01"],
                       "the swap left the displaced copy or the staging folder behind")
        // A full export rebuilds from scratch, so the previous run's files must
        // not survive into the new folder.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("3. Wednesday/reel.mp4").path))
    }

    func testAFirstExportNeedsNoPreviousFolder() throws {
        let staging = try ExportStaging.begin(finalFolder: final)
        try "captions".write(to: staging.workingFolder.appendingPathComponent("CAPTIONS.txt"),
                             atomically: true, encoding: .utf8)
        try staging.commit()

        XCTAssertEqual(try contents(final.appendingPathComponent("CAPTIONS.txt")), "captions")
        XCTAssertEqual(entries(of: root), ["Org_Show_2026-01-01"])
    }

    // MARK: - A scoped re-export keeps the days it is not rebuilding

    func testAScopedReExportKeepsEveryDayItIsNotRebuilding() throws {
        try writePreviousExport()
        let monday = final.appendingPathComponent("1. Monday")
        try FileManager.default.createDirectory(at: monday, withIntermediateDirectories: true)
        try "monday story".write(to: monday.appendingPathComponent("story.png"),
                                 atomically: true, encoding: .utf8)

        let staging = try ExportStaging.begin(finalFolder: final, rebuilding: ["3. Wednesday"])

        // Wednesday is cleared so its rebuild cannot inherit stale files, and
        // nothing else is.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staging.workingFolder.appendingPathComponent("3. Wednesday").path))
        XCTAssertEqual(try contents(staging.workingFolder.appendingPathComponent("1. Monday/story.png")),
                       "monday story")
        XCTAssertEqual(try contents(staging.workingFolder.appendingPathComponent("CAPTIONS.txt")),
                       "the captions")

        try "new wednesday".write(
            to: staging.workingFolder.appendingPathComponent("wednesday.txt"),
            atomically: true, encoding: .utf8)
        try staging.commit()

        XCTAssertEqual(try contents(final.appendingPathComponent("1. Monday/story.png")), "monday story")
        XCTAssertEqual(try contents(final.appendingPathComponent("wednesday.txt")), "new wednesday")
    }

    // MARK: - A swap that cannot happen loses nothing

    func testAFailedSwapKeepsBothTheOldExportAndTheNewWork() throws {
        try XCTSkipIf(getuid() == 0, "permission based tests are meaningless as root")
        try writePreviousExport()
        let staging = try ExportStaging.begin(finalFolder: final)
        try "the new captions".write(to: staging.workingFolder.appendingPathComponent("CAPTIONS.txt"),
                                     atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        }

        do {
            try staging.commit()
            XCTFail("a swap into a folder it cannot write to reported success")
        } catch let failure as ExportStaging.SwapFailure {
            // The run really did the work, so the error has to name where it is
            // rather than just saying the export failed (L11).
            XCTAssertEqual(failure.stagedAt, staging.workingFolder)
            XCTAssertEqual(try contents(failure.stagedAt.appendingPathComponent("CAPTIONS.txt")),
                           "the new captions")
        }

        // And the previous export is back where it was, not left renamed.
        XCTAssertEqual(try contents(final.appendingPathComponent("CAPTIONS.txt")), "the captions")
    }

    // MARK: - Debris from a run that never finished

    /// A staging folder is only cleaned up when the run ends. A crash or a
    /// force quit ends nothing, so the folder stays in the person's own export
    /// destination holding a full part-built copy, and nothing removes it.
    private func stalePostRollFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix(".postroll-export-") }
            .sorted()
    }

    func testAStagingFolderLeftByACrashedRunIsClearedByTheNextExport() throws {
        // What a force quit mid-export leaves: the folder, its part-built
        // contents, and no process that knows about it.
        let orphan = root.appendingPathComponent(".postroll-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: orphan.appendingPathComponent("Org_Show_2026-01-01"),
            withIntermediateDirectories: true)
        try Data("half an export".utf8)
            .write(to: orphan.appendingPathComponent("Org_Show_2026-01-01/partial.mp4"))

        let staging = try ExportStaging.begin(finalFolder: final)
        defer { staging.abandon() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path),
                       "the crashed run's folder is still taking up space")
    }

    func testAnExportRunningRightNowIsNotSweptAwayByAnother() throws {
        // Two events can export into one destination at the same time. Deleting
        // "any staging folder" would take the other run's work with it, turning
        // a tidy-up into the incident.
        let live = try ExportStaging.begin(finalFolder: root.appendingPathComponent("Other_Show_2026-02-02"))
        defer { live.abandon() }
        try Data("in flight".utf8)
            .write(to: live.workingFolder.appendingPathComponent("reel.mp4"))

        let second = try ExportStaging.begin(finalFolder: final)
        defer { second.abandon() }

        XCTAssertEqual(try contents(live.workingFolder.appendingPathComponent("reel.mp4")),
                       "in flight",
                       "a concurrent export deleted the other one's staged work")
    }

    func testACommittedRunLeavesNothingForTheNextSweep() throws {
        let staging = try ExportStaging.begin(finalFolder: final)
        try "captions".write(to: staging.workingFolder.appendingPathComponent("CAPTIONS.txt"),
                             atomically: true, encoding: .utf8)
        try staging.commit()

        XCTAssertTrue(stalePostRollFolders().isEmpty, stalePostRollFolders().description)
    }
}
