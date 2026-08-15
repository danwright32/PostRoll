import SwiftUI
import AppKit

struct InsightsPostsView: View {
    @Environment(AnalyticsStore.self) private var analyticsStore

    @State private var filterType: FilterType = .all
    @State private var searchText = ""

    enum FilterType: String, CaseIterable {
        case all    = "All"
        case feed   = "Feed"
        case stories = "Stories"
    }

    private var filteredPosts: [IGPost] {
        var base = analyticsStore.posts
        switch filterType {
        case .all:     break
        case .feed:    base = base.filter { $0.mediaType != .story }
        case .stories: base = base.filter { $0.mediaType == .story }
        }
        if searchText.isEmpty { return base }
        return base.filter { $0.caption.localizedCaseInsensitiveContains(searchText) ||
                              ($0.org ?? "").localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: Spacing.md) {
                Picker("Filter", selection: $filterType) {
                    ForEach(FilterType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()

                Spacer()

                Text("\(filteredPosts.count) posts")
                    .font(.light(11))
                    .foregroundStyle(Color.warmMid)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(PaintedSurfaces.deepPage)

            PaintedSurfaces.edgeRule.frame(height: 0.5)

            if analyticsStore.posts.isEmpty {
                PostsEmptyState()
            } else if filteredPosts.isEmpty {
                // The message says which of the two emptied the list, because a
                // Stories or Feed segment that matches nothing is not a search
                // miss and reading one as the other sends Dan to the wrong
                // control (L11).
                VStack(spacing: 6) {
                    Text(InsightsPostsEmpty.message(searchText: searchText,
                                                    filter: filterType.rawValue))
                        .font(.light(12))
                        .foregroundStyle(Color.warmMid)
                    if !searchText.isEmpty {
                        Button("Clear Search") { searchText = "" }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                            .padding(.top, Spacing.xs)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PaintedSurfaces.page)
            } else {
                List {
                    ForEach(filteredPosts) { post in
                        PostRow(post: post)
                            .listRowBackground(Color.cream)
                            .listRowInsets(EdgeInsets(top: 6, leading: Spacing.lg, bottom: 6, trailing: Spacing.lg))
                            .listRowSeparatorTint(Color.creamEdge)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(PaintedSurfaces.page)
            }
        }
        .background(PaintedSurfaces.page)
        // Attached to the screen, never to the non-empty branch. Inside that
        // branch the List and the toolbar's search field both leave the
        // hierarchy the moment a query matches nothing, so the state Dan is
        // stuck in removes the only control that changes it (L45, L109).
        .searchable(text: $searchText, prompt: "Search captions and orgs")
    }
}

// MARK: - Post row

private struct PostRow: View {
    let post: IGPost

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var mediaIcon: String {
        switch post.mediaType {
        case .story:    return "photo.badge.clock"
        case .reel:     return "play.rectangle"
        case .carousel: return "rectangle.stack"
        case .image:    return "photo"
        case .video:    return "video"
        case .unknown:  return "questionmark.square"
        }
    }

    private var metrics: [InsightsDisplay.Metric] {
        InsightsDisplay.metrics(likes: post.likes, comments: post.comments,
                                saves: post.saves, replies: post.replies,
                                reach: post.reach, follows: post.follows,
                                durationSec: post.durationSec)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .center, spacing: 4) {
                Image(systemName: mediaIcon)
                    .foregroundStyle(Color.warmMid)
                    .imageScale(.medium)
                Text(dateFormatter.string(from: post.publishedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.warmMid)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 56)

            VStack(alignment: .leading, spacing: 4) {
                if let org = post.org {
                    Text("@\(org)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                }
                Text(post.caption.isEmpty ? "(no caption)" : post.caption)
                    .font(.light(12))
                    .foregroundStyle(post.caption.isEmpty ? Color.warmMid : Color.warmDark)
                    .lineLimit(3)

                if !post.hashtags.isEmpty {
                    Text(post.hashtags.prefix(5).joined(separator: " ") + (post.hashtags.count > 5 ? " +\(post.hashtags.count - 5)" : ""))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.warmMid)
                        .lineLimit(1)
                }

                if !metrics.isEmpty {
                    // Symbols rather than emoji (#469), and read aloud as one
                    // sentence rather than as a row of glyph names.
                    HStack(spacing: 10) {
                        ForEach(metrics, id: \.name) { metric in
                            HStack(spacing: 3) {
                                Image(systemName: metric.symbol)
                                    .font(.system(size: 9))
                                Text(metric.value)
                                    .font(.system(size: 10))
                            }
                        }
                    }
                    .foregroundStyle(Color.warmMid)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(InsightsDisplay.metricsLabel(metrics))
                }

                // The post itself, which the import has always stored the link
                // to and nothing ever offered (#490).
                if let url = URL(string: post.igPermalink), !post.igPermalink.isEmpty {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Open on Instagram", systemImage: "arrow.up.forward.square")
                            .font(.system(size: 10))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                    }
                    .buttonStyle(.plain)
                    .help("Open this post on Instagram")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Empty state

private struct PostsEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .font(.system(size: 28))
                .foregroundStyle(Color.warmMid)
            Text("No posts imported yet.")
                .font(.light(13))
                .foregroundStyle(Color.warmMid)
            Text("Use the Import CSV button on Overview to load your Meta export.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaintedSurfaces.page)
    }
}
