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

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildFreshnessScope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path,
                             "-c", "user.email=t@example.com",
                             "-c", "user.name=T",
                             "-c", "commit.gpgsign=false"] + arguments
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
        try git(["commit", "-q", "-m", message])
        let stamp = try git(["log", "-1", "--format=%ct"])
        return Date(timeIntervalSince1970: TimeInterval(stamp) ?? 0)
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
        sleepOneSecond()
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
        sleepOneSecond()
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
        try git(["commit", "-q", "-m", "both"])
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
            sleepOneSecond()
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
        sleepOneSecond()
        try commit("postroll/ai/late.py", message: "python after the ref")
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"])

        let remote = try XCTUnwrap(BuildFreshness.remoteCommitTime(inRepo: repo))

        XCTAssertEqual(remote, swift,
                       "origin/main is judged over the whole repository, so a "
                       + "Python only merge tells Dan to pull and rebuild for a "
                       + "change that is already running")
    }

    /// Commit times have one second resolution, so two commits made in the same
    /// second are indistinguishable and a test comparing them proves nothing
    /// (L134).
    ///
    /// Two seconds rather than one, measured: with a one second gap and a one
    /// second tolerance, three of these tests passed against code that had not
    /// been written yet. The comparisons are exact now as well, since git
    /// stamps whole seconds and the fixture reads back the same value.
    private func sleepOneSecond() {
        Thread.sleep(forTimeInterval: 2.05)
    }
}
