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
