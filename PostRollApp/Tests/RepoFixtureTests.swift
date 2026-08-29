import XCTest

/// #271: a refused folder reads as a permissions problem, not a red suite.
///
/// The repo lives under ~/Documents, which macOS protects. On one run the test
/// process was refused access and five fixture-reading suites went red at once
/// with `Operation not permitted`, which looked like five broken test suites.
/// The install gate runs this suite before copying to /Applications, so a gate
/// that fails for reasons unrelated to the code teaches the operator to bypass
/// it every time, and a gate that is always bypassed is the same as no gate.
///
/// The refusal here is real: a file with its permissions actually removed, read
/// through the same API the fixtures are read with. A stubbed error would only
/// prove the classifier agrees with the error I invented for it.
final class RepoFixtureTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file, so there is no refusal to classify")
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let dir else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func testARefusedFileIsCalledAPermissionsProblem() throws {
        let file = dir.appendingPathComponent("locked.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        do {
            _ = try Data(contentsOf: file)
            XCTFail("the file was readable, so there is nothing to classify")
        } catch {
            XCTAssertEqual(RepoFixture.classify(error, path: file.path),
                           .permissionDenied(path: file.path))
        }
    }

    func testARefusedFolderIsAlsoAPermissionsProblem() throws {
        // The real shape of the incident: the FOLDER was protected, not the
        // file, which is how Documents behaves.
        let nested = dir.appendingPathComponent("closed")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("fixture.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nested.path)

        do {
            _ = try Data(contentsOf: file)
            XCTFail("the folder was readable, so there is nothing to classify")
        } catch {
            XCTAssertEqual(RepoFixture.classify(error, path: file.path),
                           .permissionDenied(path: file.path))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path)
    }

    func testAMissingFileIsNotCalledAPermissionsProblem() {
        // The two need opposite responses: a missing fixture is a real defect
        // in the test, and telling the operator to grant Documents access for
        // it would send the diagnosis somewhere unrelated.
        let missing = dir.appendingPathComponent("never-written.json")
        do {
            _ = try Data(contentsOf: missing)
            XCTFail("expected a read failure")
        } catch {
            XCTAssertEqual(RepoFixture.classify(error, path: missing.path),
                           .notFound(path: missing.path))
        }
    }

    func testThePermissionMessageSaysWhatItIsAndWhatToDo() {
        let message = RepoFixture.Failure.permissionDenied(path: "/x/y.json").message
        XCTAssertTrue(message.contains("PERMISSIONS"), message)
        XCTAssertTrue(message.contains("Documents"), message)
        XCTAssertTrue(message.contains("SKIP_INSTALL_TESTS"), message)
    }

    func testTheMissingFileMessageDoesNotBlameMacOS() {
        let message = RepoFixture.Failure.notFound(path: "/x/y.json").message
        XCTAssertFalse(message.contains("PERMISSIONS"), message)
        XCTAssertFalse(message.contains("SKIP_INSTALL_TESTS"), message)
    }

    // ── it is actually used ───────────────────────────────────────────────────

    func testItReadsARealFixtureThroughTheHelper() throws {
        let text = try RepoFixture.text("tests/fixtures/layout_sidecar.json")
        XCTAssertTrue(text.contains("_layout.json"), "the helper did not return the file")
    }

    // ── walking a source tree that lives on a symlinked path (#941) ──────────

    /// A directory of Swift files, reached through a symlink to it.
    ///
    /// The exact shape the suite meets in a worktree: on macOS `/tmp` is a
    /// symlink to `/private/tmp`, so the path a test compiled from and the path
    /// an enumerator hands back differ by a leading `/private`.
    private func treeReachedThroughASymlink() throws -> (real: URL, link: URL) {
        let real = dir.appendingPathComponent("real", isDirectory: true)
        let nested = real.appendingPathComponent("Views", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "top".write(to: real.appendingPathComponent("AppState.swift"),
                        atomically: true, encoding: .utf8)
        try "nested".write(to: nested.appendingPathComponent("EventListView.swift"),
                           atomically: true, encoding: .utf8)
        try "not swift".write(to: real.appendingPathComponent("notes.txt"),
                              atomically: true, encoding: .utf8)

        let link = dir.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return (real, link)
    }

    func testAFileIsNamedRelativelyEvenWhenTheRootIsReachedThroughASymlink() throws {
        let (_, link) = try treeReachedThroughASymlink()

        let found = RepoFixture.files(under: link, withExtension: "swift")
        XCTAssertEqual(found.map(\.relativePath).sorted(),
                       ["AppState.swift", "Views/EventListView.swift"],
                       "the sweep did not name the files relative to the root it was given")

        for entry in found {
            XCTAssertEqual(try String(contentsOf: entry.url, encoding: .utf8).isEmpty, false,
                           "the url handed back does not open: \(entry.url.path)")
        }
    }

    func testTheOldTrimmingWouldStillFuseTwoNamesTogether() throws {
        // The control, and the shape that shipped (#941, L251). Trimming a root
        // off the FRONT of a path removes a substring from the MIDDLE when the
        // two disagree about symlinks, and the two halves fuse: `/private` plus
        // `AppState.swift` became `privateAppState.swift`, a file nobody wrote.
        //
        // Kept so this suite fails if the defect stops being reproducible here,
        // which would mean the new helper is being credited with a fix the
        // platform made (L159).
        let (real, link) = try treeReachedThroughASymlink()
        let resolved = real.appendingPathComponent("AppState.swift").resolvingSymlinksInPath()
        XCTAssertNotEqual(resolved.path, link.appendingPathComponent("AppState.swift").path,
                          "the symlink and its target resolve to one path here, so this "
                          + "machine cannot show the defect and the control proves nothing")

        let trimmed = resolved.path.replacingOccurrences(of: link.path + "/", with: "")
        XCTAssertNotEqual(trimmed, "AppState.swift",
                          "trimming produced the right answer, so this control no longer "
                          + "reproduces what #941 was")
    }

    func testAFileOutsideTheRootIsRefusedRatherThanNamedOddly() throws {
        // The enumerator can only hand back what is under the root, so this is
        // about the comparison itself: an answer of nil must not be turned into
        // a plausible looking relative path by whatever is left after a trim.
        let (real, _) = try treeReachedThroughASymlink()
        let elsewhere = dir.appendingPathComponent("outside.swift")
        XCTAssertNil(RepoFixture.relativePath(of: elsewhere, under: real),
                     "a file outside the root was given a name relative to it")
        XCTAssertEqual(RepoFixture.relativePath(of: real.appendingPathComponent("AppState.swift"),
                                                under: real),
                       "AppState.swift")
    }

    func testNoSuiteDerivesARelativePathByTrimmingARootOffTheFront() throws {
        // The guard. This suite is the only place the trimming may appear, as
        // the control above, and a rule about the SHAPE keeps it from coming
        // back in the next sweep somebody writes (L30).
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(
            at: testsDir, includingPropertiesForKeys: nil)

        var offenders: [String] = []
        for url in entries where url.pathExtension == "swift" {
            guard url.lastPathComponent != URL(fileURLWithPath: #filePath).lastPathComponent,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("replacingOccurrences(of: root.path")
                || text.contains(".path.replacingOccurrences(of:") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "these suites build a relative path by trimming a root off the front of "
                      + "an absolute one, which removes a substring from the middle the moment "
                      + "the two disagree about symlinks and fuses two names into a file "
                      + "nobody wrote: \(offenders.sorted()). Use RepoFixture.files(under:) "
                      + "or RepoFixture.relativePath(of:under:) (#941, L251).")
    }

    func testEveryFixtureReadingSuiteGoesThroughTheHelper() throws {
        // Derived from the source rather than a list here, so a suite added
        // later is covered on the day it lands: the failure mode is that ONE
        // suite still reads the file itself and reports a bare permissions
        // error as a broken test.
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(
            at: testsDir, includingPropertiesForKeys: nil)

        var offenders: [String] = []
        for url in entries where url.pathExtension == "swift" {
            guard url.lastPathComponent != "RepoFixture.swift",
                  url.lastPathComponent != "RepoFixtureTests.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("tests/fixtures/") else { continue }
            if !text.contains("RepoFixture.") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "these suites read a repo fixture without RepoFixture, so a refused "
                      + "folder reports as a broken test: \(offenders.sorted())")
    }
}
