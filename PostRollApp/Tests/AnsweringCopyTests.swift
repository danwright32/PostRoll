import XCTest

/// Which copy of PostRoll answered the link (#840).
///
/// As of filing, `lsregister` on this Mac held 14 registrations for
/// `PostRoll.app` and four of those bundles still existed: the installed one,
/// a Debug and a Release build product, and a copy in Xcode's DerivedData.
/// While PostRoll answered no URLs at all that was harmless. The moment it
/// declares `postroll://`, macOS picks one of them by rules this code does not
/// get a vote in, and a Debug build sitting in a build folder is a live
/// candidate.
///
/// That is the 2026-08-04 Overture incident exactly: two copies of one app, a
/// lookup that resolved to the wrong one, and a check that agreed with itself
/// because both of its sides came from that same lookup. The remedy that works
/// is not to assume the installed copy wins. It is to make the running copy say
/// which one it is, so a link handled by the wrong build is visible rather than
/// silently operating on a different events store.
final class AnsweringCopyTests: XCTestCase {

    private let installed = "/Applications/PostRoll.app"

    func testTheInstalledCopyAnsweringSaysNothing() {
        XCTAssertNil(AnsweringCopy.notice(answeredBy: URL(fileURLWithPath: installed),
                                          installedAt: installed))
    }

    func testADebugBuildAnsweringSaysSo() {
        let debug = "/Users/dan/Library/Developer/PostRoll/Build/Products/Debug/PostRoll.app"

        let notice = AnsweringCopy.notice(answeredBy: URL(fileURLWithPath: debug),
                                          installedAt: installed)

        XCTAssertNotNil(notice, "a build product answered the link and nothing said so")
    }

    func testTheNoticeNamesBothCopies() {
        // Naming only "not the installed one" leaves Dan with four candidates
        // and no way to tell which is in front of him (L80).
        let debug = "/Users/dan/Library/Developer/PostRoll/Build/Products/Debug/PostRoll.app"

        let notice = AnsweringCopy.notice(answeredBy: URL(fileURLWithPath: debug),
                                          installedAt: installed)

        XCTAssertTrue(notice?.contains(debug) ?? false,
                      "the notice does not name the copy that answered: \(notice ?? "nil")")
        XCTAssertTrue(notice?.contains(installed) ?? false,
                      "the notice does not name the copy that was meant to: \(notice ?? "nil")")
    }

    func testAPathWrittenADifferentWayIsStillTheInstalledCopyWhenItIsThere() throws {
        // `Bundle.main.bundleURL` is not guaranteed to be spelled the way the
        // constant is. A comparison that took two spellings of one path for two
        // different copies would warn on every single link, and a warning that
        // is always on is one nobody reads (L36).
        //
        // The bundle is CREATED here rather than assumed. This test used to use
        // /Applications/PostRoll.app, and it passed on this Mac and failed on
        // CI: `resolvingSymlinksInPath` canonicalises a path that exists and
        // leaves one that does not alone, so what the test really asked was
        // whether PostRoll happened to be installed on the machine running it
        // (L504).
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnsweringCopy-\(UUID().uuidString)")
            .appendingPathComponent("PostRoll.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real.deletingLastPathComponent()) }

        let awkward = URL(fileURLWithPath: real.deletingLastPathComponent()
            .path(percentEncoded: false) + "/./PostRoll.app/")

        XCTAssertNil(AnsweringCopy.notice(answeredBy: awkward,
                                          installedAt: real.path(percentEncoded: false)))
    }

    func testAPathWrittenADifferentWayIsStillTheInstalledCopyWhenItIsNot() {
        // The other half, and the one CI actually runs: on a machine with no
        // PostRoll installed, neither side gets canonicalised, so the trailing
        // slash and the `.` survive to be compared. A copy that has been moved
        // or not yet installed must not read as a different copy answering.
        let missing = "/nowhere-postroll-was-installed/PostRoll.app"
        let awkward = URL(fileURLWithPath: "/nowhere-postroll-was-installed/./PostRoll.app/")

        XCTAssertNil(AnsweringCopy.notice(answeredBy: awkward, installedAt: missing))
    }

    func testTheDefaultIsTheCopyBuildInstallWrites() {
        // The one place that decides which copy is meant to answer. If this
        // stops matching where build-install.sh puts the app, every link warns
        // and the warning is wrong.
        XCTAssertEqual(AnsweringCopy.installedPath, "/Applications/PostRoll.app")
    }
}
