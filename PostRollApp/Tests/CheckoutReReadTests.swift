import XCTest

/// A reading seconds old answers the next question (#676).
///
/// `refreshCheckoutNotice` runs on every app activation, and a reading runs git
/// three times, one of them `git status --porcelain` over the whole working
/// tree. Clicking back into PostRoll paid for the same answer again whether or
/// not anything had moved, and in a checkout with a lot of uncommitted work that
/// is not instant.
///
/// So the moment of the last reading is kept, and a re-read taken within a few
/// seconds of it is skipped. That also covers the activation that arrives
/// immediately after a generation has just read the same folder for its own log.
///
/// The skip is deliberately only on the refresh. A generation's own reading is
/// the record of which code that run executed (#661), and handing it a reading
/// taken seconds earlier would put a number in the log that nothing measured for
/// it.
final class CheckoutReReadTests: XCTestCase {

    private func makeRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckoutReRead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: repo.appendingPathComponent("a.txt"))
        for arguments in [["init", "-q", "-b", "main"], ["add", "."],
                          ["commit", "-q", "-m", "first"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path,
                                 "-c", "user.email=t@example.com",
                                 "-c", "user.name=T"] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
        return repo
    }

    /// Every reading announced on `center`, in the order they arrived.
    ///
    /// Counted through the announcement rather than through what each call
    /// returns, because a skipped read must not reach the window either: a
    /// re-announced reading would put the same sentence back through every
    /// listener at no less cost than reading it (L46).
    private func announcements(on center: NotificationCenter,
                               while work: () -> Void) -> [CheckoutRevision.Reading] {
        var heard: [CheckoutRevision.Reading] = []
        let token = center.addObserver(
            forName: CheckoutRevision.readNotification, object: nil, queue: nil) { note in
                if let reading = CheckoutRevision.reading(in: note) { heard.append(reading) }
            }
        defer { center.removeObserver(token) }
        work()
        return heard
    }

    private let noon = Date(timeIntervalSince1970: 1_755_000_000)

    func testTheFirstReadingIsAlwaysTaken() throws {
        // Nothing recorded is not the same as a reading taken just now, and a
        // recency that could not tell them apart would make the app open with
        // no notice at all (L98).
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let center = NotificationCenter()

        var reading: CheckoutRevision.Reading?
        let heard = announcements(on: center) {
            reading = CheckoutRevision.readIfStale(
                inRepo: repo, at: noon,
                timeout: CheckoutRevision.deadlineForTests, announcingTo: center,
                recording: CheckoutRevision.Recency())
        }

        XCTAssertNotNil(reading, "the first refresh read nothing at all")
        XCTAssertEqual(heard.count, 1)
    }

    func testAReadTakenSecondsAfterTheLastOneIsSkipped() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let center = NotificationCenter()
        let recency = CheckoutRevision.Recency()

        var second: CheckoutRevision.Reading?
        let heard = announcements(on: center) {
            _ = CheckoutRevision.readIfStale(inRepo: repo, at: noon,
                                             timeout: CheckoutRevision.deadlineForTests,
                                             announcingTo: center, recording: recency)
            second = CheckoutRevision.readIfStale(
                inRepo: repo, at: noon.addingTimeInterval(2),
                timeout: CheckoutRevision.deadlineForTests,
                announcingTo: center, recording: recency)
        }

        XCTAssertNil(second, "a second activation two seconds later ran git again")
        XCTAssertEqual(heard.count, 1,
                       "the skipped read still announced, so every listener paid "
                       + "for it: \(heard)")
    }

    func testAReadTakenAfterTheWindowIsTakenAgain() throws {
        // The half the skip must not eat. A checkout moves while the app is
        // open, so a refresh that stopped happening would take the notice back
        // to being read once and never again (#668).
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let center = NotificationCenter()
        let recency = CheckoutRevision.Recency()

        var second: CheckoutRevision.Reading?
        let heard = announcements(on: center) {
            _ = CheckoutRevision.readIfStale(inRepo: repo, at: noon,
                                             timeout: CheckoutRevision.deadlineForTests,
                                             announcingTo: center, recording: recency)
            second = CheckoutRevision.readIfStale(
                inRepo: repo,
                at: noon.addingTimeInterval(CheckoutRevision.reuseWindow + 1),
                timeout: CheckoutRevision.deadlineForTests,
                announcingTo: center, recording: recency)
        }

        XCTAssertNotNil(second, "the notice stopped being refreshed altogether")
        XCTAssertEqual(heard.count, 2)
    }

    func testAGenerationsOwnReadingStandsInForTheNextActivation() throws {
        // The case named in #676: a run reads the folder for its log, and the
        // activation that follows it seconds later is asking the same question
        // of the same folder.
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let center = NotificationCenter()
        let recency = CheckoutRevision.Recency()

        var refreshed: CheckoutRevision.Reading?
        let heard = announcements(on: center) {
            _ = CheckoutRevision.read(inRepo: repo, at: noon,
                                      timeout: CheckoutRevision.deadlineForTests,
                                      announcingTo: center, recording: recency)
            refreshed = CheckoutRevision.readIfStale(
                inRepo: repo, at: noon.addingTimeInterval(1),
                timeout: CheckoutRevision.deadlineForTests,
                announcingTo: center, recording: recency)
        }

        XCTAssertNil(refreshed,
                     "coming back to the app right after a generation read the "
                     + "same folder read it all over again")
        XCTAssertEqual(heard.count, 1)
    }

    func testAGenerationsOwnReadingIsNeverSkipped() throws {
        // What a run writes into its log is the code that run executed, so it
        // has to be measured for that run rather than inherited from one taken
        // seconds earlier for something else.
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let center = NotificationCenter()
        let recency = CheckoutRevision.Recency()

        let heard = announcements(on: center) {
            _ = CheckoutRevision.read(inRepo: repo, at: noon,
                                      timeout: CheckoutRevision.deadlineForTests,
                                      announcingTo: center, recording: recency)
            _ = CheckoutRevision.read(inRepo: repo, at: noon.addingTimeInterval(1),
                                      timeout: CheckoutRevision.deadlineForTests,
                                      announcingTo: center, recording: recency)
        }

        XCTAssertEqual(heard.count, 2,
                       "a run was handed a reading taken for something else, so "
                       + "its log names a checkout nothing measured for it")
    }

    func testASkippedReadIsNotReportedAsAnUnreadableCheckout() throws {
        // A skip and a failure are different answers and only one of them means
        // the folder could not be read (L11). The window logs an unknown
        // reading, so a skip returning one would write a line saying the
        // checkout is unreadable every time the app is clicked into.
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let center = NotificationCenter()
        let recency = CheckoutRevision.Recency()

        _ = CheckoutRevision.readIfStale(inRepo: repo, at: noon,
                                         timeout: CheckoutRevision.deadlineForTests,
                                         announcingTo: center, recording: recency)
        let skipped = CheckoutRevision.readIfStale(
            inRepo: repo, at: noon.addingTimeInterval(1),
            timeout: CheckoutRevision.deadlineForTests,
            announcingTo: center, recording: recency)

        if case .unknown(let reason)? = skipped {
            XCTFail("a skipped read reported the checkout as unreadable: \(reason)")
        }
    }

    // MARK: - Wired into the window

    func testTheWindowsRefreshIsTheOneThatCanSkip() throws {
        let code = try MainWindowSource.stripped()
        let block = try XCTUnwrap(
            MainWindowSource.block(openedBy: "func refreshCheckoutNotice", in: code),
            "MainWindowView no longer refreshes the checkout notice at all, so "
            + "there is nothing here to check and this guard would otherwise "
            + "pass having read nothing")
        let refresh = MainWindowSource.flattened(block)

        XCTAssertTrue(refresh.contains("CheckoutRevision.readIfStale"),
                      "the refresh reads the folder unconditionally, so every "
                      + "click back into PostRoll runs git three times over the "
                      + "whole working tree for an answer taken seconds ago: "
                      + refresh)
        XCTAssertFalse(refresh.contains("CheckoutRevision.read(inRepo"),
                       "the refresh still takes the unskippable read as well, so "
                       + "the skip saves nothing: \(refresh)")
    }
}
