import XCTest

/// #1143: that `Blocking.run` really leaves the cooperative pool.
///
/// The Python sweep beside this one
/// (`tests/test_blocking_work_stays_off_the_cooperative_pool.py`) checks that no
/// `Task.detached` reaches work which waits on something outside the process.
/// That is a check on the SPELLING. Reading `Blocking.run` at a call site proves
/// nothing about where the work lands (L3), and if the helper detached after all
/// then every site moved onto it would be exactly where it started while every
/// check stayed green.
///
/// ## Why this asks the QUEUE rather than filling the pool
///
/// The first version of this file saturated the cooperative pool and required
/// the work to finish anyway. It passed on a 12 core Mac and killed a worker on
/// the 3 core runner: 2,977 tests executed, exit 65, no test named, and this
/// class's own results absent from the log entirely.
///
/// That is the defect being tested, staged by the test itself. The pool is
/// shared by every other class in the process, so a fixture that fills it does
/// to the suite exactly what #1143 does to the app, and the failure presents as
/// everything else stopping rather than as this complaining (L241). A test that
/// has to break the runtime to show the runtime can break is not one a parallel
/// suite can hold.
///
/// libdispatch names the queue the current thread belongs to, and the
/// cooperative pool's name says so, so the same claim can be read directly and
/// instantly. The control below takes that reading from inside a `Task.detached`
/// in the same run, so a runtime that stops labelling them this way fails there
/// rather than turning this file green by accident (L159, L224).
final class BlockingWorkTests: XCTestCase {

    /// The queue the calling thread is running on, as libdispatch names it.
    nonisolated static func queueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    /// What the cooperative pool's own queues are called.
    private static let cooperative = "cooperative"

    func testTheReadingCanStillTellTheCooperativePoolApart() async {
        // The positive control, and this file is worthless without it. If the
        // runtime stopped naming cooperative queues this way, every assertion
        // below would pass by reading nothing, which is the same as not running
        // (L100, L98).
        let reading = Task.detached { BlockingWorkTests.queueLabel() }
        let onTheCooperativePool = await reading.value

        XCTAssertTrue(onTheCooperativePool.contains(Self.cooperative),
                      "a detached task is no longer on a queue whose name says "
                      + "cooperative (it says \(onTheCooperativePool)), so the "
                      + "readings below are not measuring what they claim")
    }

    func testBlockingWorkDoesNotRunOnTheCooperativePool() async {
        let label = await Blocking.run { Self.queueLabel() }

        XCTAssertFalse(label.contains(Self.cooperative),
                       "Blocking.run put the work on the cooperative pool "
                       + "(\(label)), which is sized to the cores and does not "
                       + "grow, so every site moved onto it is exactly where it "
                       + "started")
    }

    func testItRunsOnTheQualityOfServiceItWasAsked() async {
        // The qos is passed through rather than fixed, because a launch reading
        // the checkout is userInitiated and a background freshness check is not.
        // A helper that ignored it would flatten the two, and nothing at either
        // call site would say so.
        let label = await Blocking.run(qos: .userInitiated) { Self.queueLabel() }

        XCTAssertTrue(label.contains("user-initiated"),
                      "the requested quality of service did not reach the "
                      + "queue: \(label)")
    }

    func testItHandsBackWhatTheWorkReturned() async {
        let answer = await Blocking.run { "a value" }

        XCTAssertEqual(answer, "a value")
    }

    func testItRunsTheWorkExactlyOnce() async {
        // A continuation resumed twice traps, and one resumed never hangs. The
        // count is the cheap way to say which of the three happened.
        let counter = Counted()
        _ = await Blocking.run { counter.bump() }

        XCTAssertEqual(counter.count, 1)
    }

    private final class Counted: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = 0
        func bump() -> Int { lock.withLock { seen += 1; return seen } }
        var count: Int { lock.withLock { seen } }
    }
}
