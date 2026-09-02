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

// MARK: - How fast it reads (#1066)

/// Dan, 2026-08-30, after confirming the 60fps work survives Instagram's
/// upload: "it looks good on instagram. in general I think it's too fast
/// though. Is there a warning we can put if it's running too fast?"
///
/// The quantity is computable before anything renders, from the strip's height
/// and the length he chose, so the answer arrives while the remedy is cheap.
extension ScrollReelTimingTests {

    private struct SpeedFixture: Decodable {
        struct Reel: Decodable {
            let name: String
            let photos: Int
            let strip_h: Double
        }
        struct Slider: Decodable {
            let min_s: Double
            let max_s: Double
            let step_s: Double
        }
        let fps: Double
        let viewport_h: Double
        let cruise_factor: Double
        let comfortable_travel_px: Double
        let slider: Slider
        let measured_reels: [Reel]
    }

    private func loadSpeedFixture() throws -> SpeedFixture {
        try JSONDecoder().decode(
            SpeedFixture.self,
            from: try RepoFixture.data("tests/fixtures/scroll_reel_timing.json"))
    }

    func testTheSpeedConstantsMatchTheRenderers() throws {
        let fixture = try loadSpeedFixture()
        XCTAssertEqual(ScrollReelTiming.fps, fixture.fps)
        XCTAssertEqual(ScrollReelTiming.viewportHeight, fixture.viewport_h)
        XCTAssertEqual(ScrollReelTiming.cruiseFactor, fixture.cruise_factor, accuracy: 1e-9)
        XCTAssertEqual(ScrollReelTiming.comfortableTravelPx,
                       fixture.comfortable_travel_px, accuracy: 1e-9)
    }

    /// The readings in #1066's own table, reproduced from the two reels on
    /// disk. If the editor's arithmetic drifts from the renderer's, these are
    /// what stop it agreeing with itself.
    func testTheMeasuredReelsReadAtTheSpeedsTheyWereMeasuredAt() throws {
        let fixture = try loadSpeedFixture()
        let expected: [String: [Double: Double]] = [
            "Battery Dance Festival": [35: 1.5, 60: 2.6],
            "DiGangi With A G": [35: 2.5, 60: 4.2],
        ]

        var checked = 0
        for reel in fixture.measured_reels {
            guard let wanted = expected[reel.name] else { continue }
            for (scrollSeconds, secondsPerScreen) in wanted {
                let read = ScrollReelTiming.secondsPerScreen(
                    stripHeight: reel.strip_h, scrollSeconds: scrollSeconds)
                XCTAssertEqual(read, secondsPerScreen, accuracy: 0.1,
                               "\(reel.name) at \(Int(scrollSeconds))s")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 4, "a renamed reel would skip these silently")
    }

    func testAComfortableReelIsNotWarnedAbout() throws {
        let fixture = try loadSpeedFixture()
        let digangi = try XCTUnwrap(fixture.measured_reels.first { $0.photos == 149 })

        // 100s puts it at 6.8px a frame, comfortably inside the threshold.
        XCTAssertNil(ScrollReelTiming.speedNotice(
            stripHeight: digangi.strip_h, photoCount: digangi.photos, scrollSeconds: 100))
    }

    /// A reel the slider CAN fix names the duration, with the number.
    ///
    /// The strip is CONSTRUCTED rather than taken from the two measured reels,
    /// because neither of them is this case: DiGangi needs 63 seconds and
    /// Battery Dance needs 100, so both are past the slider's maximum. That is
    /// the finding behind #1064, and it means this branch has no real reel to
    /// be exercised by. Derived from the contract so it lands where a 45 second
    /// answer is, rather than a height chosen until the test passed.
    func testAReelTheSliderCanFixIsToldWhichLengthToUse() throws {
        let fixture = try loadSpeedFixture()
        let target = 45.0
        let travel = target * fixture.fps * fixture.comfortable_travel_px
            / fixture.cruise_factor
        let stripHeight = travel + fixture.viewport_h

        let needed = ScrollReelTiming.comfortableScrollSeconds(stripHeight: stripHeight)
        XCTAssertEqual(needed, target, accuracy: 0.5, "the construction is wrong")
        XCTAssertLessThanOrEqual(needed, fixture.slider.max_s)

        let notice = try XCTUnwrap(ScrollReelTiming.speedNotice(
            stripHeight: stripHeight, photoCount: 120, scrollSeconds: 20))

        XCTAssertTrue(notice.contains("\(Int(needed.rounded()))"),
                      "the notice does not name the length that would fix it: \(notice)")
        XCTAssertFalse(notice.lowercased().contains("photograph"),
                       "a reel the slider can fix should not be told to lose photographs")
    }

    /// Both reels on disk need longer than the slider offers.
    ///
    /// Recorded as an assertion rather than left in prose, because it is the
    /// whole reason the notice has two shapes, and if a future change to the
    /// layout or the threshold makes the slider sufficient again, the branch
    /// that names the photo count becomes unreachable and should be revisited
    /// rather than left as dead code nobody notices.
    func testNeitherMeasuredReelCanBeFixedByTheSliderAlone() throws {
        let fixture = try loadSpeedFixture()
        XCTAssertFalse(fixture.measured_reels.isEmpty)
        for reel in fixture.measured_reels {
            let needed = ScrollReelTiming.comfortableScrollSeconds(stripHeight: reel.strip_h)
            XCTAssertGreaterThan(needed, fixture.slider.max_s,
                                 "\(reel.name) now fits inside the slider's range")
        }
    }

    /// And one it CANNOT names the photo count instead, because a message that
    /// points only at a control unable to solve the problem is a dead end
    /// (L80, L111). At 234 photographs the slider's maximum still leaves the
    /// reel faster than the one Dan had already called too fast.
    func testAReelTheSliderCannotFixNamesThePhotoCount() throws {
        let fixture = try loadSpeedFixture()
        let battery = try XCTUnwrap(fixture.measured_reels.first { $0.photos == 234 })

        let notice = try XCTUnwrap(ScrollReelTiming.speedNotice(
            stripHeight: battery.strip_h, photoCount: battery.photos, scrollSeconds: 35))

        let fewer = ScrollReelTiming.comfortablePhotoCount(
            stripHeight: battery.strip_h, photoCount: battery.photos,
            scrollSeconds: fixture.slider.max_s)
        XCTAssertLessThan(fewer, battery.photos, "fewer photographs means fewer")
        XCTAssertGreaterThan(fewer, 0)
        XCTAssertTrue(notice.contains("\(fewer)"),
                      "the notice does not name how many photographs would fit: \(notice)")
        XCTAssertTrue(notice.lowercased().contains("photograph"), notice)
    }

    /// A strip that fits the viewport does not scroll at all, so there is no
    /// speed to be uncomfortable about and no division to do.
    func testAStripThatDoesNotScrollIsNotWarnedAbout() throws {
        let fixture = try loadSpeedFixture()
        XCTAssertNil(ScrollReelTiming.speedNotice(
            stripHeight: fixture.viewport_h - 1, photoCount: 4, scrollSeconds: 15))
        XCTAssertEqual(ScrollReelTiming.travelPerFrame(
            stripHeight: fixture.viewport_h - 1, scrollSeconds: 15), 0)
    }

    /// Nothing here may divide by zero or answer about a reel with no photos.
    func testDegenerateInputsSayNothingRatherThanCrashing() throws {
        XCTAssertNil(ScrollReelTiming.speedNotice(
            stripHeight: 29000, photoCount: 0, scrollSeconds: 35))
        XCTAssertNil(ScrollReelTiming.speedNotice(
            stripHeight: 29000, photoCount: 234, scrollSeconds: 0))
        XCTAssertNil(ScrollReelTiming.speedNotice(
            stripHeight: 0, photoCount: 234, scrollSeconds: 35))
    }
}
