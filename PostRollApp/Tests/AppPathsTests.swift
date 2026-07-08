import XCTest

/// Pins the data directory override contract (issue #34): every store
/// resolves its path through AppPaths, and POSTROLL_DATA_DIR redirects the
/// whole tree so tests and UI automation can never touch live data.
final class AppPathsTests: XCTestCase {

    /// FileManager that reports the migration marker present or absent, so the
    /// root-resolution tests don't depend on the real machine's migration state.
    private final class MarkerFM: FileManager {
        let migrated: Bool
        init(migrated: Bool) { self.migrated = migrated; super.init() }
        required init?(coder: NSCoder) { fatalError() }
        override func fileExists(atPath path: String) -> Bool {
            if path.hasSuffix("/" + AppPaths.migrationMarker) { return migrated }
            return super.fileExists(atPath: path)
        }
    }

    func testRootIsLegacyDocumentsUntilMigrated() {
        let root = AppPaths.resolveRoot(environment: [:], fileManager: MarkerFM(migrated: false))
        XCTAssertEqual(
            root,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/PostRoll")
        )
    }

    func testRootIsAppSupportOnceMigrated() {
        let root = AppPaths.resolveRoot(environment: [:], fileManager: MarkerFM(migrated: true))
        XCTAssertEqual(root, AppPaths.appSupportRoot)
    }

    func testOverrideRedirectsRoot() {
        let root = AppPaths.resolveRoot(environment: ["POSTROLL_DATA_DIR": "/tmp/postroll-sandbox"],
                                        fileManager: MarkerFM(migrated: true))
        XCTAssertEqual(root.path, "/tmp/postroll-sandbox")
    }

    func testBlankOverrideFallsBackToDefault() {
        let root = AppPaths.resolveRoot(environment: ["POSTROLL_DATA_DIR": "   "],
                                        fileManager: MarkerFM(migrated: false))
        XCTAssertEqual(
            root,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/PostRoll")
        )
    }

    func testDefaultProjectRootIsDocumentsPostRoll() {
        // The Python checkout (venv, source, logs) stays in the repo.
        let projectRoot = AppPaths.resolveProjectRoot(environment: [:])
        XCTAssertEqual(
            projectRoot,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/PostRoll")
        )
    }

    func testProjectRootOverride() {
        let projectRoot = AppPaths.resolveProjectRoot(environment: ["POSTROLL_PROJECT_DIR": "/tmp/postroll-code"])
        XCTAssertEqual(projectRoot.path, "/tmp/postroll-code")
    }

    func testDerivedPathsHangOffRoot() {
        XCTAssertEqual(AppPaths.eventsFile, AppPaths.root.appendingPathComponent("events.json"))
        XCTAssertEqual(AppPaths.analyticsFile, AppPaths.root.appendingPathComponent("analytics.json"))
        XCTAssertEqual(AppPaths.programsDir, AppPaths.root.appendingPathComponent("programs"))
        XCTAssertEqual(AppPaths.photosDir, AppPaths.root.appendingPathComponent("photos"))
        XCTAssertEqual(AppPaths.audioDir, AppPaths.root.appendingPathComponent("audio"))
        // Clips are large video files with a different size/lifecycle profile
        // than photos, so they get their own directory rather than reusing
        // photosDir (Friday auto-cut clip reel, #131).
        XCTAssertEqual(AppPaths.clipsDir, AppPaths.root.appendingPathComponent("clips"))
        // Logs live under the data root, not the Documents checkout (#56).
        XCTAssertEqual(AppPaths.logsDir, AppPaths.root.appendingPathComponent("logs"))
        XCTAssertEqual(AppPaths.logFile, AppPaths.logsDir.appendingPathComponent("postroll.log"))
    }

    func testProgramPDFFileIsOnePerEventUnderProgramsDir() {
        let id = UUID()
        let url = AppPaths.programPDFFile(eventID: id)
        XCTAssertEqual(url, AppPaths.programsDir.appendingPathComponent("\(id.uuidString)_program.pdf"))
        // Distinct events get distinct files (so the bake and rebuild agree).
        XCTAssertNotEqual(AppPaths.programPDFFile(eventID: UUID()), url)
    }

    // importedCopy keeps picked files out of the macOS-gated Downloads/Desktop
    // by copying them into the app's own storage, so thumbnail/export reads
    // don't re-trigger the permission prompt.

    func testImportedCopyCopiesExternalFile() throws {
        let fm = FileManager.default
        let srcDir = fm.temporaryDirectory.appendingPathComponent("pr-src-\(UUID().uuidString)")
        let destDir = fm.temporaryDirectory.appendingPathComponent("pr-dest-\(UUID().uuidString)")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: srcDir); try? fm.removeItem(at: destDir) }

        let src = srcDir.appendingPathComponent("photo.jpg")
        try Data("hello".utf8).write(to: src)

        let copied = try XCTUnwrap(AppPaths.importedCopy(of: src, into: destDir))
        XCTAssertEqual(copied.deletingLastPathComponent().standardizedFileURL, destDir.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: copied), Data("hello".utf8))
        XCTAssertTrue(fm.fileExists(atPath: src.path), "original is left in place, not moved")
    }

    func testImportedCopyUniquifiesNameCollision() throws {
        let fm = FileManager.default
        let s1 = fm.temporaryDirectory.appendingPathComponent("pr-s1-\(UUID().uuidString)")
        let s2 = fm.temporaryDirectory.appendingPathComponent("pr-s2-\(UUID().uuidString)")
        let dest = fm.temporaryDirectory.appendingPathComponent("pr-d-\(UUID().uuidString)")
        try fm.createDirectory(at: s1, withIntermediateDirectories: true)
        try fm.createDirectory(at: s2, withIntermediateDirectories: true)
        defer { for d in [s1, s2, dest] { try? fm.removeItem(at: d) } }

        let f1 = s1.appendingPathComponent("photo.jpg"); try Data("one".utf8).write(to: f1)
        let f2 = s2.appendingPathComponent("photo.jpg"); try Data("two".utf8).write(to: f2)

        let c1 = try XCTUnwrap(AppPaths.importedCopy(of: f1, into: dest))
        let c2 = try XCTUnwrap(AppPaths.importedCopy(of: f2, into: dest))
        XCTAssertNotEqual(c1, c2, "a same-named second file must not overwrite the first")
        XCTAssertEqual(try Data(contentsOf: c1), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: c2), Data("two".utf8))
    }

    func testImportedCopyLeavesInStorageFilesUnchanged() {
        // Already inside app storage: returned as-is, no duplicate copy made.
        let inside = AppPaths.photosDir.appendingPathComponent("already.jpg")
        XCTAssertEqual(AppPaths.importedCopy(of: inside, into: AppPaths.photosDir), inside)
    }

    func testIsInsideAppStorage() {
        XCTAssertTrue(AppPaths.isInsideAppStorage(AppPaths.photosDir.appendingPathComponent("a.jpg")))
        XCTAssertFalse(AppPaths.isInsideAppStorage(URL(fileURLWithPath: "/tmp/elsewhere/a.jpg")))
    }

    // seedBrandVoice copies the checkout's read-only brand-voice.md into the data
    // root once, so generation reads/writes hit the unprotected location (#46).

    func testSeedBrandVoiceCopiesWhenAbsent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pr-bv-\(UUID().uuidString)")
        let seedDir = fm.temporaryDirectory.appendingPathComponent("pr-seed-\(UUID().uuidString)")
        try fm.createDirectory(at: seedDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: seedDir) }

        let seed = seedDir.appendingPathComponent("brand-voice.md")
        try Data("BASE VOICE".utf8).write(to: seed)

        AppPaths.seedBrandVoice(into: root, from: seed)

        let dest = root.appendingPathComponent("brand-voice.md")
        XCTAssertEqual(try Data(contentsOf: dest), Data("BASE VOICE".utf8))
        XCTAssertTrue(fm.fileExists(atPath: seed.path), "seed is copied, not moved")
    }

    func testSeedBrandVoiceNeverOverwritesExistingCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pr-bv-\(UUID().uuidString)")
        let seedDir = fm.temporaryDirectory.appendingPathComponent("pr-seed-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: seedDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: seedDir) }

        // The writable copy already carries the user's accumulated notes.
        let dest = root.appendingPathComponent("brand-voice.md")
        try Data("ACCUMULATED NOTES".utf8).write(to: dest)
        let seed = seedDir.appendingPathComponent("brand-voice.md")
        try Data("BASE VOICE".utf8).write(to: seed)

        AppPaths.seedBrandVoice(into: root, from: seed)

        XCTAssertEqual(try Data(contentsOf: dest), Data("ACCUMULATED NOTES".utf8),
                       "an existing writable copy must never be overwritten by the seed")
    }

    func testSeedBrandVoiceMissingSeedIsNoOp() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pr-bv-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let missingSeed = fm.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).md")

        AppPaths.seedBrandVoice(into: root, from: missingSeed)

        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("brand-voice.md").path))
    }
}
