import Foundation
import AVFoundation
import XCTest

/// A valid PCM WAV of silence, 8 kHz mono 16-bit.
///
/// One writer, used by both the playback probe and the player tests. Two copies
/// of a hand-built file header drift, and a probe built from a different file to
/// the tests it gates would be measuring something the tests never play.
enum SilentWAV {

    static func data(seconds: Double) -> Data {
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
        return wav
    }

    /// Writes one into a directory of its own and returns the file.
    static func write(seconds: Double, named name: String = "track.wav") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SilentWAV-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data(seconds: seconds).write(to: url)
        return url
    }
}

/// What asking this machine to play a file actually produced (#310).
///
/// Three outcomes, not two, because "the probe could not run" is a different
/// fact from "the device refused" and must not be reported as it.
enum AudioPlaybackVerdict: Equatable, Sendable {
    /// `play()` returned true: the tests that prove the delegate is wired can run.
    case playbackStarted
    /// A valid file opened fine and `play()` still returned false.
    case deviceRefusedPlayback
    /// The probe fell over on its own setup, so it measured nothing about audio.
    case probeUnusable(String)
}

/// Whether this machine will start audio playback at all (#310).
///
/// `AudioPreviewPlayerTests` asserts real playback started, deliberately: the
/// defect it guards was a real `AVAudioPlayer`'s behaviour going unobserved, and
/// a mocked player would only prove the mock agrees with itself. The cost is
/// that when the machine will not play sound, those tests go red saying nothing
/// about why, and `build-install.sh` refuses to install the build, so the
/// workaround becomes `SKIP_INSTALL_TESTS=1`, which turns off the gate keeping a
/// red build out of /Applications.
///
/// On this Mac, on 2026-08-11, `AVAudioPlayer.play()` returned false for any
/// process launched from the terminal, on a valid file, with the built-in
/// speakers present and selected, taking about fifteen seconds to give up each
/// time. The same tests passed on CI. By the time this was written the machine
/// had recovered on its own, which is exactly why the tests must be able to say
/// which of the two things happened rather than depending on it never recurring.
///
/// A skip is normally worse than a failure, so this one only ever fires on the
/// verdict that proves the device refused, and names that reason in the skip.
struct AudioPlaybackAvailability: Sendable {

    let verdict: AudioPlaybackVerdict

    /// Asks once, at construction. Every later question reuses the answer,
    /// because a refused `play()` costs the device's full timeout each time.
    init(probe: () -> AudioPlaybackVerdict) {
        verdict = probe()
    }

    /// The shared answer for this test process: one probe, however many tests.
    static let thisMachine = AudioPlaybackAvailability(probe: probeThisMachine)

    /// Why the playback-dependent tests cannot run here, or nil when they can.
    var skipReason: String? {
        guard verdict == .deviceRefusedPlayback else { return nil }
        return "this machine's audio device refused playback, so the delegate "
             + "could not be exercised. This is the machine, not the code: a "
             + "valid file opened and AVAudioPlayer.play() still returned false. "
             + "The same tests pass where audio works, including CI."
    }

    /// Skips the calling test when, and only when, the device refused.
    func requirePlayback(file: StaticString = #filePath, line: UInt = #line) throws {
        if let reason = skipReason {
            throw XCTSkip(reason, file: file, line: line)
        }
    }

    /// Plays a real short file and reports what happened.
    ///
    /// Not a query of the device list or a capability flag: the failure being
    /// detected is `play()` returning false while every such flag says the
    /// speakers are right there, so the only honest probe is the same call the
    /// tests make.
    static func probeThisMachine() -> AudioPlaybackVerdict {
        let url: URL
        do {
            url = try SilentWAV.write(seconds: 0.25, named: "playback-probe.wav")
        } catch {
            return .probeUnusable("could not write the probe file: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            // A WAV written a line ago that will not open is a broken probe,
            // not a refusing device.
            return .probeUnusable("could not open the probe file: \(error.localizedDescription)")
        }

        guard player.play() else { return .deviceRefusedPlayback }
        player.stop()
        return .playbackStarted
    }
}
