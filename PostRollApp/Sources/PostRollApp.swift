import SwiftUI

@main
struct PostRollApp: App {
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

    init() {
        NotificationService.shared.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
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
            CommandGroup(replacing: .newItem) {
                Button("New Event…") {
                    appState.presentNewEvent()
                }
                .keyboardShortcut("n")

                Divider()

                // The one place that answers "which days need re-rendering
                // after a design change" (#293). It walks the preview folder,
                // so it is behind a menu item rather than running on its own.
                Button("Outdated Designs…") {
                    appState.showingOutdatedDesigns = true
                }
            }
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
