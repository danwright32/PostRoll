import XCTest
import AVFoundation

/// #127: the audio button says what the player is doing.
///
/// The Thursday picker flipped `isPlaying` by hand and set no delegate, so a
/// track played to its end left the button showing Pause over a silent player.
/// The next click paused something already stopped and flipped the icon back,
/// so hearing it again took two clicks: one silent, one that worked.
///
/// The files here are real WAVs written to disk and played by a real
/// AVAudioPlayer. A mocked player would only prove the mock agrees with itself,
/// and the whole defect was a real player's behaviour going unobserved.
///
/// #310: that also means these tests need the machine to play sound, and on a
/// machine that will not, they went red naming nothing about the real cause and
/// blocked `build-install.sh` from installing. Every test below that depends on
/// playback having STARTED asks `AudioPlaybackAvailability` first, so a refusing
/// device produces a skip that says so instead of a failure that reads as a
/// broken delegate. The one test that needs no playback at all (a file that
/// cannot be opened) keeps running either way.
@MainActor
final class AudioPreviewPlayerTests: XCTestCase {

    /// Skips this test, naming why, when this machine will not play audio.
    private func requirePlayback() throws {
        try AudioPlaybackAvailability.thisMachine.requirePlayback()
    }

    private func makeTrack(seconds: Double = 0.6) throws -> URL {
        try SilentWAV.write(seconds: seconds)
    }

    // ── the reported defect ───────────────────────────────────────────────────

    func testTheButtonReturnsToPlayWhenTheTrackEnds() throws {
        try requirePlayback()
        let player = AudioPreviewPlayer()
        let url = try makeTrack()

        XCTAssertTrue(player.toggle(url: url))
        XCTAssertTrue(player.isPlaying)

        player.simulateFinishedForTesting()

        XCTAssertFalse(player.isPlaying,
                       "the control showed Pause over a player that had stopped")
    }

    func testOneClickReplaysFromTheStartAfterATrackEnds() throws {
        try requirePlayback()
        // The visible cost of the old behaviour: the first click after a track
        // finished was swallowed pausing an already-stopped player.
        let player = AudioPreviewPlayer()
        let url = try makeTrack()

        player.toggle(url: url)
        player.simulateFinishedForTesting()

        XCTAssertTrue(player.toggle(url: url))
        XCTAssertTrue(player.isPlaying, "the first click after the end must play")
    }

    func testItRewindsSoTheNextPlayIsNotSilence() throws {
        try requirePlayback()
        let player = AudioPreviewPlayer()
        let url = try makeTrack()

        player.toggle(url: url)
        player.simulateFinishedForTesting()

        XCTAssertEqual(player.currentTimeForTesting ?? -1, 0, accuracy: 0.001,
                       "resuming at the end plays nothing, which is the same "
                       + "complaint one step further along")
    }

    // ── the delegate is actually wired ────────────────────────────────────────

    func testARealPlaythroughResetsTheButtonWithoutTheTestSeam() throws {
        try requirePlayback()
        // The seam above is convenient and proves nothing about whether
        // AVAudioPlayer will ever call us. This plays a short file all the way
        // through and waits for the real callback (L3: wired is not proven).
        let player = AudioPreviewPlayer()
        let url = try makeTrack(seconds: 0.15)

        XCTAssertTrue(player.toggle(url: url))

        let stopped = expectation(description: "the player reports it finished")
        Task { @MainActor in
            for _ in 0..<100 {
                if !player.isPlaying { stopped.fulfill(); return }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        wait(for: [stopped], timeout: 5)
    }

    // ── ordinary controls ─────────────────────────────────────────────────────

    func testTogglingWhilePlayingPauses() throws {
        try requirePlayback()
        let player = AudioPreviewPlayer()
        let url = try makeTrack()

        player.toggle(url: url)
        player.toggle(url: url)

        XCTAssertFalse(player.isPlaying)
    }

    func testStopUnloadsTheFile() throws {
        try requirePlayback()
        let player = AudioPreviewPlayer()
        let url = try makeTrack()

        player.toggle(url: url)
        player.stop()

        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.loadedURL)
    }

    func testAFileThatCannotBeOpenedSaysSoRatherThanShowingPause() throws {
        let player = AudioPreviewPlayer()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPreviewPlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notAudio = dir.appendingPathComponent("track.wav")
        try Data("this is not audio".utf8).write(to: notAudio)

        XCTAssertFalse(player.toggle(url: notAudio))
        XCTAssertFalse(player.isPlaying,
                       "a control that shows Pause over a file it could not "
                       + "open is the same lie in a different shape")
    }

    func testSwitchingFilesLoadsTheNewOne() throws {
        try requirePlayback()
        let player = AudioPreviewPlayer()
        let first = try makeTrack()
        let second = try makeTrack()

        player.toggle(url: first)
        player.toggle(url: first)          // pause, so the next toggle starts
        player.toggle(url: second)

        XCTAssertEqual(player.loadedURL?.lastPathComponent, second.lastPathComponent)
        XCTAssertEqual(player.loadedURL?.deletingLastPathComponent().lastPathComponent,
                       second.deletingLastPathComponent().lastPathComponent)
    }
}
