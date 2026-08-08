import XCTest

/// A picked file is copied into the app's own storage so moving a folder in
/// Finder can't break it. When that copy fails the app used to quietly persist
/// the external path instead, so the import reported success and the event
/// broke days later (#179). The failure has to reach the caller.
final class ImportCopyFailureTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ImportCopyFailureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The app's storage tree, and a place for files that live OUTSIDE it (a
    /// stand-in for ~/Downloads). A "picked" file has to sit outside storage or
    /// importedCopyResult short-circuits and never attempts a copy.
    private var storageRoot: URL { root.appendingPathComponent("storage") }
    private var photosDir: URL { storageRoot.appendingPathComponent("photos") }
    private var outside: URL { root.appendingPathComponent("Downloads") }

    private func makeOutsideFile(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let url = outside.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testSuccessfulCopyReturnsAPathInsideAppStorage() throws {
        let source = try makeOutsideFile("outside.jpg")

        let result = AppPaths.importedCopyResult(of: source, into: photosDir, storageRoot: storageRoot)

        let stored = try result.get()
        XCTAssertTrue(AppPaths.isInside(stored, root: storageRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
    }

    func testFailedCopyReportsAFailureInsteadOfTheExternalPath() {
        // A source that isn't there is a copy that cannot succeed.
        let vanished = outside.appendingPathComponent("gone.jpg")

        let result = AppPaths.importedCopyResult(of: vanished, into: photosDir, storageRoot: storageRoot)

        switch result {
        case .success(let url):
            XCTFail("a failed copy must not hand back a path to persist, got \(url.path)")
        case .failure(let error):
            XCTAssertEqual(error.fileName, "gone.jpg")
            XCTAssertFalse(error.message.isEmpty, "the failure has to say something usable")
        }
    }

    func testAFileAlreadyInsideStorageIsAdoptedNotRecopied() throws {
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let inside = photosDir.appendingPathComponent("already.jpg")
        try Data("x".utf8).write(to: inside)

        let stored = try AppPaths.importedCopyResult(of: inside, into: photosDir, storageRoot: storageRoot).get()

        XCTAssertEqual(stored, inside)
    }

    // MARK: - batch picks

    func testABatchKeepsWhatCopiedAndReportsWhatDidNot() throws {
        let good = try makeOutsideFile("good.jpg")
        let bad = outside.appendingPathComponent("bad.jpg")   // never created

        let outcome = ImportedPicks.copy([good, bad], into: photosDir, storageRoot: storageRoot)

        XCTAssertEqual(outcome.stored.count, 1)
        XCTAssertTrue(AppPaths.isInside(outcome.stored[0], root: storageRoot))
        XCTAssertEqual(outcome.failures.map(\.fileName), ["bad.jpg"])
        XCTAssertNotNil(outcome.failureMessage)
        XCTAssertTrue(try XCTUnwrap(outcome.failureMessage).contains("bad.jpg"))
    }

    func testACleanBatchReportsNoFailure() throws {
        let good = try makeOutsideFile("good.jpg")

        let outcome = ImportedPicks.copy([good], into: photosDir, storageRoot: storageRoot)

        XCTAssertNil(outcome.failureMessage)
        XCTAssertEqual(outcome.stored.count, 1)
    }

    // MARK: - what the user is told

    func testFailureMessageNamesTheFilesAndSaysTheyWereNotImported() {
        let text = ImportFailureText.message([
            AppPaths.ImportCopyFailure(fileName: "a.jpg", message: "no such file"),
            AppPaths.ImportCopyFailure(fileName: "b.jpg", message: "no such file"),
        ])

        XCTAssertTrue(text.contains("a.jpg"), text)
        XCTAssertTrue(text.contains("b.jpg"), text)
        XCTAssertTrue(text.lowercased().contains("not"), "must say they were NOT imported: \(text)")
    }

    func testASingleFailureReadsAsOneFile() {
        let text = ImportFailureText.message([
            AppPaths.ImportCopyFailure(fileName: "a.jpg", message: "no such file")
        ])
        XCTAssertFalse(text.contains("files"), text)
    }

    /// Deliberately NOT adopting a same-named file already in storage: photo
    /// filenames collide across events (importedCopy uniquifies on collision, so
    /// the bare name belongs to whichever event imported it first), and adopting
    /// by name would silently put a different event's photograph in this post.
    /// The Locate flow, where the user names the folder, is the recovery route.
    func testASameNamedFileInStorageIsNotAdoptedForADeadSourcePath() throws {
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let sameName = photosDir.appendingPathComponent("moved.jpg")
        try Data("a different photograph".utf8).write(to: sameName)
        let dead = outside.appendingPathComponent("moved.jpg")

        let result = AppPaths.importedCopyResult(of: dead, into: photosDir, storageRoot: storageRoot)

        switch result {
        case .success(let url): XCTFail("adopted \(url.path) by filename alone")
        case .failure: break
        }
    }
}
