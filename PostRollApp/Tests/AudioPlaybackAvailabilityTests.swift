import XCTest

/// #310: telling "the delegate is not wired" apart from "this machine will not
/// play audio".
///
/// `AudioPreviewPlayerTests` asserts that real playback started, on purpose: the
/// defect it guards was a real player's behaviour going unobserved, and a mock
/// would only agree with itself. But that makes the install gate depend on the
/// machine being able to play sound at that moment, and when it cannot, five
/// tests go red naming nothing about the real cause while `build-install.sh`
/// refuses to put the build in /Applications.
///
/// These pin the three verdicts apart, because a skip is normally worse than a
/// failure and is only defensible when it names exactly why it skipped.
final class AudioPlaybackAvailabilityTests: XCTestCase {

    // ── the device refuses: skip, loudly and by name ──────────────────────────

    func testARefusingDeviceProducesASkipReasonNamingTheDevice() {
        let availability = AudioPlaybackAvailability(probe: { .deviceRefusedPlayback })

        let reason = availability.skipReason
        XCTAssertNotNil(reason, "a machine that will not play audio must skip, not fail")
        XCTAssertTrue(reason?.contains("audio device refused playback") == true,
                      "the skip has to name the cause, or it is a quiet pass in "
                      + "disguise: got \(reason ?? "nil")")
    }

    func testARefusingDeviceThrowsAnXCTSkip() {
        let availability = AudioPlaybackAvailability(probe: { .deviceRefusedPlayback })

        XCTAssertThrowsError(try availability.requirePlayback()) { error in
            XCTAssertTrue(error is XCTSkip,
                          "the playback-dependent tests must be SKIPPED, not passed and "
                          + "not failed, when the machine cannot play: got \(type(of: error))")
        }
    }

    // ── the device plays: run the real tests ──────────────────────────────────

    func testAWorkingDeviceDoesNotSkipAnything() throws {
        let availability = AudioPlaybackAvailability(probe: { .playbackStarted })

        XCTAssertNil(availability.skipReason)
        XCTAssertNoThrow(try availability.requirePlayback(),
                         "playback works here, so the tests that prove the delegate is "
                         + "wired must actually run")
    }

    // ── the probe itself is broken: say nothing, let the tests speak ──────────

    func testAProbeThatCouldNotRunDoesNotSkipTheTests() throws {
        // If the probe cannot even write its own file or open its own player,
        // it has measured nothing about this machine's audio. Skipping on that
        // would hide real failures behind a sentence that is not true, so the
        // playback tests are allowed to run and fail in their own words.
        let availability = AudioPlaybackAvailability(
            probe: { .probeUnusable("could not write the probe file") })

        XCTAssertNil(availability.skipReason,
                     "a probe that failed for its own reasons has not shown that the "
                     + "audio device refused anything")
        XCTAssertNoThrow(try availability.requirePlayback())
    }

    // ── the probe is asked once, not once per test ────────────────────────────

    func testTheDeviceIsAskedOnlyOnce() {
        // Each refused `play()` takes about fifteen seconds to give up on this
        // Mac, which is what turned a seconds-long suite into nearly three
        // minutes. One probe, reused.
        var asks = 0
        let availability = AudioPlaybackAvailability(probe: {
            asks += 1
            return .deviceRefusedPlayback
        })

        _ = availability.skipReason
        _ = availability.skipReason
        try? availability.requirePlayback()

        XCTAssertEqual(asks, 1, "the probe must be memoised, or every call pays the "
                       + "device's full timeout again")
    }

    // ── the live probe really plays a file ────────────────────────────────────

    func testTheLiveProbePlaysARealFileRatherThanAssuming() throws {
        // L1: a guard is only real once it has been seen to do its own work.
        // The verdicts above are injected; this one asks the actual machine,
        // and asserts only that it reached a verdict about the device rather
        // than falling over on its own setup.
        let verdict = AudioPlaybackAvailability.probeThisMachine()

        if case .probeUnusable(let why) = verdict {
            XCTFail("the probe could not test this machine at all: \(why). That is a "
                    + "broken probe, not a refusing audio device.")
        }
    }

    func testTheSharedAnswerComesFromTheLiveProbeRatherThanAConstant() {
        // L70: the gate the player tests consult is `thisMachine`, and a
        // hardcoded verdict there would make every test above pass while the
        // gate protected nothing. Asked twice by independent routes.
        XCTAssertEqual(AudioPlaybackAvailability.thisMachine.verdict,
                       AudioPlaybackAvailability.probeThisMachine(),
                       "the shared answer must be what asking this machine "
                       + "actually produces, not a constant")
    }
}
