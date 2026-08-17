import XCTest

/// #661: which code a paid generation actually ran.
///
/// The app does not bundle the Python. `PythonBridge.runProcess` cd's into the
/// recorded checkout and runs it from the WORKING TREE, so the code behind a run
/// is whatever is checked out at that moment: a feature branch, a rebase in
/// flight, a tree with uncommitted edits. Nothing recorded which, so a
/// surprising output was diagnosed against code that may never have run.
///
/// It nearly mattered on 2026-08-17: during #656 a pinned text renderer existed
/// only on a branch while the rebuilt Python environment was already live.
///
/// Read against real repositories built here rather than a stub of git, because
/// a fake would only confirm this test's own guess at what git prints (L52).
final class CheckoutRevisionTests: XCTestCase {

    // MARK: - What the log says

    func testTheNoteNamesTheCommitTheBranchAndACleanTree() {
        let note = CheckoutRevision.describe(
            .known(commit: "1a2b3c4", branch: "main", dirty: false))

        XCTAssertTrue(note.contains("1a2b3c4"), note)
        XCTAssertTrue(note.contains("main"), note)
        XCTAssertTrue(note.contains("clean"), note)
    }

    func testAnUncommittedTreeIsSaidInWords() {
        // The state this exists for. It must be stated, not implied by the
        // absence of the word clean: a reader scanning the log for trouble
        // cannot notice something that is not written down.
        let note = CheckoutRevision.describe(
            .known(commit: "1a2b3c4", branch: "wip/fonts", dirty: true))

        XCTAssertTrue(note.lowercased().contains("uncommitted"), note)
        XCTAssertFalse(note.contains("clean"), note)
    }

    func testACheckoutThatCouldNotBeReadSaysSoRatherThanReadingAsClean() {
        // An unreadable answer is not a good one (L11). A header that quietly
        // said nothing would be indistinguishable from a clean checkout on main.
        let note = CheckoutRevision.describe(.unknown(reason: "not a git repository"))

        XCTAssertTrue(note.contains("not a git repository"), note)
        XCTAssertFalse(note.contains("clean"), note)
        XCTAssertTrue(note.lowercased().contains("unknown"), note)
    }

    // MARK: - Reading a real checkout

    /// A real repository, on a named branch, with one commit.
    private func makeRepo(branch: String = "main") throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckoutRevision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try git(repo, ["init", "-q", "-b", branch])
        _ = try git(repo, ["add", "."])
        _ = try git(repo, ["commit", "-q", "-m", "first"])
        return repo
    }

    @discardableResult
    private func git(_ repo: URL, _ arguments: [String]) throws -> String {
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

    func testACleanCheckoutIsReadAsItsCommitAndBranch() throws {
        let repo = try makeRepo(branch: "main")
        defer { try? FileManager.default.removeItem(at: repo) }
        let head = try git(repo, ["rev-parse", "HEAD"])

        guard case .known(let commit, let branch, let dirty) =
                CheckoutRevision.read(inRepo: repo) else {
            return XCTFail("a real repository must read as known")
        }

        XCTAssertTrue(head.hasPrefix(commit), "\(head) does not start with \(commit)")
        XCTAssertFalse(commit.isEmpty)
        XCTAssertEqual(branch, "main")
        XCTAssertFalse(dirty)
    }

    func testAnUncommittedEditIsSeen() throws {
        // The case the whole record exists for: the code that ran is not any
        // commit at all.
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("edited".utf8).write(to: repo.appendingPathComponent("a.txt"))

        guard case .known(_, _, let dirty) = CheckoutRevision.read(inRepo: repo) else {
            return XCTFail("an edited repository still reads as known")
        }

        XCTAssertTrue(dirty, "an edited working tree must read as dirty")
    }

    func testAnUntrackedFileCountsAsDirty() throws {
        // A new module that has never been added is exactly the shape of "the
        // code that ran is in no commit", and `git status --porcelain` reports
        // it while `git diff --quiet` does not.
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("new".utf8).write(to: repo.appendingPathComponent("brand_new.py"))

        guard case .known(_, _, let dirty) = CheckoutRevision.read(inRepo: repo) else {
            return XCTFail("a repository with an untracked file reads as known")
        }

        XCTAssertTrue(dirty)
    }

    func testWorkOnABranchIsNamedAsThatBranch() throws {
        let repo = try makeRepo(branch: "main")
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try git(repo, ["checkout", "-q", "-b", "wip/pinned-text-shaper"])

        guard case .known(_, let branch, _) = CheckoutRevision.read(inRepo: repo) else {
            return XCTFail("a branch checkout reads as known")
        }

        XCTAssertEqual(branch, "wip/pinned-text-shaper")
    }

    func testADirectoryThatIsNotARepositoryIsUnknownRatherThanClean() throws {
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckoutRevision-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }

        guard case .unknown(let reason) = CheckoutRevision.read(inRepo: plain) else {
            return XCTFail("a directory that is not a repository cannot read as known")
        }

        XCTAssertFalse(reason.isEmpty, "a refusal with no reason is not a reason")
    }

    func testAMissingCheckoutIsUnknown() {
        guard case .unknown = CheckoutRevision.read(
            inRepo: URL(fileURLWithPath: "/nowhere/at/all")) else {
            return XCTFail("a path that does not exist cannot read as known")
        }
    }

    // MARK: - It cannot hang the run

    func testAGitThatNeverAnswersIsGivenUpOnRatherThanWaitedFor() throws {
        // Every generation would otherwise sit behind this with no message,
        // which is worse than a failure because it is indistinguishable from
        // slowness (L110). /bin/sleep stands in for a git that never returns.
        let started = Date()
        let answer = CheckoutRevision.output(
            of: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.5)

        XCTAssertNil(answer, "a command past its deadline has no answer to give")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "the read waited for the whole command")
    }

    // MARK: - It reaches the log

    func testTheRunHeaderCarriesTheRevisionAndTheMarker() {
        let header = PythonBridge.runHeader(
            marker: "9C1F-marker",
            revision: .known(commit: "1a2b3c4", branch: "main", dirty: true))

        XCTAssertTrue(header.contains("9C1F-marker"), header)
        XCTAssertTrue(header.contains("1a2b3c4"), header)
        XCTAssertTrue(header.lowercased().contains("uncommitted"), header)
    }

    func testTheHeaderIsOneLineSoItCannotSplitTheLogEntry() {
        // A branch name cannot contain a newline, but the reason a read failed
        // is arbitrary text from git's stderr, and a second line in the run log
        // is read back as another line of the process's own output.
        let header = PythonBridge.runHeader(
            marker: "m", revision: .unknown(reason: "fatal: not a git\nrepository"))

        XCTAssertFalse(header.contains("\n"), header)
    }

    func testAHostileBranchNameCannotRunAsACommand() {
        // The header is echoed by the launch shell, so anything in it that the
        // shell would expand runs as the user. A branch name is attacker
        // controlled in the sense that matters here: it is whatever was typed.
        let quoted = PythonBridge.shellQuoted("$(touch /tmp/postroll-pwned)")

        XCTAssertTrue(quoted.hasPrefix("'") && quoted.hasSuffix("'"), quoted)
        XCTAssertFalse(quoted.dropFirst().dropLast().contains("'"), quoted)
    }

    func testAnApostropheInAValueIsEscapedRatherThanEndingTheQuote() {
        let quoted = PythonBridge.shellQuoted("Dan's Mac")

        XCTAssertEqual(quoted, "'Dan'\"'\"'s Mac'")
    }
}
