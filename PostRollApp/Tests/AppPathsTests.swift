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

    // MARK: - Where the Python checkout is (#648)
    //
    // These pin the RULE, not one machine's absolute path: the checkout is
    // wherever this build was made from, recorded into the bundle at build
    // time. The old rule was a fixed `~/Documents/PostRoll`, and when the
    // project moved out of iCloud Drive on 2026-08-16 every generation, the
    // watermark asset and the brand-voice seed resolved under a folder that
    // does not exist. A hardcoded absolute path that can move is the defect;
    // pointing the same hardcode somewhere new would only reschedule it.

    func testProjectRootIsWhereThisBuildWasMadeFrom() {
        let root = AppPaths.resolveProjectRoot(
            environment: [:], recorded: "/Volumes/Work/Apps/PostRoll")
        XCTAssertEqual(root?.path, "/Volumes/Work/Apps/PostRoll")
    }

    /// The build records `$(SRCROOT)/..`, which is the app folder's parent
    /// spelled with a `..` in it. Resolving that is what makes the recording
    /// survive being read back as a path.
    func testRecordedProjectRootIsResolvedNotStoredLiterally() {
        let root = AppPaths.resolveProjectRoot(
            environment: [:], recorded: "/Volumes/Work/Apps/PostRoll/PostRollApp/..")
        XCTAssertEqual(root?.path, "/Volumes/Work/Apps/PostRoll")
    }

    /// No recording means no answer. It must NOT fall back to a home-relative
    /// guess: a guess is indistinguishable from a real location to every caller
    /// downstream, and that is exactly how #648 stayed silent.
    func testProjectRootIsUnknownWhenTheBuildRecordedNothing() {
        XCTAssertNil(AppPaths.resolveProjectRoot(environment: [:], recorded: nil))
        XCTAssertNil(AppPaths.resolveProjectRoot(environment: [:], recorded: "   "))
    }

    func testProjectRootOverrideBeatsTheRecordedPath() {
        let root = AppPaths.resolveProjectRoot(
            environment: ["POSTROLL_PROJECT_DIR": "/tmp/postroll-code"],
            recorded: "/Volumes/Work/Apps/PostRoll")
        XCTAssertEqual(root?.path, "/tmp/postroll-code")
    }

    func testBlankProjectRootOverrideFallsBackToTheRecordedPath() {
        let root = AppPaths.resolveProjectRoot(
            environment: ["POSTROLL_PROJECT_DIR": "   "],
            recorded: "/Volumes/Work/Apps/PostRoll")
        XCTAssertEqual(root?.path, "/Volumes/Work/Apps/PostRoll")
    }

    // MARK: - Saying so when the checkout cannot be reached (#648)
    //
    // Three distinct causes, three distinct answers (L11). Before this, all
    // three arrived as `.fileMissing` from the shell's own `cd` failure and
    // told Dan to check that his PHOTOS had not moved.

    func testNoRecordedCheckoutIsItsOwnProblem() {
        XCTAssertEqual(AppPaths.projectRootProblem(nil), .notRecorded)
    }

    func testAnAbsentCheckoutIsNamedAsAbsent() throws {
        let gone = URL(fileURLWithPath: "/tmp/postroll-gone-\(UUID().uuidString)")
        XCTAssertEqual(AppPaths.projectRootProblem(gone), .missing(gone))
    }

    func testAFolderWithoutThePythonPackageIsNotACheckout() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pr-empty-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        XCTAssertEqual(AppPaths.projectRootProblem(dir), .notACheckout(dir))
    }

    /// A checkout is only usable with the Python environment inside it, which
    /// is what the app actually runs (#651), so the fixture builds both.
    func testARealCheckoutHasNoProblem() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pr-checkout-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("postroll"),
                               withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("venv/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("python3"))
        defer { try? fm.removeItem(at: dir) }
        XCTAssertNil(AppPaths.projectRootProblem(dir))
    }

    /// The whole point of the named failure: the sentence has to name the
    /// checkout and the path it looked in, and must not send Dan to his photos.
    ///
    /// "must not blame the photos" is checked as "does not carry the photo
    /// screen's advice", not as "does not contain the word photo". The message
    /// deliberately DOES say his photos are not affected, which is the opposite
    /// of blaming them and is worth saying to someone reading that the app
    /// cannot find part of itself.
    func testTheMessageNamesTheCheckoutAndThePathItLookedIn() {
        let gone = URL(fileURLWithPath: "/Volumes/Work/Apps/PostRoll")
        let text = ProjectRootText.message(.missing(gone))
        XCTAssertTrue(text.contains("/Volumes/Work/Apps/PostRoll"),
                      "the message must name the path it looked in, got: \(text)")
        assertDoesNotSendDanToThePhotoScreen(text)
    }

    /// The advice that made #648 worse than a bare failure: Dan was told to
    /// re-assign photos that were never the problem.
    private func assertDoesNotSendDanToThePhotoScreen(
        _ text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let s = text.lowercased()
        for advice in ["re-assign", "reassign", "original locations", "photo screen"] {
            XCTAssertFalse(s.contains(advice),
                           "sends Dan to the photo screen over a missing code folder: \(text)",
                           file: file, line: line)
        }
    }

    func testEachProblemGetsItsOwnMessage() {
        let dir = URL(fileURLWithPath: "/Volumes/Work/Apps/PostRoll")
        let messages = [
            ProjectRootText.message(.notRecorded),
            ProjectRootText.message(.missing(dir)),
            ProjectRootText.message(.notACheckout(dir)),
            ProjectRootText.message(.noEnvironment(dir)),
        ]
        XCTAssertEqual(Set(messages).count, 4, "distinct causes need distinct messages")
    }

    /// The three problems about the FOLDER name it the same way. Without this,
    /// the sentence a caller gets depends on which cause it hit, and a test
    /// asserting the message names the code folder passes or fails on the
    /// machine's state rather than on the code (L118).
    ///
    /// `noEnvironment` is deliberately not in this list. Its subject genuinely
    /// is something else: the folder is present and correct, and what is
    /// missing is the Python environment inside it. Calling that a code folder
    /// problem would be the same word for two different things.
    func testEveryProblemAboutTheFolderCallsItTheCodeFolder() {
        let dir = URL(fileURLWithPath: "/Volumes/Work/Apps/PostRoll")
        for problem: AppPaths.ProjectRootProblem in [.notRecorded, .missing(dir), .notACheckout(dir)] {
            XCTAssertTrue(ProjectRootText.message(problem).lowercased().contains("code folder"),
                          "\(problem) does not call it the code folder")
        }
        XCTAssertTrue(
            ProjectRootText.message(.noEnvironment(dir)).lowercased().contains("environment"),
            "a missing environment must name the environment, not the folder")
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

    // storedClip is the sanctioned way to persist a Friday clip import pick
    // (#135), mirroring storedPhoto/storedAudio: routes through clipsDir so a
    // raw ~/Downloads/~/Desktop URL never reaches PostingDay.clipPaths.
    func testStoredClipRoutesIntoClipsDir() throws {
        let already = AppPaths.clipsDir.appendingPathComponent("already.mov")
        XCTAssertEqual(try AppPaths.storedClip(already).get(), already,
                        "already inside clipsDir: returned unchanged, no duplicate copy")
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
