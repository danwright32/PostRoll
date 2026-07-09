import XCTest

/// ClipCropFrameStrip.sampleTimes picks which points across a clip's trim
/// window the per-clip crop editor (#151) pulls preview frames from, so a
/// crop that drifts off-subject partway through a shot is visible before
/// it ships. Mirrors select_reel_clips.py's start/mid/end spread.
final class ClipCropFrameStripTests: XCTestCase {

    func testSpansStartMiddleAndEndOfTheTrimWindow() {
        let times = ClipCropFrameStrip.sampleTimes(trimIn: 2.0, trimOut: 6.0)
        XCTAssertEqual(times, [2.0, 4.0, 6.0])
    }

    func testZeroWidthWindowFallsBackToASingleTime() {
        // Shouldn't happen given upstream clamping, but must not divide by
        // zero or produce a bogus negative-width spread.
        let times = ClipCropFrameStrip.sampleTimes(trimIn: 3.0, trimOut: 3.0)
        XCTAssertEqual(times, [3.0])
    }

    func testInvertedWindowFallsBackToASingleTime() {
        let times = ClipCropFrameStrip.sampleTimes(trimIn: 5.0, trimOut: 1.0)
        XCTAssertEqual(times, [5.0])
    }
}
