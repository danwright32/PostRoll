import XCTest

/// The refuse-to-overwrite rule, as one implementation (#439).
///
/// Three file-backed stores need it. EventStore had the whole thing but kept it
/// private to its own file, AccountBook had its own inline copy of the
/// classification, and AnalyticsStore had neither, so a file it could not READ
/// was renamed as though corrupt and a failed rename let the next save write
/// over bytes nobody had read. Fixing that store alone would have left the rule
/// with three implementations and three behaviours, so these hold it to one.
final class StoreSaveGateTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - The gate

    func testAFileIsOnlyBlockedOnceItHasBeenBlocked() {
        let file = dir.appendingPathComponent("a.json")
        let gate = StoreSaveGate()

        XCTAssertFalse(gate.isBlocked(file))
        gate.block(file)
        XCTAssertTrue(gate.isBlocked(file))
        gate.unblock(file)
        XCTAssertFalse(gate.isBlocked(file), "a readable file must be saveable again")
    }

    func testBlockingOneStoreDoesNotBlockAnother() {
        // The keying is what makes one shared gate safe for several stores. If it
        // ever became a single flag, an unreadable analytics.json would silently
        // stop every caption and blog edit from being saved as well.
        let events = dir.appendingPathComponent("events.json")
        let analytics = dir.appendingPathComponent("analytics.json")
        let gate = StoreSaveGate()

        gate.block(events)

        XCTAssertTrue(gate.isBlocked(events))
        XCTAssertFalse(gate.isBlocked(analytics))
    }

    func testTheSamePathSpelledTwoWaysIsOneFile() {
        // Otherwise a store loaded through one spelling and saved through another
        // would be blocked in one direction and wide open in the other.
        let plain = dir.appendingPathComponent("events.json")
        let indirect = dir.appendingPathComponent("./events.json")
        let gate = StoreSaveGate()

        gate.block(plain)

        XCTAssertTrue(gate.isBlocked(indirect), "\(indirect.path) read as a different file")
    }

    // MARK: - Absent is not unreadable

    func testAMissingFileIsReportedAsMissing() throws {
        let missing = dir.appendingPathComponent("not-there.json")

        do {
            _ = try Data(contentsOf: missing)
            XCTFail("reading a file that is not there has to throw")
        } catch {
            XCTAssertTrue((error as NSError).isFileNotFound,
                          "a first launch would be treated as a read failure: \(error)")
        }
    }

    func testADeniedFileIsNotReportedAsMissing() throws {
        try XCTSkipIf(getuid() == 0, "permission bits mean nothing to root")
        let denied = dir.appendingPathComponent("denied.json")
        try Data("{}".utf8).write(to: denied)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                             ofItemAtPath: denied.path)

        do {
            _ = try Data(contentsOf: denied)
            XCTFail("a file with no read permission has to throw")
        } catch {
            // The whole point of classifying at the error rather than with
            // `fileExists`: this is the case that used to read as a first launch
            // and start the app empty over live data.
            XCTAssertFalse((error as NSError).isFileNotFound,
                           "a denied file read as absent: \(error)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                             ofItemAtPath: denied.path)
    }

    /// `FileHandle` reports an absent path differently from `Data(contentsOf:)`:
    /// NSFileNoSuchFileError with the ENOENT buried in an underlying error,
    /// rather than NSFileReadNoSuchFileError on top. The rule looked only at the
    /// top, so the first caller to open a file this way had every missing one
    /// classified as some unexplained failure (#557).
    func testAMissingFileIsReportedAsMissingWhicheverWayItWasOpened() throws {
        let missing = dir.appendingPathComponent("not-there.json")

        do {
            _ = try FileHandle(forReadingFrom: missing)
            XCTFail("opening a file that is not there has to throw")
        } catch {
            XCTAssertTrue((error as NSError).isFileNotFound,
                          "an absent file read as an unexplained failure: \(error)")
        }
    }

    /// The other half of the same judgement, and the one the rescan's message
    /// hangs off: a page that is there and refused must be nameable as refused,
    /// not merely as "not absent" (#557).
    func testADeniedFileIsReportedAsDenied() throws {
        try XCTSkipIf(getuid() == 0, "permission bits mean nothing to root")
        let denied = dir.appendingPathComponent("denied-2.json")
        try Data("{}".utf8).write(to: denied)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                             ofItemAtPath: denied.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: denied.path)
        }

        do {
            _ = try FileHandle(forReadingFrom: denied)
            XCTFail("a file with no read permission has to throw")
        } catch {
            XCTAssertTrue((error as NSError).isPermissionDenied,
                          "a refusal was not recognised as one: \(error)")
            XCTAssertFalse((error as NSError).isFileNotFound,
                           "a denied file read as absent: \(error)")
        }
    }

    /// The two answers must not both be yes for one error, or a caller
    /// branching on them gets whichever it happens to ask first.
    func testAMissingFileIsNotAlsoReportedAsDenied() throws {
        let missing = dir.appendingPathComponent("not-there-either.json")

        do {
            _ = try Data(contentsOf: missing)
            XCTFail("reading a file that is not there has to throw")
        } catch {
            XCTAssertFalse((error as NSError).isPermissionDenied,
                           "an absent file read as a refusal: \(error)")
        }
    }

    // MARK: - One implementation of the rule

    func testNoStoreKeepsItsOwnCopyOfTheNotFoundRule() throws {
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Services")

        var offenders: [String] = []
        for url in try FileManager.default.contentsOfDirectory(
            at: services, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "swift"
                      && $0.lastPathComponent != "StoreSaveGate.swift" }) {
            // Comments stripped, so the prose explaining where the rule lives
            // cannot itself be read as a copy of it (L103).
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") }
                .joined(separator: "\n")
            if code.contains("NSFileReadNoSuchFileError") || code.contains("Int(ENOENT)") {
                offenders.append(url.lastPathComponent)
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            These decide for themselves whether a file is merely absent, which is \
            the judgement that separates a first launch from live data nobody could \
            read. It belongs in StoreSaveGate.swift only:

            \(offenders.joined(separator: "\n"))
            """)
    }

    func testTheUnreadableMessageReadsAsOneSentenceWhateverTheReasonBrings() {
        struct Stopped: LocalizedError {
            var errorDescription: String? { "The volume could not be found." }
        }
        struct Unstopped: LocalizedError {
            var errorDescription: String? { "input/output error" }
        }

        for error in [Stopped() as Error, Unstopped() as Error] {
            let message = StoreRecoveryText.unreadable("Your saved events", error)

            XCTAssertFalse(message.contains(".."), message)
            XCTAssertFalse(message.contains(" ."), message)
            XCTAssertTrue(message.contains("nothing new will be saved"),
                          "the message has to say saving has stopped: \(message)")
        }
    }
}
