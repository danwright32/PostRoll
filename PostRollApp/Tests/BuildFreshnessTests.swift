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
                                             localCommit: date(2_000),
                                             remoteCommit: date(2_000))

        XCTAssertEqual(verdict, .behind(builtAt: date(1_000),
                                        latestCommit: date(2_000),
                                        remedy: .rebuild))
    }

    func testABuildNewerThanTheNewestCommitIsCurrent() {
        XCTAssertEqual(BuildFreshness.verdict(builtAt: date(2_000),
                                              localCommit: date(1_000),
                                              remoteCommit: date(1_000)), .current)
    }

    func testABuildMadeAtTheNewestCommitIsCurrent() {
        // A build carries the commit it was built from, so building exactly at
        // a commit is not behind it.
        XCTAssertEqual(BuildFreshness.verdict(builtAt: date(1_500),
                                              localCommit: date(1_500),
                                              remoteCommit: date(1_500)), .current)
    }

    func testASecondsWorthOfDriftIsNotWorthAWarning() {
        // Build time is when the binary was written, commit time is when the
        // commit was made, and a build kicked off seconds before a commit is
        // not a stale app. Warning on that is a warning nobody believes.
        XCTAssertEqual(BuildFreshness.verdict(builtAt: date(1_000),
                                              localCommit: date(1_030),
                                              remoteCommit: date(1_030)), .current)
    }

    // MARK: - Work that merged and has not reached this Mac (#312)

    /// The ordinary shape of the gap: a session ends, the work merges, this Mac
    /// is never pulled. There is then no newer commit locally, so comparing
    /// against the checkout alone says nothing and the app reads as current,
    /// which is exactly the case the warning exists for.

    func testAnAppBuiltFromEverythingLocalIsStillBehindWorkNotPulledYet() {
        let verdict = BuildFreshness.verdict(builtAt: date(2_000),
                                             localCommit: date(2_000),
                                             remoteCommit: date(5_000))

        XCTAssertEqual(verdict, .behind(builtAt: date(2_000),
                                        latestCommit: date(5_000),
                                        remedy: .pullThenRebuild))
    }

    func testACheckoutBehindTheRemoteAsksForAPullNotJustARebuild() {
        // Rebuilding a checkout that is itself behind produces another build
        // missing the same work, so telling Dan to rebuild would send him round
        // the same loop with the symptom unchanged.
        guard case let .behind(_, _, remedy) = BuildFreshness.verdict(
            builtAt: date(1_000), localCommit: date(2_000), remoteCommit: date(5_000))
        else { return XCTFail("an app behind both should be behind") }

        XCTAssertEqual(remedy, .pullThenRebuild)
    }

    func testACheckoutHoldingTheNewestWorkOnlyNeedsARebuild() {
        guard case let .behind(_, latest, remedy) = BuildFreshness.verdict(
            builtAt: date(1_000), localCommit: date(5_000), remoteCommit: date(2_000))
        else { return XCTFail("an app older than its checkout is behind") }

        XCTAssertEqual(remedy, .rebuild)
        XCTAssertEqual(latest, date(5_000), "the newest commit is the local one here")
    }

    func testAnUnreadableRemoteFallsBackToTheCheckoutRatherThanGivingUp() {
        // No origin/main ref, a fresh clone, a machine that has never fetched.
        // The local comparison still stands and is worth making, so this is not
        // the same as having nothing to compare against at all.
        XCTAssertEqual(BuildFreshness.verdict(builtAt: date(1_000),
                                              localCommit: date(2_000),
                                              remoteCommit: nil),
                       .behind(builtAt: date(1_000), latestCommit: date(2_000),
                               remedy: .rebuild))
    }

    func testTheSameSecondsOfDriftApplyToTheRemote() {
        XCTAssertEqual(BuildFreshness.verdict(builtAt: date(2_000),
                                              localCommit: date(2_000),
                                              remoteCommit: date(2_030)), .current)
    }

    // MARK: - The two fixes read differently

    func testTheRebuildMessageAsksForARebuild() {
        let text = BuildFreshness.message(builtAt: date(1_000),
                                          latestCommit: date(5_000),
                                          remedy: .rebuild)

        XCTAssertTrue(text.contains("postroll"), text)
        XCTAssertFalse(text.lowercased().contains("pull"),
                       "there is nothing to pull here: \(text)")
    }

    func testThePullMessageSaysTheWorkIsNotOnThisMacYet() {
        let text = BuildFreshness.message(builtAt: date(1_000),
                                          latestCommit: date(5_000),
                                          remedy: .pullThenRebuild)

        XCTAssertTrue(text.lowercased().contains("pull"), text)
        XCTAssertTrue(text.contains("has not") || text.contains("not reached"),
                      "the message has to say WHY a rebuild alone is not enough: \(text)")
    }

    func testTheCommandMatchesTheFix() {
        let repo = URL(fileURLWithPath: "/Users/dan/Documents/PostRoll")

        XCTAssertEqual(BuildFreshness.command(for: .rebuild, repo: repo), "postroll")

        let pull = BuildFreshness.command(for: .pullThenRebuild, repo: repo)
        XCTAssertTrue(pull.contains("git pull"), pull)
        XCTAssertTrue(pull.contains("postroll"), pull)
        XCTAssertTrue(pull.contains(repo.path),
                      "the command has to name the folder, or it only works from "
                      + "wherever the terminal happens to be: \(pull)")
    }

    func testACommandForAPathWithSpacesIsStillOneCommand() {
        // The repo has lived under a path with a space before now, and an
        // unquoted one silently runs git pull in the wrong folder.
        let repo = URL(fileURLWithPath: "/Users/dan/My Documents/PostRoll")
        let pull = BuildFreshness.command(for: .pullThenRebuild, repo: repo)

        XCTAssertTrue(pull.contains("\"/Users/dan/My Documents/PostRoll\"")
                      || pull.contains("'/Users/dan/My Documents/PostRoll'"), pull)
    }

    // MARK: - Not knowing is its own answer

    func testAnUnreadableBuildTimeIsNotACleanBillOfHealth() {
        // The failure mode this must not have: no build time is exactly what a
        // bundle that cannot be read gives, and reporting "current" for it
        // tells Dan the app is up to date when nothing looked (LESSONS.md L98).
        guard case .cannotTell = BuildFreshness.verdict(builtAt: nil,
                                                        localCommit: date(2_000),
                                                        remoteCommit: nil)
        else { return XCTFail("an unreadable build time read as an answer") }
    }

    func testAnUnreadableCommitTimeIsNotACleanBillOfHealth() {
        guard case .cannotTell = BuildFreshness.verdict(builtAt: date(1_000),
                                                        localCommit: nil,
                                                        remoteCommit: nil)
        else { return XCTFail("a missing repository read as an answer") }
    }

    func testTheReasonSaysWhichHalfCouldNotBeRead() {
        // One message for two causes tells Dan something is wrong and not what.
        guard case let .cannotTell(noBuild) = BuildFreshness.verdict(
                builtAt: nil, localCommit: date(1), remoteCommit: nil),
              case let .cannotTell(noCommit) = BuildFreshness.verdict(
                builtAt: date(1), localCommit: nil, remoteCommit: nil)
        else { return XCTFail("expected two cannotTell verdicts") }

        XCTAssertNotEqual(noBuild, noCommit)
        XCTAssertTrue(noBuild.lowercased().contains("build"), noBuild)
        XCTAssertTrue(noCommit.lowercased().contains("code"), noCommit)
    }

    // MARK: - Only a behind verdict interrupts

    func testOnlyABehindVerdictIsWorthShowing() {
        XCTAssertTrue(BuildFreshness.verdict(builtAt: date(1), localCommit: date(1_000),
                                             remoteCommit: nil).isWorthShowing)
        XCTAssertFalse(BuildFreshness.Verdict.current.isWorthShowing)
        // Not knowing is recorded in the log, not put in front of him on every
        // launch: a popup that cannot say anything actionable is one he learns
        // to dismiss, and then the real one goes with it (L36).
        XCTAssertFalse(BuildFreshness.Verdict.cannotTell(reason: "x").isWorthShowing)
    }

    // MARK: - What it says

    func testTheMessageNamesBothTimesAndWhatToDo() {
        let message = BuildFreshness.message(builtAt: date(1_700_000_000),
                                             latestCommit: date(1_700_100_000),
                                             remedy: .rebuild)

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

    /// A real repository with a real `origin/main`, built here rather than
    /// stubbed. A fake would only confirm this test's own guess about what git
    /// prints for a remote-tracking ref (L52), and the whole point of #312 is
    /// that this read has to work offline against a ref no fetch is performed
    /// for.
    func testTheRemoteCommitTimeIsReadFromARealTrackingRef() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildFreshnessRepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path,
                                 "-c", "user.email=t@example.com",
                                 "-c", "user.name=T"] + arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        _ = try git(["init", "-q", "-b", "main"])
        try Data("one".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-q", "-m", "first"])
        let first = try git(["rev-parse", "HEAD"])

        // origin/main pinned to the first commit, then a second commit locally,
        // which is the shape of a Mac that has pulled and moved on.
        _ = try git(["update-ref", "refs/remotes/origin/main", first])
        try Data("two".utf8).write(to: repo.appendingPathComponent("b.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-q", "-m", "second"])

        let local = try XCTUnwrap(BuildFreshness.latestCommitTime(inRepo: repo))
        let remote = try XCTUnwrap(BuildFreshness.remoteCommitTime(inRepo: repo))

        XCTAssertGreaterThanOrEqual(local, remote,
                                    "the checkout holds a commit origin/main does not")
        XCTAssertLessThan(local.timeIntervalSinceNow, 60)
    }

    func testARepositoryWithNoTrackingRefReadsAsNoRemoteCommitTime() throws {
        // A fresh clone that has never fetched, or a repo with no origin at
        // all. Nothing to compare, which the verdict turns into "fall back to
        // the checkout" rather than into an error Dan sees.
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildFreshnessRepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "init", "-q", "-b", "main"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertNil(BuildFreshness.remoteCommitTime(inRepo: repo))
    }

    func testAPathThatDoesNotExistReadsAsNoCommitTime() {
        XCTAssertNil(BuildFreshness.latestCommitTime(
            inRepo: URL(fileURLWithPath: "/nowhere/at/all")))
        XCTAssertNil(BuildFreshness.remoteCommitTime(
            inRepo: URL(fileURLWithPath: "/nowhere/at/all")))
    }
}
