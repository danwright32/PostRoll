import SwiftUI

struct InsightsDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.insightsSection {
        case .overview: InsightsOverviewView()
        case .posts:    InsightsPostsView()
        case .orgs:     InsightsOrgsView()
        }
    }
}
