import AppKit
import Observation

/// Links waiting for a window to put them in (#840).
///
/// macOS hands a `postroll://` URL to the APPLICATION, and the application is
/// alive before its first scene is. On a cold launch, which is the commonest
/// case (Dan clicks the task note; PostRoll is not open), the URL can arrive
/// before there is anything on screen to fill in. Handling it where it lands
/// would drop it, and dropping it looks exactly like a link that did nothing.
///
/// So the delivery point does one thing: it puts the URL here. The window
/// drains this when it appears and again whenever something arrives, which
/// covers both orders without either side knowing which one happened.
@MainActor
@Observable
final class DeepLinkInbox {

    /// The one the delegate feeds and the window reads.
    ///
    /// A shared instance rather than an injected one because the two ends are
    /// an AppKit delegate and a SwiftUI scene, and there is no moment where one
    /// could hand the other an object. Tests build their own.
    static let shared = DeepLinkInbox()

    /// What has arrived and not been dealt with. Observable, so a link arriving
    /// while the window is up wakes it rather than waiting for the next appear.
    private(set) var pending: [URL] = []

    func receive(_ url: URL) {
        pending.append(url)
    }

    /// Everything waiting, handed over once.
    ///
    /// Emptied here rather than by the caller: a second window, or a second
    /// appearance of the same one, would otherwise re-open a sheet Dan had
    /// already cancelled.
    func drain() -> [URL] {
        let waiting = pending
        pending = []
        return waiting
    }
}

/// The delivery point.
///
/// `application(_:open:)` rather than SwiftUI's `onOpenURL`, and only one of
/// them, because two routes into the same handling is two things doing one job
/// and the pair disagree about the cold launch: this is the AppKit method the
/// `kAEGetURL` event actually reaches, and `onOpenURL` is a layer over it that
/// needs a scene to exist first.
final class DeepLinkDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { DeepLinkInbox.shared.receive(url) }
        }
    }

    /// Closing the window does not quit PostRoll (#847).
    ///
    /// Measured on the real app on 2026-08-23: Cmd+W terminated the process
    /// outright. SwiftUI ends the app when the last window of a single `Window`
    /// scene closes, and nothing here said otherwise.
    ///
    /// #847 asked whether a closed window could be got back and the honest
    /// answer was that there was nothing to get back to. Two reasons that is
    /// wrong, and the second is the serious one.
    ///
    /// Cmd+W means "close this window" in every Mac app, and PostRoll replaces
    /// the New Window command, so quitting on it is both a surprise and one
    /// without an obvious way back.
    ///
    /// And the app already treats quitting while work is in flight as
    /// destructive: `BuildBehindSheet` asks all three background managers
    /// `hasWorkInFlight` and refuses to start an update while any of them is
    /// busy, precisely because installing quits the app (#686). Cmd+W performed
    /// that same quit with no such check, so a generation, an export or a page
    /// read could be killed by a reflex keystroke, and nothing anywhere would
    /// say what had happened to it.
    ///
    /// This is on the delegate rather than expressed in the scene, because it is
    /// a statement about the application rather than about any one window, and
    /// because a delegate method is reachable from the unit suite while
    /// `PostRollApp.swift` is not.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
