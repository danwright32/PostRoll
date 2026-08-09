import SwiftUI

struct InsightsDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(AnalyticsStore.self) private var analyticsStore

    var body: some View {
        VStack(spacing: 0) {
            // An error state and an empty state are different screens (#88).
            // A failed decode used to reach an NSLog and nothing else, so the
            // whole imported history could go and all Dan would see is an
            // empty Insights screen, which reads as "nothing imported yet".
            if case .failedToLoad(let warning) = InsightsDisplay.state(
                recoveryMessage: analyticsStore.recoveryMessage,
                postCount: analyticsStore.posts.count) {
                BrandBanner(icon: "exclamationmark.triangle",
                            message: warning,
                            style: .error)
                    .padding([.horizontal, .top], Spacing.xl)
            }

            switch appState.insightsSection {
            case .overview: InsightsOverviewView()
            case .posts:    InsightsPostsView()
            case .orgs:     InsightsOrgsView()
            }
        }
    }
}
