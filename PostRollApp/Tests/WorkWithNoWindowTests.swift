import XCTest

/// Work that carries on with no window says so (#863).
///
/// Before #847, closing the PostRoll window quit the app, so it was impossible
/// to have work running with nothing on screen. That behaviour was wrong for
/// other reasons and is gone. The state it created: Dan starts a generation,
/// closes the window, and PostRoll goes on working with no window, no progress
/// and nothing saying so. The work is not lost, which is the important part, but
/// there is no way to tell it is happening except by reopening the window.
///
/// Two halves, and the second was found while building the first.
///
/// Nothing showed work was RUNNING. The Dock badge that exists counts work that
/// has FINISHED and not been looked at, which is a different thing.
///
/// And nothing at all said work had FAILED. Every manager's failure path goes
/// through `markFailed` and none of them notified, deliberately: a failed run is
/// not a completion and the completion notifications were the only ones there
/// were. So a generation that died with the window closed was indistinguishable
/// from one still running, and from one that finished. That is the standing rule
/// about working, still alive and failed being visibly distinct, applied to a
/// surface that did not exist until the window could be closed.
final class WorkWithNoWindowTests: XCTestCase {

    private final class Owner {}

    // MARK: - Is anything running

    func testNothingRunningIsIdle() {
        XCTAssertEqual(WorkActivity().state, .idle)
    }

    func testAnOwnerThatStartsIsWorking() {
        var activity = WorkActivity()
        let owner = Owner()

        activity.report(owner, runningFor: 0)

        XCTAssertEqual(activity.state, .working(seconds: 0),
                       "a run started and the Dock has nothing to show for it")
    }

    func testTheDockShowsTheLongestRunOfSeveral() {
        // The still alive signal has to come from the run that has been going
        // longest, or a short job starting beside a long one resets the clock
        // and the display looks like it keeps starting over.
        var activity = WorkActivity()
        let slow = Owner(), quick = Owner()

        activity.report(slow, runningFor: 240)
        activity.report(quick, runningFor: 2)

        XCTAssertEqual(activity.state, .working(seconds: 240))
    }

    func testOneOwnerStoppingLeavesTheOthersRunning() {
        // The defect this shape exists to prevent: a shared counter that any
        // finishing job can drive to zero, clearing the Dock while a generation
        // is still going.
        var activity = WorkActivity()
        let slow = Owner(), quick = Owner()
        activity.report(slow, runningFor: 240)
        activity.report(quick, runningFor: 2)

        activity.report(quick, runningFor: nil)

        XCTAssertEqual(activity.state, .working(seconds: 240),
                       "one job finishing cleared the Dock while another was "
                       + "still running")
    }

    func testEverythingStoppingGoesBackToIdle() {
        var activity = WorkActivity()
        let owner = Owner()
        activity.report(owner, runningFor: 30)

        activity.report(owner, runningFor: nil)

        XCTAssertEqual(activity.state, .idle,
                       "the Dock still says PostRoll is working after "
                       + "everything finished, so the signal means nothing")
    }

    func testAnOwnerThatWentAwayDoesNotHoldTheDockOpenForever() {
        // Keyed on identity, and the owners are long lived, but a tracker that
        // is released mid run would otherwise leave the Dock saying PostRoll is
        // working for the rest of the session with nothing able to clear it.
        var activity = WorkActivity()
        do {
            let temporary = Owner()
            activity.report(temporary, runningFor: 5)
        }

        activity.forgetOwnersThatWentAway()

        XCTAssertEqual(activity.state, .idle,
                       "a released owner is still counted as running")
    }

    // MARK: - A failure is not silence

    func testAFailedRunIsAnnounced() {
        // The reason this is a test and not a comment: the whole of the app's
        // notifying was completions, and `finishFailure` said nothing on
        // purpose. With the window closed that made a dead run and a running
        // one produce exactly the same evidence, which is none (L11).
        let announcement = WorkOutcome.failed(work: "generating Thursday",
                                              eventName: "Winter Gala",
                                              reason: "the Python bridge exited 1")

        XCTAssertTrue(announcement.title.contains("Winter Gala"),
                      "the failure does not say which event it was about: \(announcement.title)")
        XCTAssertTrue(announcement.body.contains("the Python bridge exited 1"),
                      "the failure does not say what went wrong, so there is "
                      + "nothing to act on: \(announcement.body)")
    }

    func testAFailureReadsDifferentlyFromACompletion() {
        // Both arrive as a banner in the same place. If they read alike, the one
        // that needs doing something about is the one that gets waved away with
        // the six that do not (L11).
        let failed = WorkOutcome.failed(work: "generating Thursday",
                                        eventName: "Winter Gala",
                                        reason: "the Python bridge exited 1")

        XCTAssertNotEqual(failed.title, "Winter Gala: Captions Ready")
        XCTAssertTrue(failed.title.lowercased().contains("fail")
                      || failed.title.lowercased().contains("stopped"),
                      "a failed run's banner does not say it failed: \(failed.title)")
    }

    func testAFailureWithNoReasonStillSaysWhereToLook() {
        // Not every failure path has a sentence to offer. Saying nothing at all
        // in that case would be the same silence one level down.
        let announcement = WorkOutcome.failed(work: "generating Thursday",
                                              eventName: "Winter Gala",
                                              reason: nil)

        XCTAssertFalse(announcement.body.trimmingCharacters(in: .whitespaces).isEmpty,
                       "a failure with no reason produced an empty banner")
    }

    // MARK: - No manager gets to fail quietly

    /// Every place a run is marked failed says so out loud.
    ///
    /// The reason this is a sweep rather than five tests. Announcing a failure
    /// is a thing each manager does in its own failure path, which is exactly
    /// the shape of a list kept by hand: a sixth manager added later is silent,
    /// nothing fails, and the gap is invisible because the other five still
    /// announce (L96). The sweep is over what is REACHABLE in Sources, so
    /// adding a failure path enrols it.
    ///
    /// It checks proximity rather than order or exact form, because the point is
    /// that the two live together, not that they are written a particular way.
    func testEveryFailurePathAnnouncesItself() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")

        guard let walk = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return XCTFail("could not read \(sources)")
        }

        var checked = 0
        var silent: [String] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            // JobTracker DEFINES markFailed; it does not call it about any
            // particular piece of work and has no event name to announce.
            guard url.lastPathComponent != "JobTracker.swift" else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")

            for (index, line) in lines.enumerated() where line.contains(".markFailed(") {
                checked += 1
                let window = lines[index..<min(index + 9, lines.count)].joined(separator: "\n")
                if !window.contains("notifyWorkFailed(") {
                    silent.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }

        XCTAssertGreaterThanOrEqual(checked, 5,
                                    "the sweep found \(checked) failure paths and "
                                    + "there have been five since #718, so it is "
                                    + "reading the wrong thing rather than the app "
                                    + "having fewer")
        XCTAssertTrue(silent.isEmpty,
                      "these runs are marked failed and say nothing, so with the "
                      + "window closed a dead run is indistinguishable from one "
                      + "still going: \(silent)")
    }
}
