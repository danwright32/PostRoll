import SwiftUI

@main
struct PostRollApp: App {
    @State private var appState = AppState()
    @State private var hashtagStore = HashtagStore()
    @State private var analyticsStore = AnalyticsStore()
    @State private var generationManager = GenerationManager()
    @State private var ocrManager = OCRManager()
    @State private var exportManager = ExportManager()
    /// App scoped, so a programme notes search survives the section it was
    /// started from being collapsed and the screen being replaced (#693).
    @State private var notesManager = ProgramNotesManager()

    init() {
        NotificationService.shared.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(appState)
                .environment(hashtagStore)
                .environment(analyticsStore)
                .environment(generationManager)
                .environment(ocrManager)
                .environment(exportManager)
                .environment(notesManager)
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
                    appState.showingNewEvent = true
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
        }
    }
}
