import XCTest

/// #956: a source-scanning test that reports a tree which moved underneath it.
///
/// Several suites here read the app's own source at run time, so they see what
/// is on disk at the instant they run rather than what the bundle was compiled
/// from. On 2026-08-29 `build-install.sh` ran the pre-install suite while a
/// branch switch happened in the same checkout, and a source-scanning test
/// failed naming a real file. It was accurate about the disk at that moment and
/// wrong about the commit, so it read exactly like a genuine regression and
/// threw away a four minute run.
///
/// A failure that cannot tell "this code is wrong" from "this file changed
/// while I read it" teaches whoever sees it to re-run rather than to look
/// (L11), which is the habit that makes every later real failure cost a run.
final class CheckoutStabilityTests: XCTestCase {

    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    /// A `.git` directory shaped enough for the fingerprint to read it.
    private func makeGitDir(head: String) throws {
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("\(head)\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        try Data("index".utf8).write(to: git.appendingPathComponent("index"))
    }

    func testTheFingerprintChangesWhenTheBranchDoes() throws {
        try makeGitDir(head: "ref: refs/heads/main")
        let before = RepoFixture.checkoutFingerprint(root: repo)

        try makeGitDir(head: "ref: refs/heads/somebody-elses-branch")
        let after = RepoFixture.checkoutFingerprint(root: repo)

        XCTAssertNotNil(before)
        XCTAssertNotEqual(before, after,
                          "a branch switch under the run reads the same as a "
                          + "settled tree, so nothing can tell them apart")
    }

    func testTheFingerprintIsStableWhenNothingMoves() throws {
        // The other direction, or every run would report a moved tree and the
        // outcome would be noise rather than a signal (L36).
        try makeGitDir(head: "ref: refs/heads/main")

        XCTAssertEqual(RepoFixture.checkoutFingerprint(root: repo),
                       RepoFixture.checkoutFingerprint(root: repo))
    }

    func testAWorktreeIsFollowedToTheCheckoutItBelongsTo() throws {
        // A worktree's `.git` is a FILE naming the real gitdir, and a worktree
        // is exactly where a session runs to avoid this hazard, so failing to
        // follow it would leave the protection absent where it is most wanted.
        let real = repo.appendingPathComponent("primary/.git")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: real.appendingPathComponent("HEAD"))
        try Data("index".utf8).write(to: real.appendingPathComponent("index"))

        let tree = repo.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("gitdir: \(real.path)\n".utf8)
            .write(to: tree.appendingPathComponent(".git"))

        XCTAssertEqual(RepoFixture.checkoutFingerprint(root: tree),
                       "ref: refs/heads/main@" + trailingStamp(of: real))
    }

    private func trailingStamp(of gitDir: URL) -> String {
        let index = gitDir.appendingPathComponent("index")
        let when = (try? FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate]
                       as? Date)?.timeIntervalSince1970 ?? 0
        return "\(when)"
    }

    func testACheckoutWithNoGitDirectoryIsNotReportedAsMoved() throws {
        // An exported copy has no `.git` at all. Refusing there would make the
        // suite unrunnable for a reason unrelated to the code, and unknown on
        // both sides is not a change (L11).
        XCTAssertNil(RepoFixture.checkoutFingerprint(root: repo))
        XCTAssertFalse(RepoFixture.checkoutMoved(since: nil, now: nil))
    }

    func testAMovedTreeIsReportedAsItsOwnThing() {
        XCTAssertTrue(RepoFixture.checkoutMoved(since: "a", now: "b"))
        XCTAssertFalse(RepoFixture.checkoutMoved(since: "a", now: "a"))
    }

    func testTheMessageSaysWhatToDoRatherThanNamingTheFile() {
        // A message that tells somebody how to recover has to name a step that
        // changes the state they are stuck in (L111). Re-running is the remedy
        // here, and it is the one thing the old failure looked like a reason
        // NOT to do.
        let said = RepoFixture.treeMovedMessage("a sweep found something")

        XCTAssertTrue(said.contains("Re-run"), said)
        XCTAssertTrue(said.contains("worktree"), said)
        // The FIRST line is what a reader scanning a wall of test output sees,
        // so the cause has to be there rather than after the detail. Asserted
        // on the line rather than on an exact sentence, so the wording can be
        // improved without a guard defending the old copy (L103).
        let opening = said.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(opening.uppercased().contains("CHECKOUT"),
                      "the first line does not say the checkout is the cause, "
                      + "so this reads as the rule being broken: \(opening)")
    }
}
