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
@MainActor
final class AudioPreviewPlayerTests: XCTestCase {

    /// A valid PCM WAV of `seconds` of silence, 8 kHz mono 16-bit.
    private func writeSilentWAV(seconds: Double, to url: URL) throws {
        let rate = 8000
        let frames = max(1, Int(Double(rate) * seconds))
        let dataBytes = frames * 2

        var wav = Data()
        func append(_ s: String) { wav.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }

        append("RIFF");  append32(UInt32(36 + dataBytes)); append("WAVE")
        append("fmt ");  append32(16)
        append16(1)                       // PCM
        append16(1)                       // mono
        append32(UInt32(rate))
        append32(UInt32(rate * 2))        // byte rate
        append16(2)                       // block align
        append16(16)                      // bits per sample
        append("data"); append32(UInt32(dataBytes))
        wav.append(Data(count: dataBytes))

        try wav.write(to: url)
    }

    private func makeTrack(seconds: Double = 0.6) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPreviewPlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("track.wav")
        try writeSilentWAV(seconds: seconds, to: url)
        return url
    }

    // ── the reported defect ───────────────────────────────────────────────────

    func testTheButtonReturnsToPlayWhenTheTrackEnds() throws {
        let player = AudioPreviewPlayer()
        let url = try makeTrack()

        XCTAssertTrue(player.toggle(url: url))
        XCTAssertTrue(player.isPlaying)

        player.simulateFinishedForTesting()

        XCTAssertFalse(player.isPlaying,
                       "the control showed Pause over a player that had stopped")
    }

    func testOneClickReplaysFromTheStartAfterATrackEnds() throws {
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
        let player = AudioPreviewPlayer()
        let url = try makeTrack()

        player.toggle(url: url)
        player.toggle(url: url)

        XCTAssertFalse(player.isPlaying)
    }

    func testStopUnloadsTheFile() throws {
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
