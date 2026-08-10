import XCTest
import AVKit
import SwiftUI

/// #198: the other AppKit wrappers, audited for the lifetime mistake behind
/// #196.
///
/// #196 was `SpellCheckingTextEditor` handing undo operations to the WINDOW's
/// undo manager, which holds unowned references and outlives the text view, so
/// a destroyed editor left live entries pointing at freed memory. Holding
/// Cmd+Z walked into one and killed the app. Fixing only that instance leaves
/// siblings of the same defect in place, so this covers the whole family.
///
/// What the audit found, wrapper by wrapper:
///
/// * `SpellCheckingTextEditor` was the reported one, fixed by owning its own
///   `UndoManager` on the coordinator rather than borrowing the window's.
/// * `ReelPreviewPlayer` had no dangling reference (the AVPlayer is owned by
///   the AVPlayerView it lives in) but had no teardown either. `updateNSView`
///   already pauses and clears the item before swapping players, because
///   AVFoundation memory-maps the file and a player still holding the old
///   asset can serve stale frames after Python overwrites the MP4 in place.
///   Unmounting did none of that, and this view unmounts constantly, because
///   switching event remounts the whole detail pane.
/// * `WindowConfigurator` hands nothing to anything: it mutates the shared
///   window (appearance, background, minimum size) and never undoes it, which
///   is correct, because that window is the app's only window and dies with
///   the app. Its async block captures the view rather than the reverse, so
///   there is nothing to dangle.
final class AppKitWrapperLifetimeTests: XCTestCase {

    // ── ReelPreviewPlayer ─────────────────────────────────────────────────────

    @MainActor
    func testTheReelPlayerReleasesItsAssetOnTheWayOut() throws {
        let player = ReelPreviewPlayer(url: URL(fileURLWithPath: "/tmp/reel.mp4"),
                                       isRegenerating: false)
        let coordinator = player.makeCoordinator()
        let container = NSView()
        let playerView = AVPlayerView()
        playerView.player = AVPlayer(playerItem: AVPlayerItem(
            asset: AVURLAsset(url: URL(fileURLWithPath: "/tmp/reel.mp4"))))
        container.addSubview(playerView)

        ReelPreviewPlayer.dismantleNSView(container, coordinator: coordinator)

        XCTAssertNil(playerView.player,
                     "leaving the screen must release the asset, or a player "
                     + "keeps the overwritten file memory-mapped")
    }

    @MainActor
    func testDismantlingAViewWithNoPlayerIsNotACrash() {
        // SwiftUI can dismantle a view whose subview tree is not what we built,
        // and a teardown that traps is worse than one that does nothing.
        let coordinator = ReelPreviewPlayer.Coordinator()
        ReelPreviewPlayer.dismantleNSView(NSView(), coordinator: coordinator)
    }

    // ── the family, not just the instances ────────────────────────────────────

    /// Every AppKit wrapper in the app, read from the source.
    ///
    /// Derived rather than listed, because a list written here exempts the next
    /// wrapper somebody adds, which is the one this guard exists for (L96).
    private func wrapperFiles() throws -> [(file: String, type: String, body: String)] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")

        var found: [(String, String, String)] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines)
            where line.contains(": NSViewRepresentable")
               || line.contains(": NSViewControllerRepresentable") {
                let name = line.components(separatedBy: "struct ").last?
                    .components(separatedBy: ":").first?
                    .trimmingCharacters(in: .whitespaces) ?? line
                found.append((url.lastPathComponent, name, text))
            }
        }
        return found
    }

    func testEveryAppKitWrapperHasAnsweredTheLifetimeQuestion() throws {
        let wrappers = try wrapperFiles()
        XCTAssertGreaterThanOrEqual(wrappers.count, 3,
                                    "the scan stopped matching, so this guard is vacuous")

        // A wrapper answers the question either by tearing down what it made,
        // or by saying in words why it has nothing to tear down. Silence is the
        // state #196 shipped in.
        let unanswered = wrappers.filter { wrapper in
            !wrapper.body.contains("dismantleNSView")
                && !wrapper.body.contains("Lifetime, audited")
                && !wrapper.body.contains("audited against #196")
        }
        XCTAssertTrue(unanswered.isEmpty,
                      "these AppKit wrappers neither tear down what they create "
                      + "nor say why they need not: "
                      + "\(unanswered.map { "\($0.type) in \($0.file)" })")
    }
}
