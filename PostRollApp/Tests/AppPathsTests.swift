import XCTest

/// Pins the data directory override contract (issue #34): every store
/// resolves its path through AppPaths, and POSTROLL_DATA_DIR redirects the
/// whole tree so tests and UI automation can never touch live data.
final class AppPathsTests: XCTestCase {

    func testDefaultRootIsDocumentsPostRoll() {
        let root = AppPaths.resolveRoot(environment: [:])
        XCTAssertEqual(
            root,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/PostRoll")
        )
    }

    func testOverrideRedirectsRoot() {
        let root = AppPaths.resolveRoot(environment: ["POSTROLL_DATA_DIR": "/tmp/postroll-sandbox"])
        XCTAssertEqual(root.path, "/tmp/postroll-sandbox")
    }

    func testBlankOverrideFallsBackToDefault() {
        let root = AppPaths.resolveRoot(environment: ["POSTROLL_DATA_DIR": "   "])
        XCTAssertEqual(
            root,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/PostRoll")
        )
    }

    func testDerivedPathsHangOffRoot() {
        XCTAssertEqual(AppPaths.eventsFile, AppPaths.root.appendingPathComponent("events.json"))
        XCTAssertEqual(AppPaths.analyticsFile, AppPaths.root.appendingPathComponent("analytics.json"))
        XCTAssertEqual(AppPaths.programsDir, AppPaths.root.appendingPathComponent("programs"))
        XCTAssertEqual(AppPaths.photosDir, AppPaths.root.appendingPathComponent("photos"))
        XCTAssertEqual(AppPaths.audioDir, AppPaths.root.appendingPathComponent("audio"))
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
}
