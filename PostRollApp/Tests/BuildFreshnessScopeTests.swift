import XCTest

/// The out of date warning judges the app against the code that is actually IN
/// it (#691).
///
/// Only the Swift half is frozen into the bundle. The Python pipeline is read
/// live off the checkout on every run, so a week of Python only commits leaves
/// the running app entirely current while the warning says it may be missing
/// shipped work and tells Dan to rebuild.
///
/// That is the worst shape a warning can have: a false alarm whose named remedy
/// cannot clear it. Rebuilding produces a new build and the same verdict at the
/// next launch, which is the loop the `pullThenRebuild` remedy exists to break
/// for the other case, and it is how a warning becomes something to dismiss on
/// reflex (L36). The monitor has to judge by the same predicate the action
/// would (L144): a rebuild changes what is in the bundle, so only changes to
/// what goes IN the bundle can make a rebuild the answer.
///
/// These run real git against real repositories in a temp directory, because
/// what is under test is a pathspec: a stub would only confirm what I already
/// believe git does with one (L52).
final class BuildFreshnessScopeTests: XCTestCase {

    private var repo: URL!

    /// Where this fixture's first commit is stamped (#994).
    ///
    /// A fixed instant, not `Date()`. It is in the past and it never moves, so
    /// nothing here can pass or fail because of when the suite ran.
    static let firstCommitAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// How far apart consecutive commits are stamped.
    ///
    /// Comfortably over git's one second resolution, which is the whole point:
    /// two commits inside one second are the same instant to every reader, and
    /// that ambiguity is what the old 2.05s sleep was buying. A minute costs
    /// nothing when it is stamped rather than waited for.
    static let betweenCommits: TimeInterval = 60

    /// The instant the NEXT commit will carry. Advanced by every commit this
    /// fixture makes, and reset per test by `setUpWithError`, so each test gets
    /// the same sequence whatever order the suite runs them in.
    private var nextCommitAt = BuildFreshnessScopeTests.firstCommitAt

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildFreshnessScope-\(UUID().uuidString)")
        nextCommitAt = Self.firstCommitAt
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    /// `at` stamps the commit rather than letting git read the wall clock.
    ///
    /// Both variables, because they are two different fields and git takes the
    /// COMMITTER date for `%ct`, which is what `BuildFreshness` reads. Setting
    /// only the author date would leave every commit at the current second and
    /// this fixture would go back to racing the clock without saying so.
    ///
    /// The environment is inherited and added to, never replaced: git needs the
    /// ambient PATH and HOME to run at all.
    @discardableResult
    private func git(_ arguments: [String], at stamp: Date? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path,
                             "-c", "user.email=t@example.com",
                             "-c", "user.name=T",
                             "-c", "commit.gpgsign=false"] + arguments
        if let stamp {
            let git = "@\(Int(stamp.timeIntervalSince1970)) +0000"
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["GIT_AUTHOR_DATE": git, "GIT_COMMITTER_DATE": git]) { _, new in new }
        }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commit a file at `path`, creating its directories, and return when it
    /// landed.
    @discardableResult
    private func commit(_ path: String, message: String) throws -> Date {
        let file = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(UUID().uuidString.utf8).write(to: file)
        try git(["add", "."])
        try commitNow(message)
        let stamp = try git(["log", "-1", "--format=%ct"])
        return Date(timeIntervalSince1970: TimeInterval(stamp) ?? 0)
    }

    // MARK: - The fixture's own clock

    /// The commits this fixture makes are stamped, not raced (#994).
    ///
    /// Two commits made in the same second are indistinguishable, so these
    /// tests used to sleep 2.05s between them to force a gap: 23.6s of a 24.1s
    /// file, on every run, local and CI, and the single largest block of pure
    /// waiting in the Swift suite.
    ///
    /// Stamping is not merely faster, it is the stronger test. A sleep pins ONE
    /// end of the comparison and lets the wall clock supply the other, so the
    /// gap is a property of how busy the machine is; a stamp pins BOTH ends and
    /// the gap is a property of the fixture (L130, L134, L290).
    ///
    /// This is the positive control on that. If the stamping ever silently
    /// stopped working, every commit would take the current second instead,
    /// several would land in the SAME second, and the ordering assertions below
    /// would compare equal values and pass while proving nothing (L98). So the
    /// gap is asserted here, exactly, rather than assumed everywhere else.
    func testTheFixtureStampsItsCommitsRatherThanRacingTheClock() throws {
        let first = try commit("PostRollApp/Sources/Services/One.swift", message: "one")
        let second = try commit("PostRollApp/Sources/Services/Two.swift", message: "two")
        let third = try commit("PostRollApp/Sources/Services/Three.swift", message: "three")

        XCTAssertEqual(first, Self.firstCommitAt, """
            the first commit landed at \(first) rather than the pinned \
            \(Self.firstCommitAt), so this fixture is reading the wall clock and its \
            commit times move with when the suite happens to run
            """)
        XCTAssertEqual(second.timeIntervalSince(first), Self.betweenCommits, """
            two consecutive commits are \(second.timeIntervalSince(first))s apart rather \
            than the \(Self.betweenCommits)s this fixture stamps, so the ordering every \
            test below depends on is being supplied by the machine
            """)
        XCTAssertEqual(third.timeIntervalSince(second), Self.betweenCommits)
    }

    func testTheStampedGapIsWiderThanGitsOwnResolution() throws {
        // The gap has to clear one second, because git stamps whole seconds and
        // two commits inside one are the same instant to every reader. Asserted
        // rather than left to the constant's spelling, so shrinking it is a
        // failure rather than a silent return to comparing equal values.
        XCTAssertGreaterThan(Self.betweenCommits, 1,
                             "commits stamped \(Self.betweenCommits)s apart can land in "
                             + "the same whole second, which is the exact ambiguity this "
                             + "fixture exists to remove")
    }

    // MARK: - What counts

    func testAChangeToTheAppsOwnCodeCounts() throws {
        // The control, and the case the whole warning exists for: a Swift fix
        // merged and not rebuilt is invisible in the running app, which reads
        // as the fix not working rather than as the fix not being there.
        let swift = try commit("PostRollApp/Sources/Services/Thing.swift", message: "swift")

        let latest = try XCTUnwrap(BuildFreshness.latestCommitTime(inRepo: repo))

        XCTAssertEqual(latest, swift)
    }

    func testAPythonOnlyChangeDoesNotCount() throws {
        // The false alarm. The pipeline is read live off the checkout, so this
        // commit is already running in the app that is being called stale.
        let swift = try commit("PostRollApp/Sources/Services/Thing.swift", message: "swift")
        try commit("postroll/ai/generate_captions.py", message: "python")

        let latest = try XCTUnwrap(BuildFreshness.latestCommitTime(inRepo: repo))

        XCTAssertEqual(latest, swift,
                       "a Python only commit moved the comparison, so a build "
                       + "holding every line of Swift there is reads as stale")
    }

    func testACommitTouchingBothCounts() throws {
        // A change spanning the two halves is a change to the app, and the
        // Python half being live does not make the Swift half live.
        try commit("PostRollApp/Sources/Services/Thing.swift", message: "swift")
        let both = try commitBoth()

        let latest = try XCTUnwrap(BuildFreshness.latestCommitTime(inRepo: repo))

        XCTAssertEqual(latest, both)
    }

    @discardableResult
    private func commitBoth() throws -> Date {
        for path in ["PostRollApp/Sources/Services/Other.swift",
                     "postroll/ai/other.py"] {
            let file = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(UUID().uuidString.utf8).write(to: file)
        }
        try git(["add", "."])
        try commitNow("both")
        let stamp = try git(["log", "-1", "--format=%ct"])
        return Date(timeIntervalSince1970: TimeInterval(stamp) ?? 0)
    }

    func testEveryPathThatIsReadLiveIsLeftOut() throws {
        // One test per named path would be six near identical tests; what
        // matters is that each one on the list actually behaves as excluded,
        // because a list is only as good as its entries (L96).
        let swift = try commit("PostRollApp/Sources/Services/Thing.swift", message: "swift")

        for path in ["postroll/media/collage.py",
                     "tests/test_thing.py",
                     "tools/check_guards.py",
                     ".github/workflows/tests.yml",
                     "README.md",
                     "PostRollApp/build-install.sh"] {
            try commit(path, message: "live: \(path)")

            let latest = try XCTUnwrap(BuildFreshness.latestCommitTime(inRepo: repo))
            XCTAssertEqual(latest, swift,
                           "a commit to \(path) made the running app read as "
                           + "out of date, and rebuilding cannot change that")
        }
    }

    // MARK: - What the sentence claims

    func testTheMessageClaimsOnlyWhatWasMeasured() {
        // The comparison ignores the Python pipeline, so a sentence saying "the
        // newest change to the code" claims more than was measured, and the
        // first Python only week would make it read as a contradiction (L11).
        let message = BuildFreshness.message(
            builtAt: Date(timeIntervalSince1970: 1_000),
            latestCommit: Date(timeIntervalSince1970: 2_000),
            remedy: .rebuild)

        XCTAssertTrue(message.contains("the app's own code"),
                      "the message still speaks for the whole checkout: \(message)")
    }

    // MARK: - The answers that are not a verdict

    func testARepositoryWithNothingBundledInItCannotTell() throws {
        // Nothing was compared, so nothing may be claimed. Reading this as
        // current would be a clean bill of health nobody measured (L98).
        try commit("postroll/ai/only.py", message: "python only, ever")

        XCTAssertNil(BuildFreshness.latestCommitTime(inRepo: repo),
                     "a repository whose bundled paths have never been touched "
                     + "reported a commit time anyway")
    }

    func testTheRemoteRefIsJudgedTheSameWay() throws {
        // The remote half decides whether the remedy is a rebuild or a pull
        // first. Judged by a different rule it would send Dan to pull work that
        // cannot change his build.
        let swift = try commit("PostRollApp/Sources/Services/Thing.swift", message: "swift")
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try commit("postroll/ai/late.py", message: "python after the ref")
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"])

        let remote = try XCTUnwrap(BuildFreshness.remoteCommitTime(inRepo: repo))

        XCTAssertEqual(remote, swift,
                       "origin/main is judged over the whole repository, so a "
                       + "Python only merge tells Dan to pull and rebuild for a "
                       + "change that is already running")
    }

    /// Make the commit at this fixture's next stamped instant, and advance it.
    ///
    /// This used to be a 2.05s sleep before each commit, so git's one second
    /// resolution could not put two of them in the same instant. The comment
    /// recorded that one second had not been enough: with a one second gap and
    /// a one second tolerance, three of these tests passed against code that
    /// had not been written yet.
    ///
    /// That reasoning was right about the ambiguity and wrong about the remedy.
    /// Waiting makes the gap a property of the MACHINE, so the fixture ends up
    /// asserting about how busy the runner is, and it cost 23.6s of this file's
    /// 24.1s on every run, local and CI (#994, L290). Stamping makes the gap a
    /// property of the FIXTURE, pins both ends of every comparison rather than
    /// one (L130, L134), and takes no time at all.
    ///
    /// `testTheFixtureStampsItsCommitsRatherThanRacingTheClock` is the positive
    /// control on it: if this ever stopped stamping, every commit would take
    /// the current second, several would share one, and the ordering assertions
    /// throughout this file would compare equal values and pass (L98).
    private func commitNow(_ message: String) throws {
        try git(["commit", "-q", "-m", message], at: nextCommitAt)
        nextCommitAt = nextCommitAt.addingTimeInterval(Self.betweenCommits)
    }
}
