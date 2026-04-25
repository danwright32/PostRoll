import SwiftUI

@main
struct PostRollApp: App {
    @State private var appState = AppState()
    @State private var hashtagStore = HashtagStore()
    @State private var analyticsStore = AnalyticsStore()

    init() {
        NotificationService.shared.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(appState)
                .environment(hashtagStore)
                .environment(analyticsStore)
                .preferredColorScheme(.light)
                .tint(Color.roseGold)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    NotificationService.shared.clearDelivered()
                    NotificationService.shared.clearBadge()
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
