import SwiftUI

struct InsightsSidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(AnalyticsStore.self) private var analyticsStore

    private let sections: [(InsightsSection, String, String)] = [
        (.overview, "Overview",  "chart.bar.xaxis"),
        (.posts,    "Posts",     "photo.stack"),
        (.orgs,     "Orgs",      "building.2"),
    ]

    var body: some View {
        @Bindable var appState = appState

        List {
            // Fixed navigation rows
            ForEach(sections, id: \.0) { section, label, icon in
                let isSelected = appState.insightsSection == section
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .imageScale(.small)
                        .foregroundStyle(isSelected ? Color.roseGold : Color.warmMid)
                        .frame(width: 16)
                    Text(label)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.warmDark : Color.warmMid)
                    Spacer()
                    if section == .posts {
                        let count = analyticsStore.posts.count
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.warmMid)
                        }
                    } else if section == .orgs {
                        let count = analyticsStore.uniqueOrgs.count
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.warmMid)
                        }
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture { appState.insightsSection = section }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(isSelected ? Color.roseGold.opacity(0.12) : Color.clear)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowSeparator(.hidden)
            }

            // Report history
            if !analyticsStore.reports.isEmpty {
                Section {
                    ForEach(analyticsStore.reports) { report in
                        ReportHistoryRow(report: report)
                    }
                } header: {
                    Text("HISTORY")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(Color.warmMid)
                        .padding(.top, Spacing.sm)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.creamDeep)
        .navigationTitle("")
    }
}

// MARK: - Report history row

private struct ReportHistoryRow: View {
    let report: InsightReport

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .imageScale(.small)
                .foregroundStyle(Color.warmMid)
            Text(Self.formatter.localizedString(for: report.generatedAt, relativeTo: Date()))
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
            Spacer()
            Text("\(report.postCount) posts")
                .font(.system(size: 10))
                .foregroundStyle(Color.warmMid)
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12))
        .listRowSeparator(.hidden)
    }
}
