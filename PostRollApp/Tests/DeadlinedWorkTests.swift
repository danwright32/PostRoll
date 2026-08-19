import XCTest

/// Running something with a deadline, in one place (#718).
///
/// A wait with no deadline cannot fail, it can only hang, and a hang is worse
/// than a failure because it is indistinguishable from slowness (L110). Two
/// managers had already written this, byte for byte the same, and the Insights
/// runs were about to make a third copy.
@MainActor
final class DeadlinedWorkTests: XCTestCase {

    func testWorkThatFinishesInTimeReturnsWhatItProduced() async throws {
        let value = try await DeadlinedWork.run(within: 5) { "done" }
        XCTAssertEqual(value, "done")
    }

    func testWorkThatOverrunsBecomesAnErrorRatherThanAWaitForever() async {
        do {
            _ = try await DeadlinedWork.run(within: 0.05) {
                try await Task.sleep(for: .seconds(30))
                return "never"
            }
            XCTFail("a run past its deadline returned instead of throwing, so a "
                    + "call that never comes back is indistinguishable from a "
                    + "slow one")
        } catch let stalled as DeadlinedWork.Stalled {
            // Asserted on the specific failure rather than on the mere fact of
            // an error: any throw at all would satisfy a bare catch, including
            // one raised by the work itself (L140).
            XCTAssertEqual(stalled.seconds, 0.05)
        } catch {
            XCTFail("threw \(error) rather than a stall")
        }
    }

    func testAnErrorFromTheWorkIsNotDisguisedAsAStall() async {
        // The two are different problems with different next steps, so they
        // must not arrive as one (L11). A helper that reported everything as a
        // stall would send Dan to wait it out when the run had already failed.
        struct Refused: Error {}
        do {
            _ = try await DeadlinedWork.run(within: 30) {
                throw Refused()
            } as Void
            XCTFail("the work's own error was swallowed")
        } catch is DeadlinedWork.Stalled {
            XCTFail("a real failure was reported as a stall")
        } catch is Refused {
            // Correct.
        } catch {
            XCTFail("threw \(error)")
        }
    }

    func testTheDeadlineTimerDoesNotOutliveWorkThatFinished() async throws {
        // The timer arm sleeps for the whole deadline. If it were left running
        // after the work returned, every finished run would hold a task for
        // minutes, and a test suite would take the sum of every deadline in it.
        let started = Date()
        _ = try await DeadlinedWork.run(within: 60) { "quick" }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the call did not return until its deadline elapsed, "
                          + "so the losing arm of the race is not being cancelled")
    }
}
