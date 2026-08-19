import XCTest

/// What the window does while an update runs, and afterwards (#686).
///
/// The awkward part of updating PostRoll from inside PostRoll is that the app
/// does not survive its own update: build-install.sh quits it before replacing
/// /Applications/PostRoll.app and reopens it afterwards. So there are two
/// halves to get right, and they fail in opposite directions.
///
/// While the app is alive it must show the update as working, and must not let
/// a second one start on top of the first. Once it is gone, a failure has no
/// screen to appear on, so the next launch has to find it: a reason written
/// only to a surface that dies with the attempt leaves Dan pressing the same
/// button with no way to learn why it did nothing (L148, L164).
final class AppUpdateStateTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppUpdateState-\(UUID().uuidString)")

    private let repo = URL(fileURLWithPath: "/tmp/AppUpdateStateRepo")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// An AppState whose updater is this test rather than a real build.
    ///
    /// The seam exists because the real one runs xcodebuild against a checkout
    /// and reinstalls /Applications/PostRoll.app. A suite that could reach that
    /// is a suite that can replace the app it is running under (L2).
    @MainActor
    private func state(launch: @escaping @Sendable (AppUpdate.LaunchPlan) throws -> Void
                       = { _ in }) -> AppState {
        let state = AppState(events: [],
                             storeURL: root.appendingPathComponent("events.json"),
                             dataRoot: root)
        state.launchUpdate = launch
        return state
    }

    private func behind() -> BuildBehind {
        BuildBehind(builtAt: Date(timeIntervalSince1970: 1_000),
                    latestCommit: Date(timeIntervalSince1970: 2_000),
                    remedy: .rebuild, repo: repo)
    }

    @MainActor
    private func writeOutcome(_ json: String, to state: AppState) throws {
        let file = state.updateOutcomeFile
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
    }

    private let failedOutcome = #"""
    {"ok":false,"exit_code":65,"phase":"Running the Swift tests before installing",
     "message":"XCTAssertEqual failed","finished_at":1750000000}
    """#

    // MARK: - Starting

    @MainActor
    func testPressingUpdateRunsTheUpdaterForThisCheckout() throws {
        let launched = Launched()
        let state = state(launch: { launched.record($0) })

        state.startUpdate(for: behind(), busyReason: nil)

        let plan = try XCTUnwrap(launched.plan, "nothing was run at all")
        XCTAssertTrue(plan.arguments.contains { $0.contains(repo.path) },
                      "the update was run against some checkout other than the "
                      + "one the warning was about: \(plan.arguments)")
        XCTAssertNotNil(state.updateStartedAt,
                        "the update is running and the sheet has no way to know")
    }

    @MainActor
    func testASecondPressDoesNotStartASecondBuild() {
        // Two xcodebuilds writing one derived data folder, two installs racing
        // for /Applications, and a progress file two runs are both writing.
        // Assume it runs twice, because a button can always be pressed twice.
        let launched = Launched()
        let state = state(launch: { launched.record($0) })

        state.startUpdate(for: behind(), busyReason: nil)
        state.startUpdate(for: behind(), busyReason: nil)

        XCTAssertEqual(launched.count, 1,
                       "a second update was started on top of the first")
    }

    @MainActor
    func testAnUpdateIsRefusedWhileWorkIsInFlight() {
        // Installing quits the app, and a generation part way through loses
        // everything it has not written back. Refusing is the point; saying
        // what to wait for is what makes the refusal actionable.
        let launched = Launched()
        let state = state(launch: { launched.record($0) })

        state.startUpdate(for: behind(), busyReason: "a week is generating")

        XCTAssertEqual(launched.count, 0, "the update ran over work in flight")
        XCTAssertEqual(state.updateRefusal, "a week is generating")
        XCTAssertNil(state.updateStartedAt,
                     "the sheet shows an update running that was never started")
    }

    @MainActor
    func testAnUpdaterThatCouldNotBeStartedSaysSoRatherThanSpinning() throws {
        // The failure with no output to read: the script is missing, the disk
        // is full, the binary cannot be executed. Nothing will ever write an
        // outcome file, so an update left looking like it is working would spin
        // until Dan gave up on it (L110).
        struct CouldNotRun: Error {}
        let state = state(launch: { _ in throw CouldNotRun() })

        state.startUpdate(for: behind(), busyReason: nil)

        XCTAssertNil(state.updateStartedAt,
                     "an update that never started is being shown as running")
        let failure = try XCTUnwrap(state.updateFailure,
                                    "nothing at all was said about an update "
                                    + "that could not be started")
        XCTAssertFalse(failure.ok)
    }

    @MainActor
    func testStartingClearsTheLastAttemptsProgressAndOutcome() throws {
        // A retry that inherits the previous attempt's files reports the old
        // failure the moment it starts, and shows the phase the old run died in
        // as though it were this one's (L133).
        try writeOutcome(failedOutcome, to: state())
        let state = state()
        state.checkUpdateOutcome()
        XCTAssertNotNil(state.updateFailure, "the fixture did not take")

        state.startUpdate(for: behind(), busyReason: nil)

        XCTAssertNil(state.updateFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.updateOutcomeFile.path),
                       "the previous attempt's outcome is still on disk, so the "
                       + "next reading of it reports a failure that has been retried")
    }

    // MARK: - How it ended

    @MainActor
    func testAFailureIsPickedUpWhileTheAppIsStillOpen() throws {
        // Everything before the install happens with the app alive: a red
        // suite, a compile error, a pull that would overwrite local changes.
        let state = state()
        state.startUpdate(for: behind(), busyReason: nil)
        try writeOutcome(failedOutcome, to: state)

        state.checkUpdateOutcome()

        XCTAssertEqual(state.updateFailure?.exitCode, 65)
        XCTAssertNil(state.updateStartedAt,
                     "the update is over and the sheet still shows it running")
    }

    @MainActor
    func testAFailureFromAnUpdateThatOutlivedTheAppIsFoundAtLaunch() throws {
        // The case the outcome file exists for. Nothing in this session started
        // an update: the previous one quit the app, failed at the install step,
        // and this is the only place its reason survives.
        let state = state()
        try writeOutcome(failedOutcome, to: state)

        state.checkUpdateOutcome()

        XCTAssertEqual(state.updateFailure?.phase,
                       "Running the Swift tests before installing")
    }

    @MainActor
    func testAFailureIsKeptUntilItIsAcknowledged() throws {
        // Reading it must not consume it. An app opened and closed again before
        // Dan looked at the sheet would otherwise take the reason with it, and
        // he would be back at a button that did nothing with nothing to read.
        let state = state()
        try writeOutcome(failedOutcome, to: state)
        state.checkUpdateOutcome()

        XCTAssertTrue(FileManager.default.fileExists(atPath: state.updateOutcomeFile.path))

        state.dismissUpdateFailure()

        XCTAssertNil(state.updateFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.updateOutcomeFile.path),
                       "an acknowledged failure is reported again at the next launch")
    }

    @MainActor
    func testASuccessfulUpdateLeavesNothingToReport() throws {
        // The ordinary end: the app was quit, replaced and reopened, and this
        // IS the new build. There is nothing to tell him, and a leftover file
        // saying an update happened would be read again at every launch.
        let state = state()
        try writeOutcome(
            #"{"ok":true,"exit_code":0,"phase":"Launching","message":"","finished_at":1750000000}"#,
            to: state)

        state.checkUpdateOutcome()

        XCTAssertNil(state.updateFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.updateOutcomeFile.path))
    }

    @MainActor
    func testAnUpdateStillRunningIsNotTreatedAsFinished() {
        // No outcome file yet is the normal state for the several minutes a
        // build takes. Reading that as a finished update would take the
        // progress off the screen while the work carried on (L98).
        let state = state()
        state.startUpdate(for: behind(), busyReason: nil)

        state.checkUpdateOutcome()

        XCTAssertNotNil(state.updateStartedAt)
        XCTAssertNil(state.updateFailure)
    }

    /// Records what the seam was asked to launch.
    private final class Launched: @unchecked Sendable {
        private let lock = NSLock()
        private var plans: [AppUpdate.LaunchPlan] = []
        func record(_ plan: AppUpdate.LaunchPlan) {
            lock.withLock { plans.append(plan) }
        }
        var plan: AppUpdate.LaunchPlan? { lock.withLock { plans.first } }
        var count: Int { lock.withLock { plans.count } }
    }
}
