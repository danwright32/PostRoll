import SwiftUI

/// The commands that put something on the window, which have to make sure there
/// IS one (#884, #847).
///
/// Both actions here only set state on `AppState`, and a sheet with no window
/// has nowhere to be presented. Nothing in this app opened a window from code:
/// the scene comes back when macOS reopens the app, which is what clicking the
/// Dock icon does, and that is the only route there was. So with the window
/// closed, Cmd+N set the flag and NOTHING appeared.
///
/// That is worse than an inert command. The request is recorded, so the form
/// turns up later, on whatever window opens next, with nobody having asked for
/// it then.
///
/// Measured on the runner on 2026-08-24, run 32684066381, and it had never been
/// measured before: it is step 2 of a manual checklist nobody had run. The same
/// run pressed this command WITH a window open moments earlier and the form
/// appeared, which is what separates a dead command from a click that never
/// landed (L248, L159).
///
/// `openWindow` on a `Window` scene brings the one window forward rather than
/// making a second, so this cannot reintroduce #842.
private struct SheetCommands: Commands {

    let appState: AppState

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Event…") {
                openWindow(id: PostRollApp.mainWindowID)
                appState.presentNewEvent()
            }
            .keyboardShortcut("n")

            Divider()

            // The one place that answers "which days need re-rendering
            // after a design change" (#293). It walks the preview folder,
            // so it is behind a menu item rather than running on its own.
            Button("Outdated Designs…") {
                openWindow(id: PostRollApp.mainWindowID)
                appState.presentOutdatedDesigns()
            }
        }
    }
}

@main
struct PostRollApp: App {

    /// The one window's id, named once so the scene and the commands that reopen
    /// it cannot drift apart.
    static let mainWindowID = "main"

    @State private var appState = AppState()
    @State private var hashtagStore = HashtagStore()
    @State private var analyticsStore = AnalyticsStore()
    /// The default posting layout, owned here and handed to the Settings scene
    /// that edits it (#727).
    @State private var presetStore = PostingPresetStore()
    /// Every owner of work that outlives a screen, in one list rather than
    /// seven declarations here and the same seven again in the test harness
    /// that renders whole screens (#718). See `AppOwners`.
    @State private var owners = AppOwners()

    /// Where a `postroll://` link lands (#840).
    ///
    /// An AppKit delegate rather than `onOpenURL`, and only one of the two,
    /// because they disagree about the case that matters: on a cold launch the
    /// URL is delivered to the application before the first scene exists. This
    /// is the method that event actually reaches, and it puts the URL in the
    /// inbox rather than handling it, so there is something waiting whichever
    /// order the two happen in.
    @NSApplicationDelegateAdaptor(DeepLinkDelegate.self) private var deepLinks


    /// Tell the delegate what is running, so it can ask before quitting (#862).
    ///
    /// Here rather than in the delegate itself because the owners live in this
    /// struct's `@State` and an AppKit delegate has no view around it to read
    /// them from. A closure rather than a copied list: the answer has to be the
    /// one true at the instant of the quit, and a value handed over at launch
    /// would be the answer from launch forever (L175).
    private func wireQuitGuard() {
        deepLinks.workInFlight = { owners.workInFlight }
    }

    var body: some Scene {
        // ONE window, declared rather than hoped for (#842).
        //
        // This was a `WindowGroup`, and SwiftUI treats an incoming URL open
        // event as an external event that a group answers by opening a NEW
        // window. Measured on the real machine the day #840 shipped: one
        // window, two after a link, three after a quit and another link, since
        // window restoration brings the extras back.
        //
        // The cost was not the clutter. Which sheet is showing is one piece of
        // state on the shared AppState and every window binds to it, so a single
        // link put a New Event sheet on all three, showing the same prefill,
        // and cancelling one left the others standing.
        //
        // PostRoll has always been a one window app: the New Window command is
        // replaced below. Saying so here removes the class rather than the one
        // route into it, and it means a flag on shared state has exactly one
        // surface to be presented on.
        Window("PostRoll", id: PostRollApp.mainWindowID) {
            MainWindowView()
                .task {
                    wireQuitGuard()
                    // Join the handle lookups to the figures fetch (#1004).
                    // Here rather than at either end, because this is the one
                    // place that already knows about both.
                    owners.connectTheHandleTrigger()
                    // The events that were already in the store when that
                    // trigger shipped, which it can never reach (#1268).
                    owners.backfillTheArchive(events: appState.events)
                }
                .environment(appState)
                .environment(hashtagStore)
                .environment(analyticsStore)
                .environment(presetStore)
                .withAppOwners(owners)
                .preferredColorScheme(.light)
                // The accent every system control inherits: a spinner's arc, a
                // slider's filled track, a picker's selection. Named as the
                // icon role rather than written raw, because that is what it is
                // in: a mark, held to 3:1 rather than to the 4.5:1 the same
                // colour would need as words (#591).
                .tint(PaintedSurfaces.iconAccent)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    NotificationService.shared.clearDelivered()
                    NotificationService.shared.clearBadge()
                }
                // A debounced edit must never be lost to a quit or to Dan
                // switching away mid sentence (#91, #197). Both are cheap: the
                // flush does nothing when no edit is pending.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.flushPendingWrites()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    appState.flushPendingWrites()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 760)
        .commands {
            SheetCommands(appState: appState)
            CommandGroup(replacing: .help) {
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("postroll", forType: .string)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(presetStore)
        }
    }
}
