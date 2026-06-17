import XCTest

/// Covers the missing-media check that flags reel audio whose file moved or was
/// deleted (issue #51), mirroring how missing photos are flagged.
final class MediaPresenceTests: XCTestCase {

    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("media-presence-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    func testNilIsNotMissing() {
        XCTAssertFalse(MediaPresence.isMissing(nil))
    }

    func testPresentFileIsNotMissing() throws {
        let url = dir.appendingPathComponent("track.m4a")
        try Data("audio".utf8).write(to: url)
        XCTAssertFalse(MediaPresence.isMissing(url))
    }

    func testSetButAbsentFileIsMissing() {
        let url = dir.appendingPathComponent("gone.m4a")  // never created
        XCTAssertTrue(MediaPresence.isMissing(url))
    }

    func testFileBecomesMissingAfterDeletion() throws {
        let url = dir.appendingPathComponent("track.m4a")
        try Data("audio".utf8).write(to: url)
        XCTAssertFalse(MediaPresence.isMissing(url))
        try fm.removeItem(at: url)
        XCTAssertTrue(MediaPresence.isMissing(url))
    }
}
