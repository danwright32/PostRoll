import XCTest

/// #451: a folder nobody can read is not a folder with nothing in it.
final class DirectoryListingTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func testItReadsWhatIsThere() throws {
        try Data("a".utf8).write(to: dir.appendingPathComponent("b.jpg"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.jpg"))

        guard case .entries(let found) = DirectoryListing.of(dir) else {
            return XCTFail("a readable folder did not read")
        }
        XCTAssertEqual(found.map(\.lastPathComponent), ["a.jpg", "b.jpg"],
                       "the order is not stable, so two listings of one folder differ")
    }

    /// An empty folder is a real answer and must stay one.
    func testAnEmptyFolderIsEntriesRatherThanAFailure() {
        XCTAssertEqual(DirectoryListing.of(dir), .entries([]))
        XCTAssertNil(DirectoryListing.of(dir).failureReason)
    }

    func testAFolderThatCannotBeListedSaysSo() throws {
        try Data("a".utf8).write(to: dir.appendingPathComponent("hidden-from-us.jpg"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: dir.path)

        let listing = DirectoryListing.of(dir)

        XCTAssertNotNil(listing.failureReason,
                        "an unreadable folder read as an empty one: \(listing)")
        XCTAssertFalse(listing.failureReason?.isEmpty ?? true,
                       "the failure carries no reason to show anyone")
    }

    func testAFolderThatIsNotThereIsAFailureRatherThanEmpty() {
        let missing = dir.appendingPathComponent("never-made")

        XCTAssertNotNil(DirectoryListing.of(missing).failureReason)
    }

    func testHiddenFilesAreSkipped() throws {
        try Data("a".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("real.jpg"))

        XCTAssertEqual(DirectoryListing.of(dir).entriesIgnoringFailure.map(\.lastPathComponent),
                       ["real.jpg"])
    }

    func testFlatteningAFailureGivesNothingRatherThanCrashing() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: dir.path)

        XCTAssertEqual(DirectoryListing.of(dir).entriesIgnoringFailure, [])
    }
}
