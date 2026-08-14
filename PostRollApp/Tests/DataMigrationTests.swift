import XCTest

/// Pins the move of user data out of the TCC-protected ~/Documents folder into
/// Application Support. The path rewrite is the risky part — it must rebase both
/// the percent-encoded `file://` form (Codable URLs + dict keys) and plain-path
/// strings, for photos/programs/audio AND the regeneratable preview graphics
/// (which now live under the data root too), while leaving the Python project's
/// own subpaths (venv, logs) alone. Completion is gated on a verified copy via a
/// marker file so a denied/partial migration keeps reading from Documents.
final class DataMigrationTests: XCTestCase {

    private let legacy = URL(fileURLWithPath: "/Users/test/Documents/PostRoll")
    private let data   = URL(fileURLWithPath: "/Users/test/Library/Application Support/PostRoll")

    /// EventStore writes JSON with forward slashes escaped as `\/`. The first
    /// cut of this migration searched for unescaped `/`, matched nothing, and
    /// left references dangling — this pins the real on-disk format (raw strings
    /// so `\/` is literal) for both the file:// and plain-path encodings.
    func testRebaseRewritesEscapedSlashOnDiskFormat() {
        let json = #"""
        {"editedPhotoPath":"file:\/\/\/Users\/test\/Documents\/PostRoll\/photos\/Reverence%20&%20Resistance.jpg","photo_path":"\/Users\/test\/Documents\/PostRoll\/photos\/Reverence & Resistance.jpg","audioPath":"file:\/\/\/Users\/test\/Documents\/PostRoll\/audio\/song.mp3","programImagePaths":["file:\/\/\/Users\/test\/Documents\/PostRoll\/programs\/p1.png"],"previewMediaPaths":{"sunday":{"story":"\/Users\/test\/Documents\/PostRoll\/preview\/x\/story.png"}},"photoTags":{"file:\/\/\/Users\/test\/Documents\/PostRoll\/photos\/Reverence%20&%20Resistance.jpg":["Jane"]}}
        """#
        let out = DataMigration.rebasePaths(in: json, from: legacy, to: data)

        // file:// form (escaped slashes) → new root, space percent-encoded.
        XCTAssertTrue(out.contains(#"file:\/\/\/Users\/test\/Library\/Application%20Support\/PostRoll\/photos\/Reverence%20&%20Resistance.jpg"#))
        // plain-path form (escaped slashes) → literal-space new root.
        XCTAssertTrue(out.contains(#"\/Users\/test\/Library\/Application Support\/PostRoll\/photos\/Reverence & Resistance.jpg"#))
        // programs + audio + the photoTags dict key rebased too.
        XCTAssertTrue(out.contains(#"Application%20Support\/PostRoll\/audio\/song.mp3"#))
        XCTAssertTrue(out.contains(#"Application%20Support\/PostRoll\/programs\/p1.png"#))
        // preview now lives under the data root too, so it must rebase.
        XCTAssertTrue(out.contains(#"\/Users\/test\/Library\/Application Support\/PostRoll\/preview\/x\/story.png"#))
        // nothing under the moved subfolders still points at Documents.
        XCTAssertFalse(out.contains(#"Documents\/PostRoll\/photos"#))
        XCTAssertFalse(out.contains(#"Documents\/PostRoll\/audio"#))
        XCTAssertFalse(out.contains(#"Documents\/PostRoll\/programs"#))
        XCTAssertFalse(out.contains(#"Documents\/PostRoll\/preview"#))
    }

    /// Also handles unescaped slashes (e.g. paths from other tooling).
    func testRebaseRewritesUnescapedForm() {
        let json = "{\"p\":\"file:///Users/test/Documents/PostRoll/photos/a.jpg\"}"
        let out = DataMigration.rebasePaths(in: json, from: legacy, to: data)
        XCTAssertTrue(out.contains("file:///Users/test/Library/Application%20Support/PostRoll/photos/a.jpg"))
        XCTAssertFalse(out.contains("Documents/PostRoll/photos"))
    }

    /// Regression for the double-encoding bug: when the roots are REAL on-disk
    /// directories, URL(fileURLWithPath:) appended a trailing slash, the precise
    /// file:// match missed, and the plain-path pass corrupted the URL — a later
    /// save re-encoded "%20" into "%2520", breaking every filename. The original
    /// test missed this because its fake paths don't exist (no trailing slash).
    func testRebaseDoesNotDoubleEncodeWithRealDirectories() throws {
        let fm = FileManager.default
        let base = try tmpDir()
        defer { try? fm.removeItem(at: base) }
        let legacyRoot = base.appendingPathComponent("Documents/PostRoll")
        let appRoot = base.appendingPathComponent("Application Support/PostRoll") // space, like the real path
        try fm.createDirectory(at: legacyRoot.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try fm.createDirectory(at: appRoot.appendingPathComponent("photos"), withIntermediateDirectories: true)

        // A photo URL exactly as Codable writes it: percent-encoded file:// form.
        let legacyURL = URL(fileURLWithPath: legacyRoot.path)
            .appendingPathComponent("photos/My Song & More.jpg").absoluteString
        let json = "{\"p\":\"\(legacyURL)\"}"

        let out = DataMigration.rebasePaths(in: json, from: legacyRoot, to: appRoot)

        XCTAssertFalse(out.contains("%2520"), "filenames must not be double-encoded")
        XCTAssertFalse(out.contains("\(legacyRoot.path)/photos"), "the legacy root must be gone")
        // Must round-trip to the real on-disk App Support path (single-encoded).
        let expected = URL(fileURLWithPath: appRoot.path)
            .appendingPathComponent("photos/My Song & More.jpg").absoluteString
        XCTAssertTrue(out.contains(expected), "rebased URL must be a valid single-encoded path; got \(out)")
    }

    // MARK: - End-to-end move

    private func tmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var markerName: String { AppPaths.migrationMarker }

    func testMigrateCopiesMediaAndRewritesEventsAndMarks() throws {
        let fm = FileManager.default
        let base = try tmpDir()
        defer { try? fm.removeItem(at: base) }
        let legacyRoot = base.appendingPathComponent("Documents/PostRoll")
        let dataRoot = base.appendingPathComponent("AppSupport/PostRoll")
        let photos = legacyRoot.appendingPathComponent("photos")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        fm.createFile(atPath: photos.appendingPathComponent("shot.jpg").path, contents: Data("x".utf8))
        let eventsJSON = "{\"p\":\"file://\(legacyRoot.path)/photos/shot.jpg\"}"
        try eventsJSON.write(to: legacyRoot.appendingPathComponent("events.json"), atomically: true, encoding: .utf8)

        DataMigration.migrateIfNeeded(appSupportRoot: dataRoot, legacyRoot: legacyRoot, environment: [:])

        // Photos copied across; the legacy original stays as a fallback.
        XCTAssertTrue(fm.fileExists(atPath: dataRoot.appendingPathComponent("photos/shot.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: photos.appendingPathComponent("shot.jpg").path),
                      "the legacy original must survive (copy, not move)")
        // New events.json written and rebased to the new root.
        let migrated = try String(contentsOf: dataRoot.appendingPathComponent("events.json"), encoding: .utf8)
        XCTAssertTrue(migrated.contains("\(dataRoot.path)/photos/shot.jpg"))
        XCTAssertFalse(migrated.contains("\(legacyRoot.path)/photos"))
        XCTAssertTrue(fm.fileExists(atPath: legacyRoot.appendingPathComponent("events.json").path))
        // The marker is written only once the verified copy completes.
        XCTAssertTrue(fm.fileExists(atPath: dataRoot.appendingPathComponent(markerName).path),
                      "a fully verified migration must drop the completion marker")
    }

    func testFreshInstallMarksWithoutLegacyData() throws {
        let fm = FileManager.default
        let base = try tmpDir()
        defer { try? fm.removeItem(at: base) }
        let legacyRoot = base.appendingPathComponent("Documents/PostRoll")  // never created
        let dataRoot = base.appendingPathComponent("AppSupport/PostRoll")

        DataMigration.migrateIfNeeded(appSupportRoot: dataRoot, legacyRoot: legacyRoot, environment: [:])

        XCTAssertTrue(fm.fileExists(atPath: dataRoot.appendingPathComponent(markerName).path),
                      "a fresh install with no legacy data should claim App Support immediately")
    }

    func testMigrateIsNoOpWhenMarkerPresent() throws {
        let fm = FileManager.default
        let base = try tmpDir()
        defer { try? fm.removeItem(at: base) }
        let legacyRoot = base.appendingPathComponent("Documents/PostRoll")
        let dataRoot = base.appendingPathComponent("AppSupport/PostRoll")
        try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try "{\"old\":1}".write(to: legacyRoot.appendingPathComponent("events.json"), atomically: true, encoding: .utf8)
        try "{\"new\":1}".write(to: dataRoot.appendingPathComponent("events.json"), atomically: true, encoding: .utf8)
        // Simulate an already-completed migration.
        fm.createFile(atPath: dataRoot.appendingPathComponent(markerName).path, contents: nil)

        DataMigration.migrateIfNeeded(appSupportRoot: dataRoot, legacyRoot: legacyRoot, environment: [:])

        let kept = try String(contentsOf: dataRoot.appendingPathComponent("events.json"), encoding: .utf8)
        XCTAssertEqual(kept, "{\"new\":1}", "a migrated data root must not be overwritten")
    }

    func testMigrateRetriesWhenMarkerAbsent() throws {
        // Without the marker, an earlier App Support events.json is treated as
        // non-authoritative and is overwritten by a fresh verified migration —
        // this is what lets a partial/denied first attempt self-heal.
        let fm = FileManager.default
        let base = try tmpDir()
        defer { try? fm.removeItem(at: base) }
        let legacyRoot = base.appendingPathComponent("Documents/PostRoll")
        let dataRoot = base.appendingPathComponent("AppSupport/PostRoll")
        let photos = legacyRoot.appendingPathComponent("photos")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        fm.createFile(atPath: photos.appendingPathComponent("shot.jpg").path, contents: Data("x".utf8))
        try "{\"p\":\"file://\(legacyRoot.path)/photos/shot.jpg\"}"
            .write(to: legacyRoot.appendingPathComponent("events.json"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try "{\"stale\":1}".write(to: dataRoot.appendingPathComponent("events.json"), atomically: true, encoding: .utf8)

        DataMigration.migrateIfNeeded(appSupportRoot: dataRoot, legacyRoot: legacyRoot, environment: [:])

        let migrated = try String(contentsOf: dataRoot.appendingPathComponent("events.json"), encoding: .utf8)
        XCTAssertTrue(migrated.contains("\(dataRoot.path)/photos/shot.jpg"),
                      "a markerless data root is re-migrated, not trusted")
        XCTAssertTrue(fm.fileExists(atPath: dataRoot.appendingPathComponent(markerName).path))
    }

    func testDoesNotMarkWhenLegacyEventsUnreadable() throws {
        // Regression: a TCC-denied (or otherwise unreadable) legacy events.json
        // must NOT be treated as "no legacy data" and stamped complete — that
        // shipped a half-migrated library. Simulate an unreadable file with a
        // directory where events.json is expected: the read fails with a
        // non-"no such file" error, so the marker must stay absent and migration
        // retry. (The genuinely-absent case is covered by the fresh-install test.)
        let fm = FileManager.default
        let base = try tmpDir()
        defer { try? fm.removeItem(at: base) }
        let legacyRoot = base.appendingPathComponent("Documents/PostRoll")
        let dataRoot = base.appendingPathComponent("AppSupport/PostRoll")
        try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        // events.json is a DIRECTORY → String(contentsOf:) fails, but not with
        // NSFileReadNoSuchFileError.
        try fm.createDirectory(at: legacyRoot.appendingPathComponent("events.json"),
                               withIntermediateDirectories: true)

        DataMigration.migrateIfNeeded(appSupportRoot: dataRoot, legacyRoot: legacyRoot, environment: [:])

        XCTAssertFalse(fm.fileExists(atPath: dataRoot.appendingPathComponent(markerName).path),
                       "an unreadable legacy events.json must not mark the migration complete")
    }

    // MARK: - Absent, in either spelling the system uses (#439)
    //
    // The end-to-end tests above cover the two outcomes, but each can only
    // produce one spelling of "not there" from a real filesystem. The decision
    // itself is asserted against both, because recognising only one of them means
    // a fresh install is read as "not allowed yet" and the marker is never
    // written, so the migration retries on every launch forever.

    func testAnAbsentLegacyStoreIsRecognisedInEitherSpelling() {
        for error in [NSError(domain: NSCocoaErrorDomain,
                              code: NSFileReadNoSuchFileError, userInfo: nil),
                      NSError(domain: NSPOSIXErrorDomain,
                              code: Int(ENOENT), userInfo: nil)] {
            XCTAssertTrue(DataMigration.legacyStoreIsAbsent(error),
                          "\(error.domain) \(error.code) has to read as a fresh install")
        }
    }

    func testARefusedLegacyStoreIsNotCountedAsAbsent() {
        // The half-migrated library this exists to prevent: anything other than
        // "not there" must leave the marker unwritten and retry.
        for error in [NSError(domain: NSCocoaErrorDomain,
                              code: NSFileReadNoPermissionError, userInfo: nil),
                      NSError(domain: NSPOSIXErrorDomain,
                              code: Int(EACCES), userInfo: nil),
                      NSError(domain: NSPOSIXErrorDomain,
                              code: Int(EIO), userInfo: nil)] {
            XCTAssertFalse(DataMigration.legacyStoreIsAbsent(error),
                           "\(error.domain) \(error.code) was mistaken for a fresh install")
        }
    }

    func testMigrateSkippedUnderDataDirOverride() throws {
        let fm = FileManager.default
        let base = try tmpDir()
        defer { try? fm.removeItem(at: base) }
        let legacyRoot = base.appendingPathComponent("Documents/PostRoll")
        let dataRoot = base.appendingPathComponent("AppSupport/PostRoll")
        try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try "{}".write(to: legacyRoot.appendingPathComponent("events.json"), atomically: true, encoding: .utf8)

        DataMigration.migrateIfNeeded(appSupportRoot: dataRoot, legacyRoot: legacyRoot,
                                      environment: ["POSTROLL_DATA_DIR": "/tmp/sandbox"])

        XCTAssertFalse(fm.fileExists(atPath: dataRoot.appendingPathComponent("events.json").path),
                       "a redirected data dir (tests/automation) must skip migration")
    }

    // MARK: - #443: a truncated copy is not a migrated file

    /// The migration is idempotent by skipping files already at the
    /// destination, which is right, but it judged that on EXISTENCE. A copy
    /// interrupted part way leaves a short file there; the re-run skipped it as
    /// done, the completion marker was stamped, and LegacyDataReclaim was then
    /// free to delete the intact original, leaving the truncated copy as the
    /// only one (L40).

    func testAPartialCopyAtTheDestinationIsReplacedRatherThanSkipped() throws {
        let fm = FileManager.default
        let base = try tmpDir()
        defer { try? fm.removeItem(at: base) }
        let legacyRoot = base.appendingPathComponent("Documents/PostRoll")
        let dataRoot = base.appendingPathComponent("AppSupport/PostRoll")

        let photos = legacyRoot.appendingPathComponent("photos")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let whole = "the whole photo, every byte of it"
        try Data(whole.utf8).write(to: photos.appendingPathComponent("shot.jpg"))
        try "{}".write(to: legacyRoot.appendingPathComponent("events.json"),
                       atomically: true, encoding: .utf8)

        // What an interrupted copy leaves behind.
        let landed = dataRoot.appendingPathComponent("photos/shot.jpg")
        try fm.createDirectory(at: landed.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("the whol".utf8).write(to: landed)

        DataMigration.migrateIfNeeded(appSupportRoot: dataRoot, legacyRoot: legacyRoot,
                                      environment: [:])

        XCTAssertEqual(try String(contentsOf: landed, encoding: .utf8), whole,
                       "the truncated copy was accepted as already migrated, and the "
                       + "intact original is now free to be reclaimed")
    }

    func testAFileAlreadyFullyCopiedIsLeftAlone() throws {
        let fm = FileManager.default
        let base = try tmpDir()
        defer { try? fm.removeItem(at: base) }
        let legacyRoot = base.appendingPathComponent("Documents/PostRoll")
        let dataRoot = base.appendingPathComponent("AppSupport/PostRoll")

        let photos = legacyRoot.appendingPathComponent("photos")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("same length!".utf8).write(to: photos.appendingPathComponent("shot.jpg"))
        try "{}".write(to: legacyRoot.appendingPathComponent("events.json"),
                       atomically: true, encoding: .utf8)

        let landed = dataRoot.appendingPathComponent("photos/shot.jpg")
        try fm.createDirectory(at: landed.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("same length!".utf8).write(to: landed)
        let before = try fm.attributesOfItem(atPath: landed.path)[.modificationDate] as? Date

        DataMigration.migrateIfNeeded(appSupportRoot: dataRoot, legacyRoot: legacyRoot,
                                      environment: [:])

        let after = try fm.attributesOfItem(atPath: landed.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after,
                       "a file already migrated was copied again, so every launch "
                       + "would rewrite the whole library")
    }

    func testAnUnreadableSizeCountsAsNotYetCopied() throws {
        // Unknown must land on the side that copies again, never the side that
        // skips and leaves whatever is there (L50).
        let fm = FileManager.default
        let base = try tmpDir()
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: source)

        XCTAssertFalse(DataMigration.sameFile(source, base.appendingPathComponent("nope.jpg"),
                                              fm: fm))
    }
}
