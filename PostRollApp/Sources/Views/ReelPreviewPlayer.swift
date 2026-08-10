import SwiftUI
import AVKit

/// The inline video player for a rendered reel.
///
/// Lifetime, audited against #196 (#198): the AVPlayer is owned by the
/// AVPlayerView, which is owned by the container this returns, so nothing is
/// handed to an object that outlives the view. What WAS missing is the
/// teardown. `updateNSView` already pauses and clears the item before swapping
/// players, with a comment saying why: AVFoundation memory-maps the file, and a
/// player left holding the old asset can keep serving stale frames after Python
/// overwrites the MP4 in place. Unmounting took none of those steps, and this
/// view unmounts constantly, because switching event remounts the whole detail
/// pane. `dismantleNSView` now does the same teardown the update path does.
struct ReelPreviewPlayer: NSViewRepresentable {
    let url: URL
    var version: Int = 0
    var onRegenerate: (() -> Void)?
    var isRegenerating: Bool
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let playerView = AVPlayerView()
        playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        playerView.controlsStyle = .inline
        playerView.videoGravity = videoGravity
        playerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(playerView)
        context.coordinator.lastVersion = version
        context.coordinator.lastURL = url
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: container.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // Replace the AVPlayer when the URL changes OR the version bumps. Same
    // URL with new bytes (Python may overwrite the MP4 in place after a
    // regen) needs a fresh AVPlayer because AVFoundation caches by URL.
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let playerView = nsView.subviews.first as? AVPlayerView else { return }
        if context.coordinator.lastURL != url || context.coordinator.lastVersion != version {
            // Tear down the old player explicitly so the underlying AVAsset
            // is released before the new one memory-maps the (now overwritten)
            // file. Without this, AVFoundation can keep serving stale frames
            // even though we replaced the player object.
            Self.teardown(playerView)
            playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url)))
            context.coordinator.lastURL = url
            context.coordinator.lastVersion = version
        }
        playerView.videoGravity = videoGravity
    }

    /// The same teardown on the way out (#198).
    ///
    /// Without it, leaving the screen while a reel is playing left a player
    /// holding a memory-mapped asset for a file the next regeneration
    /// overwrites, which is exactly the condition `updateNSView` tears down to
    /// avoid. Static, because SwiftUI calls this after the value that made the
    /// view is gone.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        guard let playerView = nsView.subviews.first as? AVPlayerView else { return }
        teardown(playerView)
        playerView.player = nil
    }

    private static func teardown(_ playerView: AVPlayerView) {
        playerView.player?.pause()
        playerView.player?.replaceCurrentItem(with: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
        var lastVersion: Int = -1
    }
}
