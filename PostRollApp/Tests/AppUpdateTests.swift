import XCTest

/// What the update button actually runs, and how its result is read back
/// (#686).
///
/// The sheet used to print a command for Dan to copy into Terminal. The button
/// has to do the same thing that command did, and the two must not be able to
/// drift: a button that rebuilds without pulling, next to a sentence saying the
/// change has not reached this Mac yet, would send him round exactly the loop
/// `BuildFreshness.Remedy` exists to break.
///
/// So the parity between the two is asserted here rather than left to whoever
/// edits one of them next.
final class AppUpdateTests: XCTestCase {

    private let repo = URL(fileURLWithPath: "/Users/dan/Apps/PostRoll")
    private lazy var layout = AppPaths.Layout(
        root: FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdateTests-\(UUID().uuidString)"))

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: layout.root)
    }

    private func plan(_ remedy: BuildFreshness.Remedy) -> AppUpdate.LaunchPlan {
        AppUpdate.plan(repo: repo, remedy: remedy, layout: layout)
    }

    // MARK: - What gets run

    func testTheUpdaterRunsFromTheCheckoutBeingUpdated() {
        // Not from the running bundle and not from a path typed here: the app
        // in /Applications is the OLD build, and the script that knows how to
        // build the new one is the one sitting in the checkout the verdict was
        // reached against (L153).
        let arguments = plan(.rebuild).arguments
        XCTAssertTrue(
            arguments.contains("\(repo.path)/PostRollApp/update-postroll.sh"),
            "the button runs something other than the checkout's own updater: \(arguments)")
    }

    func testTheUpdaterIsToldWhereToReportProgressAndHowItEnded() {
        // The app reads these three files. If the plan named different ones the
        // sheet would sit on an empty progress file forever while the update
        // ran perfectly, and nothing would say so (L100).
        let plan = self.plan(.rebuild)
        XCTAssertEqual(plan.progressFile, layout.updateProgressFile)
        XCTAssertEqual(plan.outcomeFile, layout.updateOutcomeFile)
        XCTAssertEqual(plan.logFile, layout.updateLogFile)
        for file in [plan.progressFile, plan.outcomeFile, plan.logFile] {
            XCTAssertTrue(plan.arguments.contains(file.path),
                          "\(file.lastPathComponent) is never passed to the updater, "
                          + "so it reports somewhere nothing reads: \(plan.arguments)")
        }
    }

    // MARK: - Parity with the command the sheet spells out

    func testACheckoutBehindMainIsPulledFirst() {
        XCTAssertTrue(plan(.pullThenRebuild).arguments.contains("--pull"))
    }

    func testACheckoutAlreadyHoldingTheWorkIsNotPulled() {
        // Pulling anyway is not a harmless extra step: it moves a checkout Dan
        // may have deliberately left where it is.
        XCTAssertFalse(plan(.rebuild).arguments.contains("--pull"))
    }

    func testTheButtonPullsExactlyWhenTheWrittenCommandSaysItWill() {
        // The two halves of one remedy, held together. Whichever of them is
        // edited next, this fails rather than letting the sheet say one thing
        // and the button do another (L41).
        for remedy in [BuildFreshness.Remedy.rebuild, .pullThenRebuild] {
            let written = BuildFreshness.command(for: remedy, repo: repo)
            XCTAssertEqual(
                plan(remedy).arguments.contains("--pull"),
                written.contains("git pull"),
                "the command shown for \(remedy) and what the button does "
                + "disagree about pulling: the sheet says \"\(written)\"")
        }
    }

    // MARK: - Reading how it ended

    func testNoOutcomeFileIsNotSuccess() throws {
        // The state before anything has run, and also the state while an update
        // is in flight. Neither is an update that finished, and treating a
        // missing file as a pass is how a check reports green having measured
        // nothing (L98).
        XCTAssertNil(AppUpdate.readOutcome(at: layout.updateOutcomeFile))
    }

    func testAnUnreadableOutcomeIsNotSuccess() throws {
        try FileManager.default.createDirectory(
            at: layout.updateOutcomeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("half a file".utf8).write(to: layout.updateOutcomeFile)

        XCTAssertNil(AppUpdate.readOutcome(at: layout.updateOutcomeFile),
                     "a file that could not be decoded was read as a finished "
                     + "update, so a broken updater reports as a working one")
    }

    func testAFailureIsReadBackWithEverythingNeededToActOnIt() throws {
        try write(#"""
        {"ok":false,"exit_code":65,"phase":"Running the Swift tests before installing",
         "message":"BuildFreshnessTests: XCTAssertEqual failed","finished_at":1750000000}
        """#)

        let outcome = try XCTUnwrap(AppUpdate.readOutcome(at: layout.updateOutcomeFile))
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.exitCode, 65)
        XCTAssertEqual(outcome.phase, "Running the Swift tests before installing")
        XCTAssertEqual(outcome.message, "BuildFreshnessTests: XCTAssertEqual failed")
    }

    func testASuccessIsReadBackAsOneToo() throws {
        try write(#"{"ok":true,"exit_code":0,"phase":"Launching","message":"","finished_at":1750000000}"#)
        XCTAssertEqual(AppUpdate.readOutcome(at: layout.updateOutcomeFile)?.ok, true)
    }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: layout.updateOutcomeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(json.utf8).write(to: layout.updateOutcomeFile)
    }

    // MARK: - What the failure says

    func testTheFailureNamesTheStepItStoppedIn() {
        // A red test suite, a compile error, a dirty working tree and a missing
        // toolchain are four different problems with four different next steps,
        // and "the update failed" is the right sentence for none of them (L11).
        let tests = AppUpdate.failureMessage(
            .init(ok: false, exitCode: 65,
                  phase: "Running the Swift tests before installing",
                  message: "", finishedAt: Date(timeIntervalSince1970: 1)))
        let pull = AppUpdate.failureMessage(
            .init(ok: false, exitCode: 1, phase: "Getting the newest code",
                  message: "", finishedAt: Date(timeIntervalSince1970: 1)))

        XCTAssertTrue(tests.contains("Running the Swift tests before installing"), tests)
        XCTAssertTrue(pull.contains("Getting the newest code"), pull)
        XCTAssertNotEqual(tests, pull,
                          "two entirely different failures are described with "
                          + "the same sentence")
    }

    func testTheFailureCarriesTheExitCode() {
        let message = AppUpdate.failureMessage(
            .init(ok: false, exitCode: 65, phase: "Building PostRoll (Release)",
                  message: "", finishedAt: Date(timeIntervalSince1970: 1)))
        XCTAssertTrue(message.contains("65"),
                      "the exit code is nowhere in what Dan is shown, so the "
                      + "only distinguishing detail lives in a log: \(message)")
    }

    func testAFailureThatSaidNothingStillSaysWhereItStopped() {
        // The build going quiet and dying is a state, not a reason to show a
        // blank. An empty message must not produce an empty sentence.
        let message = AppUpdate.failureMessage(
            .init(ok: false, exitCode: 1, phase: "Building PostRoll (Release)",
                  message: "", finishedAt: Date(timeIntervalSince1970: 1)))
        XCTAssertFalse(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(message.contains("Building PostRoll (Release)"), message)
    }

    // MARK: - When it must not start

    func testWorkInFlightNamesWhatIsRunning() {
        // Installing quits the running app, so a generation part way through
        // loses its write-back. Refusing is the whole point, and a refusal that
        // does not say what is running leaves Dan to guess which of three
        // things to wait for (L11).
        let reason = try? XCTUnwrap(
            AppUpdate.busyReason(generating: true, readingPrograms: false, exporting: false))
        XCTAssertEqual(reason?.contains("generat"), true, reason ?? "no reason given")
    }

    func testEachKindOfWorkInFlightIsNamedSeparately() {
        let generating = AppUpdate.busyReason(generating: true, readingPrograms: false, exporting: false)
        let reading = AppUpdate.busyReason(generating: false, readingPrograms: true, exporting: false)
        let exporting = AppUpdate.busyReason(generating: false, readingPrograms: false, exporting: true)
        XCTAssertEqual(Set([generating, reading, exporting].compactMap { $0 }).count, 3,
                       "two different kinds of work in flight produce the same "
                       + "sentence, so the refusal cannot be acted on")
    }

    func testNothingRunningIsNoReasonToRefuse() {
        // The control for the three above: a guard that refused whatever the
        // state would satisfy them all while blocking every update (L159).
        XCTAssertNil(AppUpdate.busyReason(generating: false, readingPrograms: false, exporting: false))
    }
}
