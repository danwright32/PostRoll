import XCTest

/// #91 / #197: every keystroke in a caption, blog body or notes field wrote the
/// ENTIRE events store to disk. The cost scaled with how many events Dan has
/// rather than with the size of the edit, and a crash landing mid write is
/// exactly the situation that leaves the store unreadable. It was found while
/// diagnosing #196, where the app really did die during an active edit.
///
/// The thing that must not regress while fixing it: a debounce that drops the
/// last edit is worse than the problem. Every path that ends an editing session
/// has to flush, and the in-memory events must stay current at all times so no
/// reader sees stale text just because the disk write is still pending.
final class DebouncedStoreWriterTests: XCTestCase {

    /// Collects writes from whatever thread they land on.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [[String]] = []
        var writes: [[String]] { lock.lock(); defer { lock.unlock() }; return _writes }
        func record(_ v: [String]) { lock.lock(); _writes.append(v); lock.unlock() }
    }

    private func writer(interval: TimeInterval = 0.05,
                        into sink: Sink) -> DebouncedStoreWriter<[String]> {
        DebouncedStoreWriter(interval: interval) { sink.record($0) }
    }

    func testABurstOfEditsCollapsesToOneWrite() {
        let sink = Sink()
        let w = writer(into: sink)

        for i in 1...50 { w.schedule(["draft \(i)"]) }
        XCTAssertTrue(sink.writes.isEmpty, "nothing should have hit the disk yet")

        w.flush()
        XCTAssertEqual(sink.writes.count, 1, "50 keystrokes must not be 50 full store writes")
    }

    func testTheWriteCarriesTheLastEditNotTheFirst() {
        let sink = Sink()
        let w = writer(into: sink)

        w.schedule(["first"])
        w.schedule(["second"])
        w.schedule(["last"])
        w.flush()

        XCTAssertEqual(sink.writes.last, ["last"])
    }

    func testFlushingWithNothingPendingWritesNothing() {
        let sink = Sink()
        let w = writer(into: sink)

        w.flush()
        w.flush()

        XCTAssertTrue(sink.writes.isEmpty, "an idle flush must not rewrite the store")
    }

    func testASecondFlushDoesNotRepeatTheSameWrite() {
        let sink = Sink()
        let w = writer(into: sink)

        w.schedule(["a"])
        w.flush()
        w.flush()

        XCTAssertEqual(sink.writes.count, 1)
    }

    func testThePendingEditIsWrittenWhenTypingStops() {
        // The ordinary case: Dan stops typing and the save lands on its own,
        // with nobody having to call flush.
        let sink = Sink()
        let w = writer(interval: 0.05, into: sink)
        let landed = expectation(description: "the pause triggers the write")

        w.schedule(["typed then paused"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if sink.writes == [["typed then paused"]] { landed.fulfill() }
        }

        wait(for: [landed], timeout: 3)
    }

    func testAnEditSchedulledAfterAFlushStillLands() {
        // Flush must not leave the writer dead: editing continues afterwards.
        let sink = Sink()
        let w = writer(into: sink)

        w.schedule(["before"])
        w.flush()
        w.schedule(["after"])
        w.flush()

        XCTAssertEqual(sink.writes, [["before"], ["after"]])
    }

    func testTheLastEditIsNotLostWhenTheWriterGoesAway() {
        // The review screen remounts whenever Dan switches events, so a pending
        // write has to survive teardown or the edit he just made is gone.
        let sink = Sink()
        do {
            let w = writer(interval: 60, into: sink)
            w.schedule(["unsaved when the screen went away"])
        }
        XCTAssertEqual(sink.writes, [["unsaved when the screen went away"]],
                       "a pending edit must be written on teardown, not dropped")
    }
}
