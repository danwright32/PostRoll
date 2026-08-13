import XCTest

/// #440 and #505: accounts.json holds numbers Dan typed in by hand that come
/// from nowhere else, and it was the only such store with no backup generations
/// and no way back from a bad file.
@MainActor
final class AccountBookRecoveryTests: XCTestCase {
    private var root: URL!
    private var file: URL!
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    // `setUp() async throws`, not `setUpWithError`: CI builds with Xcode 16.4,
    // where the throwing override is nonisolated and cannot touch these
    // main-actor properties at all. The local Xcode accepts it, so this only
    // shows up in CI.
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountBookRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("accounts.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        // The gate is process-wide and keyed by path, so a blocked temp path
        // from one test must not follow the suite into the next one.
        StoreSaveGate.shared.unblock(file)
        try? FileManager.default.removeItem(at: root)
    }

    private func backups() -> [String] {
        StoreBackups.existing(for: file).map(\.lastPathComponent)
    }

    private func setAsideFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".corrupt-") }
    }

    // MARK: - #440, generations

    func testEachSaveKeepsTheGenerationItIsAboutToReplace() throws {
        let book = AccountBook(fileURL: file)
        book.record(handle: "janecellist", followers: 2_000, likes: 50, comments: 10, on: stamp)
        XCTAssertTrue(backups().isEmpty, "there was nothing to back up on the first save")

        book.record(handle: "sambassoon", followers: 900, likes: 20, comments: 4, on: stamp)

        XCTAssertEqual(backups().count, 1, "the previous generation was overwritten with no copy kept")
        let kept = root.appendingPathComponent(try XCTUnwrap(backups().first))
        let text = try String(contentsOf: kept, encoding: .utf8)
        XCTAssertTrue(text.contains("janecellist"), text)
    }

    func testABadFileIsNeverCapturedAsABackup() throws {
        let book = AccountBook(fileURL: file)
        book.record(handle: "janecellist", followers: 2_000, likes: 50, comments: 10, on: stamp)
        // Something writes nonsense over the store between two saves. Capturing
        // it would make the safety net a copy of the failure it exists for.
        try Data("not account data".utf8).write(to: file)

        let reopened = AccountBook(fileURL: file)
        reopened.record(handle: "sambassoon", followers: 900, likes: 20, comments: 4, on: stamp)

        for name in backups() {
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("not account data"),
                           "\(name) is a copy of the bad file")
        }
    }

    // MARK: - #505, a way back

    func testABadFileIsSetAsideSoSavingResumes() throws {
        try Data("not account data".utf8).write(to: file)

        let book = AccountBook(fileURL: file)
        XCTAssertEqual(book.loadStatus, .corrupt(setAsideAs: try setAsideFiles().first))
        book.record(handle: "janecellist", followers: 2_000, likes: 50, comments: 10, on: stamp)

        // The whole point: the numbers entered after the failure are saved, and
        // are still there next launch. Before this they were dropped forever.
        let reopened = AccountBook(fileURL: file)
        XCTAssertEqual(reopened.loadStatus, .ok)
        XCTAssertEqual(reopened.stats(for: "janecellist")?.followers, 2_000)
    }

    func testTheBadBytesAreKeptRatherThanDeleted() throws {
        try Data("not account data".utf8).write(to: file)

        _ = AccountBook(fileURL: file)

        let aside = try setAsideFiles()
        XCTAssertEqual(aside.count, 1, "the unreadable bytes were not preserved: \(aside)")
        let text = try String(contentsOf: root.appendingPathComponent(aside[0]), encoding: .utf8)
        XCTAssertEqual(text, "not account data")
    }

    func testAFileThatCannotBeReadAtAllStillBlocksSaving() throws {
        try XCTSkipIf(getuid() == 0, "permission based tests are meaningless as root")
        // Unknown contents, not invalid contents: nothing here proves the file
        // is bad, so it must be left exactly where it is and never written over.
        try Data("{\"records\": []}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        let book = AccountBook(fileURL: file)

        XCTAssertEqual(book.loadStatus, .unreadable)
        XCTAssertTrue(try setAsideFiles().isEmpty,
                      "a file we merely could not read was renamed as though it were corrupt")
    }

    func testTheNoteNamesTheFileAndTheFolder() throws {
        try Data("not account data".utf8).write(to: file)

        let note = try XCTUnwrap(AccountBook(fileURL: file).recoveryNote)

        // The only fix is a file on disk, and "the file" identifies nothing to
        // somebody standing in Finder.
        XCTAssertTrue(note.contains("accounts.json"), note)
        XCTAssertTrue(note.contains(root.lastPathComponent), note)
    }

    func testAHealthyBookSaysNothing() {
        let book = AccountBook(fileURL: file)
        book.record(handle: "janecellist", followers: 2_000, likes: 50, comments: 10, on: stamp)
        XCTAssertNil(book.recoveryNote)
    }

    func testTheTwoFailuresReadDifferently() throws {
        try Data("not account data".utf8).write(to: file)
        let corrupt = try XCTUnwrap(AccountBook(fileURL: file).recoveryNote)

        let other = root.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: other)
        try XCTSkipIf(getuid() == 0, "permission based tests are meaningless as root")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: other.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: other.path)
            StoreSaveGate.shared.unblock(other)
        }
        let unreadable = try XCTUnwrap(AccountBook(fileURL: other).recoveryNote)

        // Distinct causes, distinct messages (L11). One says the numbers are
        // gone and new ones are being saved; the other says nothing was touched
        // and nothing will be saved.
        XCTAssertNotEqual(corrupt, unreadable)
        XCTAssertTrue(corrupt.contains("set aside"), corrupt)
        XCTAssertTrue(unreadable.contains("left alone"), unreadable)
    }
}
