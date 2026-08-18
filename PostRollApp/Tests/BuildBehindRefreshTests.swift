import XCTest

/// The out of date warning keeps up with the code folder (#675).
///
/// `buildBehind` was read once at launch, and its own note said the answer could
/// not change while the app was open. It can: the running app is compared
/// against the newest commit in the code folder, and the code folder moves while
/// PostRoll sits there. A session that pulls, or switches to a branch ahead of
/// the build, leaves the running copy out of date with nothing saying so, which
/// is the state that makes a shipped fix look like it never worked.
///
/// The same treatment #668 gave the checkout notice: the verdict is taken again
/// on the reading that already goes out, rather than by adding a second reader of
/// the same folder. What is new here is the dismissal. The notice is a banner and
/// can simply reappear; this is a sheet in the middle of the window, so a verdict
/// Dan has waved away must not be put back in front of him every time he clicks
/// into the app.
final class BuildBehindRefreshTests: XCTestCase {

    private func date(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private let repo = URL(fileURLWithPath: "/tmp/PostRollBuildBehindRefresh")

    private func behind(latestCommit: TimeInterval = 2_000) -> BuildFreshness.Verdict {
        .behind(builtAt: date(1_000), latestCommit: date(latestCommit),
                remedy: .rebuild)
    }

    /// An AppState whose freshness answers come from this test rather than git.
    ///
    /// The seam exists because `BuildFreshness.check` runs git against a real
    /// checkout, so a test driving it would be answering about whenever this Mac
    /// last committed (L2). What is under test here is what the window does with
    /// a verdict, which is the half that was missing.
    /// The temporary tree this suite's state objects point at, so the seam's
    /// required locations (#684) name somewhere that is not the live store.
    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("BuildBehindRefresh-\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func state(judging verdicts: [BuildFreshness.Verdict]) -> AppState {
        let state = AppState(events: [],
                             storeURL: root.appendingPathComponent("events.json"),
                             dataRoot: root)
        let queue = VerdictQueue(verdicts)
        state.judgeBuildFreshness = { _ in queue.next() }
        return state
    }

    private final class VerdictQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var verdicts: [BuildFreshness.Verdict]
        init(_ verdicts: [BuildFreshness.Verdict]) { self.verdicts = verdicts }
        func next() -> BuildFreshness.Verdict {
            lock.lock()
            defer { lock.unlock() }
            return verdicts.count > 1 ? verdicts.removeFirst() : verdicts[0]
        }
    }

    // MARK: - A reading refreshes the verdict

    @MainActor
    func testAReadingTakenAnywhereRefreshesTheVerdict() async {
        // The scenario: PostRoll is open, a session pulls in the terminal, and
        // the app comes forward. The reading that refreshes the notice is the
        // one that must refresh this too.
        let state = state(judging: [behind()])
        state.watchCheckoutReadings(center)

        announce(.known(commit: "1a2b3c4", branch: "main", dirty: false), from: repo)
        await settle(state)

        XCTAssertNotNil(state.buildBehind,
                        "the app went on saying nothing while the code folder "
                        + "had moved ahead of the running build")
    }

    @MainActor
    func testAReadingThatNamesNoFolderJudgesNothing() async {
        // Nothing to judge against is not a verdict of current. A reading with
        // no folder on it must leave the answer alone rather than reach for a
        // checkout nobody named (L75).
        //
        // The test above is this one's control: it drives the same fixture the
        // same way and expects the warning to appear, so a mechanism that had
        // simply stopped working could not leave this one green (L159).
        let state = state(judging: [behind()])
        state.watchCheckoutReadings(center)

        announce(.known(commit: "1a2b3c4", branch: "main", dirty: false), from: nil)
        await settle(state)

        XCTAssertNil(state.buildBehind)
    }

    // MARK: - Dismissing it

    @MainActor
    func testAVerdictWavedAwayDoesNotComeBackOnTheNextActivation() async {
        // The whole reason a launch-only check was tolerable. Clicking into the
        // app is not a request to be told again, and a sheet that reappears
        // every time is one that gets dismissed on reflex, taking the real
        // warning with it (L36).
        let state = state(judging: [behind()])
        await state.refreshBuildFreshness(inRepo: repo)
        XCTAssertNotNil(state.buildBehind, "the warning must appear first")

        state.dismissBuildBehind()
        await state.refreshBuildFreshness(inRepo: repo)

        XCTAssertNil(state.buildBehind,
                     "the same verdict was put back in front of Dan after he "
                     + "had waved it away")
    }

    @MainActor
    func testANewerCommitBringsTheWarningBack() async {
        // Dismissing says "not now" about one verdict, not "never again". Work
        // merging afterwards is new information, and it is the case the sheet
        // exists for.
        let state = state(judging: [behind(latestCommit: 2_000),
                                    behind(latestCommit: 9_000)])
        await state.refreshBuildFreshness(inRepo: repo)
        state.dismissBuildBehind()

        await state.refreshBuildFreshness(inRepo: repo)

        XCTAssertEqual(state.buildBehind?.latestCommit, date(9_000),
                       "work merged after the sheet was dismissed is never "
                       + "mentioned again, which is the silence the whole check "
                       + "exists to break")
    }

    @MainActor
    func testCatchingUpTakesTheWarningAway() async {
        // The clearing half. A rebuild while the app is open is exactly what the
        // sheet asked for, and a warning that stays put afterwards says the fix
        // did not work.
        let state = state(judging: [behind(), .current])
        await state.refreshBuildFreshness(inRepo: repo)
        XCTAssertNotNil(state.buildBehind)

        await state.refreshBuildFreshness(inRepo: repo)

        XCTAssertNil(state.buildBehind, "the app still says it is out of date")
    }

    @MainActor
    func testAVerdictThatCouldNotBeReadLeavesTheStandingWarningAlone() async {
        // A read that failed measured nothing, so it cannot take away a warning
        // that was measured. Clearing here would be a clean bill of health
        // nobody gave (L11, L98).
        let state = state(judging: [behind(),
                                    .cannotTell(reason: "git could not be run")])
        await state.refreshBuildFreshness(inRepo: repo)

        await state.refreshBuildFreshness(inRepo: repo)

        XCTAssertNotNil(state.buildBehind,
                        "an unreadable answer took the warning off the screen")
    }

    @MainActor
    func testCatchingUpRearmsTheWarningForTheNextTimeItIsBehind() async {
        // Dismissing a verdict must not silence a later one that happens to
        // carry the same times: catching up ends the whole episode, so the next
        // time the build falls behind it is new news again.
        let state = state(judging: [behind(), .current, behind()])
        await state.refreshBuildFreshness(inRepo: repo)
        state.dismissBuildBehind()

        await state.refreshBuildFreshness(inRepo: repo)   // caught up
        await state.refreshBuildFreshness(inRepo: repo)   // behind again

        XCTAssertNotNil(state.buildBehind,
                        "the app caught up and fell behind again in one session "
                        + "and said nothing the second time")
    }

    // MARK: - Wired into the window

    func testTheWindowsSheetRecordsThatItWasDismissed() throws {
        let code = MainWindowSource.flattened(try MainWindowSource.stripped())
        XCTAssertTrue(code.contains("BuildBehindSheet("),
                      "MainWindowView no longer presents the out of date sheet "
                      + "at all, so there is nothing here to check and this guard "
                      + "would otherwise pass having read nothing")

        // Asserted as ONE match carrying both halves rather than as a sheet
        // somewhere and a dismissal somewhere, because two separate matches in a
        // file this size prove neither of them (L172).
        XCTAssertNotNil(
            code.range(of: #"\.sheet\(item: Binding\([^)]*dismissBuildBehind"#,
                       options: .regularExpression),
            "the out of date sheet is dismissed without recording it, so the "
            + "next reading of the code folder puts it straight back and it "
            + "reappears every time the app comes forward: \(code)")
    }

    func testTheWindowJudgesFreshnessThroughTheStateThatCanRefreshIt() throws {
        // Written into the state directly at launch and re-derived nowhere else
        // is the shape #675 is about, and it reads as perfectly correct.
        let code = try MainWindowSource.stripped()

        XCTAssertFalse(code.contains("appState.buildBehind ="),
                       "the window writes the verdict straight into the state, "
                       + "so the launch answer and the refreshed one are two "
                       + "paths that can disagree about what is on screen (L16)")
        XCTAssertTrue(code.contains("refreshBuildFreshness"),
                      "nothing in the window asks for a freshness verdict")
    }

    // MARK: - Driving the notification

    private let center = NotificationCenter()

    private func announce(_ reading: CheckoutRevision.Reading, from repo: URL?) {
        var userInfo: [AnyHashable: Any] = [CheckoutRevision.readingKey: reading]
        if let repo { userInfo[CheckoutRevision.repoKey] = repo }
        center.post(name: CheckoutRevision.readNotification, object: nil,
                    userInfo: userInfo)
    }

    /// Let the hop back to the main actor and the judging that follows land.
    @MainActor
    private func settle(_ state: AppState) async {
        for _ in 0..<20 {
            if state.buildBehind != nil { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
