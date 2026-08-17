import XCTest

/// PostRoll says at launch that it cannot reach its code folder, rather than
/// waiting for the first generation to be attempted (#652).
///
/// An app that cannot generate anything at all otherwise looks completely
/// normal: the events load, the screens draw, and nothing is wrong until Dan
/// picks a day and presses a button. The information exists at launch, so
/// withholding it until he spends effort is a choice, not a limitation.
final class LaunchProjectCheckTests: XCTestCase {

    private func makeCheckout() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pr-launch-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("postroll"),
                               withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("venv/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("python3"))
        return dir
    }

    func testAUsableCheckoutIsReadyAtLaunch() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        XCTAssertEqual(LaunchProjectCheck.outcome(root: checkout), .ready(checkout))
    }

    func testAnAbsentCheckoutIsReportedAtLaunch() {
        let gone = URL(fileURLWithPath: "/tmp/postroll-gone-\(UUID().uuidString)")
        XCTAssertEqual(LaunchProjectCheck.outcome(root: gone), .unreachable(.missing(gone)))
    }

    func testABuildThatRecordedNothingIsReportedAtLaunch() {
        XCTAssertEqual(LaunchProjectCheck.outcome(root: nil), .unreachable(.notRecorded))
    }

    /// The launch notice and the refusal a generation gives say the same thing,
    /// because they are the same sentence rather than two written separately.
    ///
    /// Two texts about one condition drift, and the moment they disagree Dan
    /// has to work out which one is telling the truth about his machine (L144).
    func testTheLaunchNoticeIsTheSameSentenceAGenerationWouldGive() {
        let gone = URL(fileURLWithPath: "/Volumes/Work/Apps/PostRoll")
        XCTAssertEqual(LaunchProjectCheck.message(.missing(gone)),
                       PythonBridgeError.projectRootUnavailable(.missing(gone))
                           .message(whileDoing: .generation))
    }

    /// The heading says what is not going to work. A title naming only the
    /// fault leaves Dan to work out whether it matters to him right now.
    func testTheHeadingSaysWhatWillNotWork() {
        XCTAssertTrue(LaunchProjectCheck.title.lowercased().contains("generate"),
                      LaunchProjectCheck.title)
    }

    /// It warns, it does not block. Everything that is not generation still
    /// works, so quitting him out of the app or trapping him behind a modal
    /// would take away more than the fault does.
    func testTheNoticeIsDismissible() {
        XCTAssertTrue(LaunchProjectCheck.isDismissible)
    }
}
