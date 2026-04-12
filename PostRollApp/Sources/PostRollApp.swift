import SwiftUI

@main
struct PostRollApp: App {
    @State private var appState = AppState()
    @State private var hashtagStore = HashtagStore()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(appState)
                .environment(hashtagStore)
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
        }
    }
}
