import XCTest

/// The code folder notice keeps up with the folder it is about (#668).
///
/// #664 read the checkout once, in `checkTheCodeFolder` at launch, and never
/// again. The condition it reports changes precisely while the app is open,
/// because that is when a session switches branches or leaves edits in the same
/// folder, so the likeliest state was a wrong one: the banner absent while the
/// folder had already moved off main, or naming a branch left an hour ago. A
/// notice that is silent in the case it exists for is worse than none, because
/// its silence reads as an assurance.
///
/// Rather than add a second reader, every reading taken anywhere announces
/// itself, and the window applies whatever arrives. `PythonBridge.runProcess`
/// already reads the revision at the top of every run for the log (#661), so a
/// generation now refreshes the notice at no extra cost, which is the moment it
/// matters most.
final class CheckoutNoticeFreshnessTests: XCTestCase {

    // MARK: - Somewhere for a reading to land

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckoutNotice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A state object, and nothing else (#681).
    ///
    /// Every test below wants somewhere for a reading to arrive, so none of
    /// them want a library. The shipping initialiser reads the real events.json
    /// and then runs the launch sweeps against whatever came back, and those
    /// sweeps delete media for every event NOT in the list they were handed.
    /// Pointed at a temporary tree instead, so this suite is structurally
    /// unable to reach live data (L2). Held to by
    /// `TestTargetHygieneTests.testNoTestBuildsAnAppStateThroughTheShippingInitialiser`,
    /// because the rule is worth nothing while the unsafe path is shorter to
    /// type.
    @MainActor
    private func makeState() -> AppState {
        AppState(events: [],
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    // MARK: - Every reading says so

    private func makeRepo(branch: String = "main") throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckoutFreshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: repo.appendingPathComponent("a.txt"))
        for arguments in [["init", "-q", "-b", branch], ["add", "."],
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

    func testAReadingOfARealCheckoutIsAnnounced() throws {
        let repo = try makeRepo(branch: "wip/fonts")
        defer { try? FileManager.default.removeItem(at: repo) }
        let center = NotificationCenter()

        var returned: CheckoutRevision.Reading?
        let heard = announcements(on: center) {
            returned = CheckoutRevision.read(inRepo: repo,
                                             timeout: CheckoutRevision.deadlineForTests,
                                             announcingTo: center)
        }

        XCTAssertEqual(heard.count, 1, "one read, one announcement")
        XCTAssertEqual(heard.first, returned,
                       "the reading announced is not the reading returned, so a "
                       + "surface listening would show something the run did not use")
    }

    func testAReadingThatFailedIsAnnouncedToo() throws {
        // The early returns are where an announcement is easiest to forget, and
        // forgetting one leaves the previous notice standing as though it were
        // still true. Broken where the work BEGINS rather than at the end, so
        // the case really is the unreadable one (L165).
        let center = NotificationCenter()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString)")

        let heard = announcements(on: center) {
            _ = CheckoutRevision.read(inRepo: missing,
                                      timeout: CheckoutRevision.deadlineForTests,
                                      announcingTo: center)
        }

        XCTAssertEqual(heard.count, 1)
        guard case .unknown = heard.first else {
            return XCTFail("an unreachable folder must announce as unknown: \(heard)")
        }
    }

    // MARK: - What the window does with one

    @MainActor
    func testAReadingTakenAnywhereReachesTheWindowsNotice() {
        // The run's own read is the one that matters: PythonBridge takes it at
        // the top of every generation, which is the last moment the notice can
        // still be acted on.
        let center = NotificationCenter()
        let state = makeState()
        state.watchCheckoutReadings(center)

        announce(.known(commit: "1a2b3c4", branch: "wip/fonts", dirty: false), on: center)
        settle()

        XCTAssertEqual(state.checkoutNotice?.contains("wip/fonts"), true,
                       state.checkoutNotice ?? "nil")
    }

    private func announce(_ reading: CheckoutRevision.Reading,
                          on center: NotificationCenter) {
        center.post(name: CheckoutRevision.readNotification, object: nil,
                    userInfo: [CheckoutRevision.readingKey: reading])
    }

    /// Let the hop back to the main actor land before reading the notice.
    @MainActor
    private func settle() {
        let arrived = expectation(description: "the notice catches up")
        DispatchQueue.main.async { arrived.fulfill() }
        wait(for: [arrived], timeout: 2)
    }

    @MainActor
    func testWatchingTwiceLeavesOneSubscription() {
        // A window can appear more than once, and two observers on one shared
        // centre would apply every reading twice. Asserted by watching a second
        // centre that must then be ignored, because "there is only one" is not
        // otherwise observable from outside (L151).
        let first = NotificationCenter()
        let second = NotificationCenter()
        let state = makeState()
        state.watchCheckoutReadings(first)
        state.watchCheckoutReadings(second)

        announce(.known(commit: "1a2b3c4", branch: "wip/second", dirty: false), on: second)
        settle()
        XCTAssertNil(state.checkoutNotice,
                     "a second call subscribed again: \(state.checkoutNotice ?? "")")

        announce(.known(commit: "1a2b3c4", branch: "wip/first", dirty: false), on: first)
        settle()
        XCTAssertEqual(state.checkoutNotice?.contains("wip/first"), true,
                       "the first subscription stopped working: "
                       + (state.checkoutNotice ?? "nil"))
    }

    @MainActor
    func testGoingBackToACleanMainTakesTheNoticeAway() {
        // The half a re-read exists for. A notice that appears correctly and
        // then never leaves is a banner that says the folder is off main for
        // the rest of the session, which teaches its reader to ignore it.
        let state = makeState()
        state.apply(.known(commit: "1a2b3c4", branch: "wip/fonts", dirty: true))
        XCTAssertNotNil(state.checkoutNotice, "the notice must appear first")

        state.apply(.known(commit: "1a2b3c4", branch: "main", dirty: false))

        XCTAssertNil(state.checkoutNotice,
                     "the banner still names a branch that was left: "
                     + (state.checkoutNotice ?? ""))
    }

    @MainActor
    func testAReadingThatFailedLeavesNoStaleSentenceStanding() {
        // An unreadable checkout is logged rather than shown (#664), so what
        // must not happen is the previous sentence staying on the window as
        // though it had been measured again.
        let state = makeState()
        state.apply(.known(commit: "1a2b3c4", branch: "wip/fonts", dirty: true))

        state.apply(.unknown(reason: "git could not name a branch"))

        XCTAssertNil(state.checkoutNotice, state.checkoutNotice ?? "")
    }

    // MARK: - Wired into the window

    func testTheWindowRefreshesTheNoticeWhenTheAppComesForward() throws {
        // Switching to a terminal, moving the checkout and coming back is the
        // whole scenario, and it produces exactly this notification.
        let code = try MainWindowSource.stripped()
        let block = try XCTUnwrap(
            MainWindowSource.block(openedBy: "didBecomeActiveNotification", in: code),
            "nothing in the window watches for the app coming forward, so the "
            + "notice is back to being read once at launch and never again")

        XCTAssertTrue(MainWindowSource.flattened(block).contains("refreshCheckoutNotice"),
                      "the window notices the app coming forward and does not "
                      + "re-read the checkout: \(MainWindowSource.flattened(block))")
    }

    func testTheWindowListensForReadingsTakenByARun() throws {
        let code = try MainWindowSource.stripped()

        XCTAssertTrue(code.contains("appState.watchCheckoutReadings()"),
                      "the window never subscribes, so the reading a run takes "
                      + "at its own start reaches nothing and the notice is only "
                      + "as fresh as the last time the app was activated")
    }
}
