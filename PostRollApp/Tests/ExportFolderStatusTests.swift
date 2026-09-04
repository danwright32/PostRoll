import XCTest

/// #247: the export folder's completeness reaches the app.
///
/// #184 made the manifest the completion signal: written last, and only by a
/// run that lost nothing, so an interrupted run leaves none. `isComplete` and
/// `read` were then called by nothing, so only somebody standing in Finder
/// could use the record, and the field looked alive to any is-this-used check
/// while its purpose silently never happened (L46).
final class ExportFolderStatusTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeDay(_ name: String, files: [String]) throws {
        let dir = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            try Data("x".utf8).write(to: dir.appendingPathComponent(f))
        }
    }

    private func writeManifest(now: Date = Date()) {
        ExportManifest.write(
            ExportManifest.build(folder: folder, preset: .balanced, event: "Test", now: now),
            to: folder)
    }

    // ── the finished case ─────────────────────────────────────────────────────

    func testAFolderWithAManifestIsFinished() throws {
        try makeDay("1. Sunday", files: ["story.png"])
        try Data("captions".utf8).write(to: folder.appendingPathComponent("CAPTIONS.txt"))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        writeManifest(now: when)

        guard case .finished(let at, let count, _) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("a folder holding a manifest is a finished export")
        }
        XCTAssertEqual(at.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(count, 2)
    }

    func testAFinishedExportDoesNotAskForAttention() throws {
        try makeDay("1. Sunday", files: ["story.png"])
        writeManifest()
        XCTAssertFalse(ExportFolderStatus.of(folder: folder).needsAttention,
                       "a banner on every visit to a good export is how a real "
                       + "warning stops being read")
    }

    // ── the case the manifest exists for ──────────────────────────────────────

    func testAFolderWithNoManifestIsUnfinished() throws {
        try makeDay("1. Sunday", files: ["story.png"])

        guard case .unfinished = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("no manifest means the run that made this did not finish")
        }
        XCTAssertTrue(ExportFolderStatus.of(folder: folder).needsAttention)
    }

    func testItNamesTheEmptyDayFolders() throws {
        try makeDay("1. Sunday", files: ["story.png"])
        try makeDay("5. Thursday", files: [])
        try makeDay("6. Friday", files: [])

        guard case .unfinished(_, let empties, _, _) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("expected unfinished")
        }
        XCTAssertEqual(empties, ["5. Thursday", "6. Friday"],
                       "with no manifest there is no record of what was meant to "
                       + "be there, so it reports what is missing NOW")
    }

    func testItNoticesTheCaptionsFileIsAbsent() throws {
        try makeDay("1. Sunday", files: ["story.png"])

        guard case .unfinished(_, _, let hasCaptions, _) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("expected unfinished")
        }
        XCTAssertFalse(hasCaptions)
        let message = try XCTUnwrap(ExportFolderStatus.of(folder: folder).message)
        XCTAssertTrue(message.contains("CAPTIONS.txt"), message)
    }

    func testItCountsTheFilesThatAreThere() throws {
        try makeDay("1. Sunday", files: ["story.png", "cover.png"])
        try Data("captions".utf8).write(to: folder.appendingPathComponent("CAPTIONS.txt"))

        guard case .unfinished(let count, _, let hasCaptions, _) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("expected unfinished")
        }
        XCTAssertEqual(count, 3, "nearly-done and nearly-empty are different situations")
        XCTAssertTrue(hasCaptions)
    }

    // ── the folder itself ─────────────────────────────────────────────────────

    func testAFolderThatIsNoLongerThereIsItsOwnState() {
        let gone = folder.appendingPathComponent("moved-away")
        guard case .lostTrack = ExportFolderStatus.of(folder: gone) else {
            return XCTFail("a missing folder is not an unfinished export")
        }
        XCTAssertTrue(ExportFolderStatus.of(folder: gone).needsAttention)
    }

    // ── #1110: a filed export is not a lost one ──────────────────────────────
    //
    // Measured against the live store on 2026-09-02: 9 of 21 events record an
    // export path and 0 of those 9 folders are at the recorded path, because
    // Dan files every finished export into one of his own Finder buckets
    // afterwards. So the absent path is the ORDINARY state of a finished
    // export here, not a fault, and the warning fired on all 9 of them.

    func testAnAbsentRecordedPathIsNotAWarning() {
        let filed = folder.appendingPathComponent("filed-away")
        XCTAssertEqual(ExportFolderStatus.of(folder: filed).attention, .informational,
                       "Dan files every finished export elsewhere, so a recorded path "
                     + "that is absent fires on every export he has. A warning that is "
                     + "right 0 times out of 9 stops being read (L36).")
    }

    func testItDoesNotClaimTheExportItselfIsGone() throws {
        let filed = folder.appendingPathComponent("filed-away")
        let message = try XCTUnwrap(ExportFolderStatus.of(folder: filed).message)
        XCTAssertTrue(message.contains("lost track"),
                      "an absent path is evidence the app no longer knows where the "
                    + "export is, never that the export was lost (L11): \(message)")
        XCTAssertFalse(message.contains("Export again"),
                       "the folder is very likely sitting finished in one of his "
                     + "buckets, so re-exporting it is work he has already done and "
                     + "the step cannot change the state he is in (L111): \(message)")
    }

    func testItOffersToBePointedAtTheFolderAgain() throws {
        let filed = folder.appendingPathComponent("filed-away")
        let message = try XCTUnwrap(ExportFolderStatus.of(folder: filed).message)
        XCTAssertTrue(message.contains("Point PostRoll at it again"),
                      "the remedy has to be one that actually clears the state, which "
                    + "is re-recording where the folder went: \(message)")
    }

    func testAnAbsentPathNamesTheFolderSoHeCanFindIt() throws {
        let filed = folder.appendingPathComponent("battery_dance_festival_2026-08-14")
        let message = try XCTUnwrap(ExportFolderStatus.of(folder: filed).message)
        XCTAssertTrue(message.contains("battery_dance_festival_2026-08-14"),
                      "a message that names no folder leaves him nothing to search "
                    + "Finder for (L80): \(message)")
    }

    func testARealFaultIsStillAWarning() throws {
        try makeDay("1. Sunday", files: [])
        XCTAssertEqual(ExportFolderStatus.of(folder: folder).attention, .warning,
                       "softening the absent-path case must not soften an export that "
                     + "genuinely did not finish")
    }

    func testAnEventNeverExportedSaysNothing() {
        let event = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        XCTAssertEqual(ExportFolderStatus.of(event), .neverExported)
        XCTAssertNil(ExportFolderStatus.of(event).message)
        XCTAssertFalse(ExportFolderStatus.of(event).needsAttention)
    }

    func testItReadsTheFolderRecordedOnTheEvent() throws {
        try makeDay("1. Sunday", files: ["story.png"])
        writeManifest()
        var event = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        event.exportPath = folder

        guard case .finished = ExportFolderStatus.of(event) else {
            return XCTFail("the event's own folder is the one to read")
        }
    }

    // ── the message ───────────────────────────────────────────────────────────

    func testTheUnfinishedMessageSaysWhatToDo() throws {
        try makeDay("1. Sunday", files: [])
        let message = try XCTUnwrap(ExportFolderStatus.of(folder: folder).message)
        XCTAssertTrue(message.lowercased().contains("export again"), message)
    }

    // testTheMissingFolderMessageSaysWhereItWent was deleted by #1110. Its
    // second half asserted the absent-folder message tells Dan to export
    // again, which is the decision that issue reversed, so keeping it would
    // have left it guarding the defect (L252). Its first half, that the
    // message names the folder, is now
    // testAnAbsentPathNamesTheFolderSoHeCanFindIt above.

    // MARK: - #451: a folder that cannot be read is not one that never finished

    func testAnUnreadableFolderIsNotReportedAsAnUnfinishedExport() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }

        guard case .unreadable = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("an unreadable folder read as \(ExportFolderStatus.of(folder: folder))")
        }
    }

    func testTheUnreadableMessageDoesNotTellDanToExportAgain() {
        guard let message = ExportFolderStatus.unreadable("Permission denied").message else {
            return XCTFail("an unreadable folder says nothing")
        }
        XCTAssertTrue(message.contains("Permission denied"), message)
        XCTAssertTrue(message.lowercased().contains("privacy"),
                      "the message does not name the fix that would work: \(message)")
    }

    func testAnUnreadableFolderIsWorthShowing() {
        XCTAssertTrue(ExportFolderStatus.unreadable("Permission denied").needsAttention)
    }

    /// An empty folder is a real answer: that export genuinely never finished.
    func testAnEmptyReadableFolderStillReadsAsUnfinished() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        guard case .unfinished(let count, _, _, _) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("an empty folder did not read as unfinished")
        }
        XCTAssertEqual(count, 0)
    }

    /// The same defect one level down: a day folder that cannot be listed
    /// would otherwise be counted as zero files and reported as a day the
    /// export lost, which is a different problem with a different fix (#451).
    func testADayFolderThatCannotBeReadIsNotReportedAsAnEmptyOne() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("partly-unreadable-\(UUID().uuidString)")
        let day = folder.appendingPathComponent("sunday")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: day.appendingPathComponent("story.png"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: day.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: day.path)
            try? FileManager.default.removeItem(at: folder)
        }

        guard case .unfinished(_, let empties, _, let unreadable) =
                ExportFolderStatus.of(folder: folder) else {
            return XCTFail("expected an unfinished export")
        }

        XCTAssertEqual(unreadable, ["sunday"])
        XCTAssertFalse(empties.contains("sunday"),
                       "a day nothing could look inside was reported as an empty one")
    }

    func testTheMessageKeepsUnreadableDaysApartFromEmptyOnes() {
        let status = ExportFolderStatus.unfinished(
            fileCount: 3, emptyDayFolders: ["monday"], hasCaptions: true,
            unreadableDayFolders: ["sunday"])

        guard let message = status.message else { return XCTFail("no message") }
        XCTAssertTrue(message.contains("monday is empty"), message)
        XCTAssertTrue(message.contains("sunday could not be read"), message)
    }

    // MARK: - #540: the manifest's own record of what it could not read

    /// The field was written and shown at write time and ignored on the way back
    /// in, so an export whose own record says a day could not be listed still
    /// reported as finished with a clean file count. That is the write-only
    /// field class #490 closed, reintroduced by the fix for its sibling (L46).
    func testAFinishedExportCarriesTheDaysItsManifestCouldNotRead() throws {
        try makeDay("1. Sunday", files: ["story.png"])
        let contents = ExportManifest.Contents(
            exportedAt: Date(), preset: "balanced", event: "Test",
            filesByDay: ["1. Sunday": ["story.png"]], totalFiles: 1,
            unreadableFolders: ["2. Monday": "Permission denied"])
        ExportManifest.write(contents, to: folder)

        guard case .finished(_, _, let unreadable) = ExportFolderStatus.of(folder: folder) else {
            return XCTFail("a folder holding a manifest is a finished export")
        }
        XCTAssertEqual(unreadable, ["2. Monday"])
    }

    /// A count that is missing a day is worth interrupting for. The whole point
    /// of recording the folder was that a certificate must not say something it
    /// never read, and a certificate nobody is shown says it anyway.
    func testAFinishedExportWithAnUnreadDayAsksForAttention() {
        let clean = ExportFolderStatus.finished(exportedAt: Date(), fileCount: 4)
        XCTAssertFalse(clean.needsAttention)

        let partial = ExportFolderStatus.finished(exportedAt: Date(), fileCount: 4,
                                                  unreadableDayFolders: ["2. Monday"])
        XCTAssertTrue(partial.needsAttention,
                      "an export whose own record admits a gap reads as a clean one")
    }

    func testTheFinishedMessageNamesTheDayItCouldNotRead() {
        let status = ExportFolderStatus.finished(exportedAt: Date(), fileCount: 4,
                                                 unreadableDayFolders: ["2. Monday"])
        guard let message = status.message else { return XCTFail("no message") }

        XCTAssertTrue(message.contains("2. Monday"), message)
        XCTAssertTrue(message.lowercased().contains("could not be read"), message)
        // The count has to stop claiming to be the whole export, since the day
        // it could not read is exactly the part it did not count.
        XCTAssertFalse(message.contains("4 files in the folder."),
                       "the count still presents as complete: \(message)")
    }

    func testACleanFinishedExportStillReadsExactlyAsBefore() {
        let status = ExportFolderStatus.finished(exportedAt: Date(), fileCount: 4)
        guard let message = status.message else { return XCTFail("no message") }
        XCTAssertTrue(message.contains("4 files in the folder."), message)
        XCTAssertFalse(message.lowercased().contains("could not be read"), message)
    }

    // MARK: - Which folder a re-export may use without asking (#1048)

    /// The export folder was one app-wide preference, so a brand new show
    /// arrived at the export screen already offering the PREVIOUS show's folder
    /// as a one-click button, and the per-day re-export used it with no picker
    /// at all. Exporting a show into another show's folder overwrites the day
    /// folders already sitting there.
    ///
    /// Dan's requirement, stated on the issue: the export folder starts empty
    /// on every new project and choosing one is a required step, because it is
    /// always a new folder.

    private func event(exportedTo path: URL?) -> Event {
        var e = Event(name: "Show", org: "Org", venue: "Hall",
                      date: Date(timeIntervalSince1970: 1_800_000_000),
                      shootType: .fullShow)
        e.exportPath = path
        return e
    }

    func testANewEventOffersNoFolderAtAll() {
        XCTAssertNil(ExportFolderStatus.rememberedFolder(for: event(exportedTo: nil)),
                     "a show nothing has exported offers a folder, so the fastest "
                     + "button on the screen writes it into somewhere it has never "
                     + "been")
    }

    func testAnEventOffersTheFolderItWasActuallyExportedTo() throws {
        // The positive control (L159). Without it "offers nothing" is satisfied
        // by a fixture where nothing could ever be offered, and the picker
        // would be forced even on the one case where remembering is right:
        // re-exporting the same show into the same place.
        try makeDay("1. Sunday", files: ["story.png"])
        writeManifest()

        XCTAssertEqual(ExportFolderStatus.rememberedFolder(for: event(exportedTo: folder)),
                       folder)
    }

    func testAFolderThatHasBeenFiledAwayIsNotOfferedAgain() {
        // Measured against the live store on 2026-09-02: 9 of 21 events record
        // an export path and 0 of those 9 folders are still at it, because Dan
        // files every finished export into one of his own Finder buckets. So
        // this is the ordinary case rather than the exotic one, and offering a
        // path nothing is at would create the folder on export rather than
        // reuse it.
        let gone = folder.appendingPathComponent("filed-away-somewhere-else")

        XCTAssertNil(ExportFolderStatus.rememberedFolder(for: event(exportedTo: gone)),
                     "a recorded folder nothing is at is still offered, so the "
                     + "one-click export makes a new empty folder at a path Dan "
                     + "moved away from")
    }

    func testAnUnfinishedExportIsStillTheSameShowsFolder() throws {
        // No manifest, so the run did not finish. That is a reason to export
        // again and not a reason to export somewhere else, and this is the one
        // path where re-exporting into the same folder is exactly right.
        try makeDay("1. Sunday", files: ["story.png"])

        XCTAssertEqual(ExportFolderStatus.rememberedFolder(for: event(exportedTo: folder)),
                       folder)
    }

    func testNothingReadsOneExportFolderForEveryShow() {
        // The defect was not the wording, it was the SCOPE, and the scope lives
        // in a shared preference key rather than in any value a test can hold.
        // So this asserts the key is gone from both halves that used it (L46):
        // one writer and one reader, and either left behind puts the previous
        // show's folder back on a new show's screen.
        func source(_ file: String) -> String {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/\(file)")
            return try! String(contentsOf: url, encoding: .utf8)
        }

        for file in ["Views/ExportView.swift", "Services/ExportManager.swift"] {
            XCTAssertFalse(source(file).contains("\"lastExportFolder\""),
                           "\(file) still keys the export folder app wide, so a new "
                           + "show arrives offering the previous show's folder")
        }

        // And the screen asks the per event question instead, or the check
        // above is satisfied by a screen that simply lost the feature (L283).
        XCTAssertTrue(source("Views/ExportView.swift").contains("rememberedFolder"),
                      "the export screen no longer asks which folder THIS event may "
                      + "reuse, so re-exporting the same show into the same place "
                      + "went with the shared key rather than being scoped to it")
    }
}
