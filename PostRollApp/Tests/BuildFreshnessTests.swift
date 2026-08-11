import XCTest

/// Warning Dan when the PostRoll he is running is older than the code.
///
/// Work merges all week and the app in /Applications keeps running whatever it
/// was last built from, so a fix can be shipped, merged and invisible, and the
/// only symptom is the app behaving like the old one. Overture answers this
/// from the command line (`mac/scripts/check-release-freshness.sh`); Dan does
/// not live in a terminal, so PostRoll says it on screen.
final class BuildFreshnessTests: XCTestCase {

    private func date(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    // MARK: - The comparison

    func testABuildOlderThanTheNewestCommitIsBehind() {
        let verdict = BuildFreshness.verdict(builtAt: date(1_000),
                                             latestCommit: date(2_000))

        XCTAssertEqual(verdict, .behind(builtAt: date(1_000),
                                        latestCommit: date(2_000)))
    }

    func testABuildNewerThanTheNewestCommitIsCurrent() {
        XCTAssertEqual(BuildFreshness.verdict(builtAt: date(2_000),
                                              latestCommit: date(1_000)), .current)
    }

    func testABuildMadeAtTheNewestCommitIsCurrent() {
        // A build carries the commit it was built from, so building exactly at
        // a commit is not behind it.
        XCTAssertEqual(BuildFreshness.verdict(builtAt: date(1_500),
                                              latestCommit: date(1_500)), .current)
    }

    func testASecondsWorthOfDriftIsNotWorthAWarning() {
        // Build time is when the binary was written, commit time is when the
        // commit was made, and a build kicked off seconds before a commit is
        // not a stale app. Warning on that is a warning nobody believes.
        XCTAssertEqual(BuildFreshness.verdict(builtAt: date(1_000),
                                              latestCommit: date(1_030)), .current)
    }

    // MARK: - Not knowing is its own answer

    func testAnUnreadableBuildTimeIsNotACleanBillOfHealth() {
        // The failure mode this must not have: no build time is exactly what a
        // bundle that cannot be read gives, and reporting "current" for it
        // tells Dan the app is up to date when nothing looked (LESSONS.md L98).
        guard case .cannotTell = BuildFreshness.verdict(builtAt: nil,
                                                        latestCommit: date(2_000))
        else { return XCTFail("an unreadable build time read as an answer") }
    }

    func testAnUnreadableCommitTimeIsNotACleanBillOfHealth() {
        guard case .cannotTell = BuildFreshness.verdict(builtAt: date(1_000),
                                                        latestCommit: nil)
        else { return XCTFail("a missing repository read as an answer") }
    }

    func testTheReasonSaysWhichHalfCouldNotBeRead() {
        // One message for two causes tells Dan something is wrong and not what.
        guard case let .cannotTell(noBuild) = BuildFreshness.verdict(
                builtAt: nil, latestCommit: date(1)),
              case let .cannotTell(noCommit) = BuildFreshness.verdict(
                builtAt: date(1), latestCommit: nil)
        else { return XCTFail("expected two cannotTell verdicts") }

        XCTAssertNotEqual(noBuild, noCommit)
        XCTAssertTrue(noBuild.lowercased().contains("build"), noBuild)
        XCTAssertTrue(noCommit.lowercased().contains("code"), noCommit)
    }

    // MARK: - Only a behind verdict interrupts

    func testOnlyABehindVerdictIsWorthShowing() {
        XCTAssertTrue(BuildFreshness.verdict(builtAt: date(1), latestCommit: date(1_000))
            .isWorthShowing)
        XCTAssertFalse(BuildFreshness.Verdict.current.isWorthShowing)
        // Not knowing is recorded in the log, not put in front of him on every
        // launch: a popup that cannot say anything actionable is one he learns
        // to dismiss, and then the real one goes with it (L36).
        XCTAssertFalse(BuildFreshness.Verdict.cannotTell(reason: "x").isWorthShowing)
    }

    // MARK: - What it says

    func testTheMessageNamesBothTimesAndWhatToDo() {
        let message = BuildFreshness.message(builtAt: date(1_700_000_000),
                                             latestCommit: date(1_700_100_000))

        XCTAssertTrue(message.contains("built"), message)
        XCTAssertTrue(message.contains("postroll"), message)
        XCTAssertFalse(message.contains("1700000000"), "raw epochs are not a date")
    }

    // MARK: - Reading the real halves

    func testTheBuildTimeOfARealBundleIsReadable() throws {
        // Read through the same call the app uses, against a real bundle, so
        // this cannot pass against an assumption about the file layout (L52).
        let bundle = Bundle(for: type(of: self))

        let built = try XCTUnwrap(BuildFreshness.buildTime(of: bundle))

        XCTAssertLessThan(built.timeIntervalSinceNow, 60)
    }

    func testTheLatestCommitTimeOfThisRepositoryIsReadable() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PostRollApp
            .deletingLastPathComponent()  // repo root

        let commit = try XCTUnwrap(BuildFreshness.latestCommitTime(inRepo: repo))

        XCTAssertLessThan(commit.timeIntervalSinceNow, 60)
        XCTAssertGreaterThan(commit.timeIntervalSince1970, 1_700_000_000)
    }

    func testAFolderThatIsNotARepositoryReadsAsNoCommitTime() {
        let notARepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildFreshnessTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: notARepo,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notARepo) }

        XCTAssertNil(BuildFreshness.latestCommitTime(inRepo: notARepo))
    }

    func testAPathThatDoesNotExistReadsAsNoCommitTime() {
        XCTAssertNil(BuildFreshness.latestCommitTime(
            inRepo: URL(fileURLWithPath: "/nowhere/at/all")))
    }
}
