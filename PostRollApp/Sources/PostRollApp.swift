import SwiftUI

@main
struct PostRollApp: App {
    @State private var appState = AppState()
    @State private var hashtagStore = HashtagStore()
    @State private var analyticsStore = AnalyticsStore()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(appState)
                .environment(hashtagStore)
                .environment(analyticsStore)
                .preferredColorScheme(.light)
                .tint(Color.roseGold)
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
                    NSPasteboard.general.setString(
                        "cd /Users/danielhankins-wright/Documents/PostRoll && make install",
                        forType: .string
                    )
                }
            }
        }
    }
}
