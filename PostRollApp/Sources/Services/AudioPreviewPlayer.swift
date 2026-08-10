import Foundation
import AVFoundation

/// Auditioning one audio file, with the button's state tracking what the player
/// is actually doing (#127).
///
/// The picker used to flip `isPlaying` by hand and set no delegate, so a track
/// that played to its end left the button showing Pause over a silent player.
/// The next click called `pause()` on something already stopped and flipped the
/// icon back, so hearing it again took two clicks: one that did nothing audible
/// and one that played. A control that lies about what it is doing is the thing
/// worth fixing here, not the extra click.
///
/// Owns its `AVAudioPlayer` outright. `AVAudioPlayer.delegate` is weak, so the
/// player cannot keep this object alive; this object keeping the player alive is
/// the direction that is safe, and is why the delegate is set here rather than
/// on a view that comes and goes (#196, #198).
@MainActor
final class AudioPreviewPlayer: NSObject, ObservableObject {

    /// What the player is doing, not what the last button press asked for.
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?

    /// The file currently loaded, or nil when nothing is.
    var loadedURL: URL? { player?.url }

    /// Start `url` if stopped, pause it if playing. Returns false when the file
    /// could not be opened, so a caller can say so rather than showing a
    /// control that silently does nothing.
    @discardableResult
    func toggle(url: URL) -> Bool {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return true
        }
        if player?.url != url {
            guard let fresh = try? AVAudioPlayer(contentsOf: url) else {
                stop()
                return false
            }
            fresh.delegate = self
            player = fresh
        }
        guard player?.play() == true else { return false }
        isPlaying = true
        return true
    }

    /// Stop and unload. Used when the file changes or the row goes away.
    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    /// The track reached its end on its own.
    ///
    /// Rewinds as well as clearing the flag: without it the next play resumes
    /// at the end and produces silence, which is the same complaint one step
    /// further along.
    fileprivate func finished() {
        player?.currentTime = 0
        isPlaying = false
    }
}

extension AudioPreviewPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }

    /// A decode failure ends playback just as surely as reaching the end, and
    /// leaving the button on Pause would be the same lie.
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finished() }
    }
}

#if POSTROLL_TESTS
extension AudioPreviewPlayer {
    /// Test seam: the delegate callback, without waiting on real playback.
    ///
    /// The real wiring is proved separately by playing a short file through to
    /// its end, because a seam that only ever calls itself proves nothing about
    /// whether AVAudioPlayer will call it.
    func simulateFinishedForTesting() { finished() }

    var currentTimeForTesting: TimeInterval? { player?.currentTime }
}
#endif
