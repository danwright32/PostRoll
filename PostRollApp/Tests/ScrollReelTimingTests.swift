import XCTest

/// #1076: the editor answers "will this track cover the reel" from the same
/// numbers the renderer uses.
///
/// `fit_audio_to_duration` loops a short track with crossfaded seams and used
/// to say nothing, so a reel whose music repeats was indistinguishable from one
/// whose track fits. The pipeline reports it now, but only after a render;
/// this is the half that answers before Dan waits for one.
final class ScrollReelTimingTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Slider: Decodable {
            let min_s: Double
            let max_s: Double
            let step_s: Double
        }
        let hold_end_s: Double
        let closing_frame_s: Double
        let slider: Slider
        let reel_seconds_for_scroll: [String: Double]
    }

    private func loadFixture() throws -> Fixture {
        try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/scroll_reel_timing.json"))
    }

    func testTheHoldsMatchTheOnesTheRendererUses() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(ScrollReelTiming.holdEndSeconds, fixture.hold_end_s)
        XCTAssertEqual(ScrollReelTiming.closingFrameSeconds, fixture.closing_frame_s)
    }

    /// The trap this exists for. A reel is the scroll PLUS the holds, so a
    /// track that comfortably covers the slider value can still be six seconds
    /// short of the reel, and a notice computed against the slider alone would
    /// say nothing on exactly the reels that loop.
    func testEveryLengthTheSliderOffersMatchesTheRecordedReelLength() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.reel_seconds_for_scroll.count, 5,
                                    "an empty contract would pass vacuously")

        for (scrollText, reelSeconds) in fixture.reel_seconds_for_scroll {
            let scrollSeconds = Double(scrollText)!
            XCTAssertEqual(ScrollReelTiming.reelSeconds(scrollSeconds: scrollSeconds),
                           reelSeconds, accuracy: 0.001,
                           "a \(scrollText)s scroll")
            XCTAssertGreaterThan(reelSeconds, scrollSeconds,
                                 "the holds have stopped counting")
        }
    }

    func testATrackShorterThanTheReelSaysSoWithBothLengths() throws {
        let fixture = try loadFixture()
        let scrollSeconds = fixture.slider.min_s
        let reelSeconds = ScrollReelTiming.reelSeconds(scrollSeconds: scrollSeconds)

        let notice = ScrollReelTiming.musicNotice(trackSeconds: reelSeconds - 8,
                                                  scrollSeconds: scrollSeconds)

        let text = try XCTUnwrap(notice, "a track 8s short of the reel said nothing")
        // Both numbers, because a sentence saying only that something will
        // happen sends Dan to measure the track himself, which is the step
        // this exists to remove.
        XCTAssertTrue(text.contains("\(Int(reelSeconds - 8))"), text)
        XCTAssertTrue(text.contains("\(Int(reelSeconds))"), text)
        XCTAssertTrue(text.lowercased().contains("repeat"), text)
    }

    /// The case the holds create, and the reason the notice cannot be computed
    /// against the slider value: a track that covers the SCROLL and not the
    /// REEL is the one a person is most likely to think is fine.
    func testATrackThatCoversTheScrollButNotTheReelStillSaysSo() throws {
        let fixture = try loadFixture()
        let scrollSeconds = fixture.slider.min_s

        let notice = ScrollReelTiming.musicNotice(trackSeconds: scrollSeconds + 1,
                                                  scrollSeconds: scrollSeconds)

        XCTAssertNotNil(notice,
                        "a track longer than the scroll but shorter than the reel said nothing")
    }

    func testATrackThatCoversTheReelSaysNothing() throws {
        let fixture = try loadFixture()
        let scrollSeconds = fixture.slider.max_s
        let reelSeconds = ScrollReelTiming.reelSeconds(scrollSeconds: scrollSeconds)

        XCTAssertNil(ScrollReelTiming.musicNotice(trackSeconds: reelSeconds,
                                                  scrollSeconds: scrollSeconds),
                     "a track exactly as long as the reel does not repeat")
        XCTAssertNil(ScrollReelTiming.musicNotice(trackSeconds: reelSeconds + 30,
                                                  scrollSeconds: scrollSeconds))
    }

    /// An unknown length is not a short one. Jamendo fetches the track during
    /// the run, so before a render there is often nothing to measure, and
    /// warning then would fire on every reel that has not chosen its music yet.
    func testAnUnknownTrackLengthSaysNothing() throws {
        let fixture = try loadFixture()
        XCTAssertNil(ScrollReelTiming.musicNotice(trackSeconds: nil,
                                                  scrollSeconds: fixture.slider.min_s))
    }
}
