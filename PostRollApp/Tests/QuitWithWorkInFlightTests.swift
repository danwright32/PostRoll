import AppKit
import XCTest

/// Quitting while something is running asks first (#862).
///
/// The app already treats quitting mid work as destructive in exactly one
/// place: `BuildBehindSheet` refuses to start an update while background work
/// is in flight, because installing quits the app (#686). Every other way out
/// was unguarded. Cmd+Q, the Quit menu item, quitting from the Dock and a
/// logout all terminated PostRoll with no check at all, so a generation, an
/// export or a page read was killed and nothing anywhere said what had happened
/// to it.
///
/// `applicationShouldTerminate` is the one place that answers for every route
/// out, including a logout, which is why the guard lives there rather than on
/// the Quit menu item.
///
/// Dan's decision, taken on 2026-08-23: it ASKS, and Quit Anyway is always
/// available. A hard refusal is its own trap on a logout, because the system may
/// kill the app regardless and he is left with a machine that will not log out
/// for a reason buried in an app he is not looking at.
final class QuitWithWorkInFlightTests: XCTestCase {

    // MARK: - The decision

    func testQuittingWithNothingRunningGoesStraightThrough() {
        XCTAssertEqual(QuitGuard.decision(workInFlight: []), .quitNow,
                       "PostRoll asked whether to quit when nothing at all was "
                       + "running, which makes the question meaningless the "
                       + "moment it is worth asking")
    }

    func testQuittingWithWorkRunningAsks() {
        let decision = QuitGuard.decision(workInFlight: ["a week is still generating"])

        guard case .ask = decision else {
            return XCTFail("a quit with a generation in flight went straight "
                           + "through, so the run was killed and nothing said so")
        }
    }

    func testTheQuestionNamesWhatIsRunning() {
        // "Something is running" names nothing Dan can wait for, and the whole
        // reason `AppUpdate` composes a sentence rather than a flag is that a
        // refusal without a subject is a dead end (L11).
        let decision = QuitGuard.decision(workInFlight: ["an export is still running"])

        guard case .ask(let question) = decision else {
            return XCTFail("a quit with an export in flight did not ask")
        }
        XCTAssertTrue(question.contains("an export is still running"),
                      "the question does not say what is running, so there is "
                      + "nothing to decide about: \(question)")
    }

    func testEverythingRunningIsNamed() {
        // Not just the first one. Waiting for the generation to finish and then
        // quitting into a live export is the same defect one step later.
        let decision = QuitGuard.decision(
            workInFlight: ["a week is still generating", "an export is still running"])

        guard case .ask(let question) = decision else {
            return XCTFail("a quit with two runs in flight did not ask")
        }
        XCTAssertTrue(question.contains("a week is still generating"), question)
        XCTAssertTrue(question.contains("an export is still running"), question)
    }

    // MARK: - The delegate, which is what macOS actually asks

    @MainActor
    func testTheDelegateLetsAQuitThroughWhenNothingIsRunning() {
        let delegate = DeepLinkDelegate()
        delegate.workInFlight = { [] }

        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
    }

    @MainActor
    func testADelegateNobodyWiredDoesNotBlockQuitting() {
        // The closure is set by the app at launch, and PostRollApp.swift is not
        // in this bundle. An unwired delegate must let the quit through: no work
        // can be in flight before the first window exists, and a guard that
        // refuses by default would make the app unquittable if the wiring ever
        // broke, which is far worse than the defect it protects against.
        let delegate = DeepLinkDelegate()

        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
    }

    // MARK: - One predicate, not two

    func testTheQuitQuestionAndTheUpdateRefusalNameTheSameWork() {
        // Two sentences composed from two lists drift, and they drift into
        // disagreeing about whether it is safe to quit, which is the one thing
        // both exist to say (L144). Both are built from the same phrases.
        let work = ["a week is still generating", "a program is still being read"]

        guard case .ask(let question) = QuitGuard.decision(workInFlight: work),
              let refusal = AppUpdate.busyReason(workInFlight: work) else {
            return XCTFail("one of the two did not speak at all with work in flight")
        }

        for phrase in work {
            XCTAssertTrue(question.contains(phrase), "the quit question drops \(phrase)")
            XCTAssertTrue(refusal.contains(phrase), "the update refusal drops \(phrase)")
        }
    }

    // MARK: - Every owner of background work is asked

    @MainActor
    func testEveryOwnerInAppOwnersReportsWhetherItIsBusy() {
        // The reason this is a test and not a comment. `AppOwners` holds nine
        // owners of work that outlives a screen, and the update refusal asked
        // three of them: generation, the program read and the export. The other
        // six were invisible to it, so the app would say nothing was running
        // while a performer lookup, an Insights analysis, a caption rerun, an
        // OCR reflow, a notes search or a collage render was in flight.
        //
        // A list of owners kept beside the list of owners is a list they can
        // disagree about, which is the whole reason AppOwners exists (L41, L96).
        // So the answer is derived from the container itself, and this holds
        // every member of it to being derivable.
        let owners = AppOwners()
        let children = Mirror(reflecting: owners).children

        let silent = children.compactMap { child -> String? in
            child.value is BackgroundWork ? nil : (child.label ?? "an unnamed owner")
        }

        XCTAssertTrue(silent.isEmpty,
                      "these owners of background work cannot say whether they "
                      + "are busy, so quitting while they are running asks "
                      + "nothing and kills the work: \(silent)")
        XCTAssertGreaterThanOrEqual(children.count, 9,
                                    "only \(children.count) owners were found in "
                                    + "AppOwners, which has held nine since "
                                    + "#718, so this is reading the wrong thing")
    }

    @MainActor
    func testAnIdleAppHasNothingInFlight() {
        XCTAssertTrue(AppOwners().workInFlight.isEmpty,
                      "a freshly built set of owners reports work in flight")
    }

    // MARK: - The scan itself, proved on something that IS busy

    /// One owner, busy, and one idle. A stub rather than a real manager, because
    /// starting real work means starting a real Python run.
    @MainActor
    private struct Busy: BackgroundWork {
        var hasWorkInFlight: Bool
        var workPhrase: String
    }

    @MainActor
    private struct TwoOwners {
        var running = Busy(hasWorkInFlight: true, workPhrase: "a thing is running")
        var idle = Busy(hasWorkInFlight: false, workPhrase: "another thing is running")
    }

    @MainActor
    func testTheScanFindsWorkThatIsActuallyRunning() {
        // The positive control, and it is not optional. `AppOwners().workInFlight`
        // being empty on an idle app is satisfied just as well by a scan that
        // finds nothing at all, ever, and that version passes every test above
        // this one while the guard does nothing (L98, L159).
        XCTAssertEqual(BackgroundWorkScan.inFlight(of: TwoOwners()),
                       ["a thing is running"],
                       "the scan cannot see a busy owner, so nothing above this "
                       + "is a measurement of anything")
    }

    @MainActor
    func testTheScanIgnoresAnythingThatIsNotAnOwnerOfWork() {
        @MainActor struct Mixed {
            var busy = Busy(hasWorkInFlight: true, workPhrase: "a thing is running")
            var name = "not an owner at all"
            var count = 3
        }

        XCTAssertEqual(BackgroundWorkScan.inFlight(of: Mixed()), ["a thing is running"])
    }

    // MARK: - The wiring the test bundle cannot execute

    /// `PostRollApp.swift` is excluded from this bundle, correctly: a test
    /// bundle is loaded into a host that already has an entry point. So the one
    /// line that connects the owners to the delegate has no reviewer that RUNS
    /// it, and without that line every test above passes while the shipping app
    /// asks nothing before quitting, because an unwired delegate reports nothing
    /// in flight by design.
    ///
    /// Read from the file rather than asserted about behaviour, which is the
    /// most this can be. #842 is the standing reminder of what that costs, and
    /// the hand check is where the running app gets looked at.
    func testTheAppTellsTheDelegateWhatIsRunning() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PostRollApp.swift")
        let code = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(code.contains("deepLinks.workInFlight"),
                      "nothing hands the delegate the owners, so every quit "
                      + "reports nothing in flight and goes straight through, "
                      + "which is the defect #862 is about")
        XCTAssertTrue(code.contains("wireQuitGuard()"),
                      "the wiring exists but is never called, which is the same "
                      + "thing as not existing (L3)")
    }
}
