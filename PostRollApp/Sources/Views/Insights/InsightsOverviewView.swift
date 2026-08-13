import SwiftUI
import AppKit

struct InsightsOverviewView: View {
    @Environment(AnalyticsStore.self) private var analyticsStore
    @Environment(HashtagStore.self) private var hashtagStore
    @Environment(AppState.self) private var appState

    @State private var isImporting = false
    /// When the current import or analysis started (#460). A bare spinner looks
    /// identical whether the work is progressing, hung or dead, so both of
    /// these runs report elapsed time and convert to a stalled state.
    @State private var importStartedAt: Date?
    @State private var generationStartedAt: Date?
    @State private var importError: String?
    @State private var importSummary: String?
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {

                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("INSTAGRAM INSIGHTS")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(Color.warmDark)
                        if let last = analyticsStore.lastImport {
                            let f: DateFormatter = {
                                let d = DateFormatter()
                                d.dateStyle = .medium
                                d.timeStyle = .none
                                return d
                            }()
                            Text("Last import \(f.string(from: last)) · \(analyticsStore.feedPosts.count) feed, \(analyticsStore.storyPosts.count) stories")
                                .font(.light(11))
                                .foregroundStyle(Color.warmMid)
                        }
                    }
                    Spacer()
                    Button {
                        importCSV()
                    } label: {
                        Label(isImporting ? "Importing…" : "Import CSV", systemImage: "square.and.arrow.down")
                            .foregroundStyle(Color.roseGold)
                    }
                    .buttonStyle(.plain)
                    .disabled(isImporting)
                    .help("Import Meta Business Suite CSV export (allows multiple files)")
                }

                if isImporting {
                    LongRunIndicator(label: "Reading the CSV files…",
                                     startedAt: importStartedAt,
                                     silenceThreshold: LongRunState.localWorkSilenceThreshold)
                }

                RoseGoldDivider()

                if let summary = importSummary {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 110/255, green: 140/255, blue: 110/255))
                        Text(summary)
                            .font(.light(12))
                            .foregroundStyle(Color.warmDark)
                    }
                    .transition(.opacity)
                }

                if let error = importError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.roseGold)
                        Text(error)
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    }
                }

                // Empty state or report
                if analyticsStore.posts.isEmpty {
                    InsightsEmptyState()
                } else {
                    // Generate button
                    HStack {
                        Button {
                            generateInsights()
                        } label: {
                            Label(isGenerating ? "Analyzing…" : "Generate Insights", systemImage: "sparkles")
                        }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(isGenerating)

                        if isGenerating {
                            // A paid Claude pass over the whole post history,
                            // behind an indefinite spinner with no elapsed time
                            // and no stall state until #460.
                            LongRunIndicator(label: "Analyzing your posts…",
                                             startedAt: generationStartedAt)
                                .padding(.leading, 4)
                        }
                        Spacer()
                    }

                    if let genError = generationError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Color.roseGold)
                            Text(genError)
                                .font(.light(11))
                                .foregroundStyle(Color.warmMid)
                        }
                    }

                    // Latest report
                    if let report = analyticsStore.reports.first {
                        InsightReportView(report: report)
                    }
                }
            }
            .padding(Spacing.lg)
        }
        .background(Color.cream)
    }

    // MARK: - Actions

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .text]
        panel.title = "Select Meta Business Suite CSV exports"
        panel.message = "Select one or more CSV files exported from Meta Business Suite. You can select both the stories CSV and the feed CSV at once."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let urls = panel.urls
        isImporting = true
        importStartedAt = Date()
        importError = nil
        importSummary = nil
        Task {
            do {
                let result = try await PythonBridge.shared.importMetaCSV(paths: urls)
                let prev = analyticsStore.posts.count
                let save = analyticsStore.mergePosts(result.posts)
                let added = analyticsStore.posts.count - prev
                let updated = result.posts.count - max(0, added)
                // The words, and whether they may be said as a success, are
                // decided in one place (#439). A merge that was refused a write
                // is not an import that happened.
                switch InsightsDisplay.importNotice(imported: result.posts.count,
                                                    added: max(0, added),
                                                    updated: max(0, updated),
                                                    warnings: result.warnings.count,
                                                    save: save) {
                case .saved(let text):
                    importSummary = text
                    if !result.warnings.isEmpty {
                        importError = result.warnings.prefix(3).joined(separator: "\n")
                    }
                case .notSaved(let text):
                    // Deliberately NOT importSummary: that row renders a green
                    // tick, and a tick over a write that did not happen is the
                    // whole defect.
                    importSummary = nil
                    importError = text
                }
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
            importStartedAt = nil
        }
    }

    private func generateInsights() {
        isGenerating = true
        generationStartedAt = Date()
        generationError = nil
        let posts = analyticsStore.posts
        let bands = analyticsStore.orgFollowerBands
        let globalTags = hashtagStore.globalTags
        Task {
            do {
                let report = try await PythonBridge.shared.runAnalytics(
                    posts: posts,
                    orgBands: bands,
                    globalHashtags: globalTags
                )
                // Same rule as the import above (#439): a report the store was
                // refused permission to write is in this window only, and the
                // screen has to say so rather than showing it as recorded.
                if let unsaved = InsightsDisplay.unsavedReportNotice(
                    save: analyticsStore.addReport(report)) {
                    generationError = unsaved
                }
            } catch {
                generationError = error.localizedDescription
            }
            isGenerating = false
            generationStartedAt = nil
        }
    }
}

// MARK: - Empty state

private struct InsightsEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("No Instagram data yet.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.warmDark)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                InstructionRow(number: "1", text: "Open **business.facebook.com** on your Mac.")
                InstructionRow(number: "2", text: "Left sidebar → **Insights** → **Content** tab.")
                InstructionRow(number: "3", text: "Click **Export Data** (top right), choose **CSV** + **post-level**.")
                InstructionRow(number: "4", text: "Repeat for **stories** if you want those analyzed too.")
                InstructionRow(number: "5", text: "Click **Import CSV** above and select your files.")
            }

            Text("Meta exports stories and feed posts as separate CSVs. Import both at once for the full picture.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(Color.creamDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(Color.creamEdge, lineWidth: 1)
                )
        )
    }
}

private struct InstructionRow: View {
    let number: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.roseGold)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.light(12))
                .foregroundStyle(Color.warmDark)
        }
    }
}

// MARK: - Report View

private struct InsightReportView: View {
    let report: InsightReport
    @Environment(AnalyticsStore.self) private var analyticsStore

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            // Report metadata
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Insights Report")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.warmDark)
                    Text("Generated \(dateFormatter.string(from: report.generatedAt)) · \(report.feedCount) feed, \(report.storyCount) stories")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                }
                Spacer()
            }

            RoseGoldDivider()

            // Summary
            if !report.summary.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionHeader("SUMMARY")
                    Text(report.summary)
                        .font(.light(13))
                        .foregroundStyle(Color.warmDark)
                        .lineSpacing(4)
                }
            }

            // Feed findings
            if !report.feedFindings.captionPatterns.isEmpty ||
               !report.feedFindings.hashtagPatterns.isEmpty ||
               !report.feedFindings.contentTypePatterns.isEmpty ||
               !report.feedFindings.timingPatterns.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    SectionHeader("FEED POSTS")
                    FindingsList("Caption Patterns",      findings: report.feedFindings.captionPatterns)
                    FindingsList("Hashtag Patterns",      findings: report.feedFindings.hashtagPatterns)
                    FindingsList("Content Type",          findings: report.feedFindings.contentTypePatterns)
                    FindingsList("Timing",                findings: report.feedFindings.timingPatterns)
                }
            }

            // Story findings
            if !report.storyFindings.captionPatterns.isEmpty ||
               !report.storyFindings.contentTypePatterns.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    SectionHeader("STORIES")
                    FindingsList("Caption Patterns",  findings: report.storyFindings.captionPatterns)
                    FindingsList("Content Type",      findings: report.storyFindings.contentTypePatterns)
                    FindingsList("Timing",            findings: report.storyFindings.timingPatterns)
                }
            }

            // Brand voice suggestions
            if !report.brandVoiceSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionHeader("BRAND VOICE SUGGESTIONS")
                    Text("Apply these to your brand voice file to influence future caption generation.")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                    ForEach(report.brandVoiceSuggestions, id: \.self) { suggestion in
                        BrandVoiceSuggestionRow(suggestion: suggestion)
                    }
                }
            }

            // Caveats
            if !report.caveats.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionHeader("CAVEATS")
                    ForEach(report.caveats, id: \.self) { caveat in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·")
                                .foregroundStyle(Color.warmMid)
                            Text(caveat)
                                .font(.light(11))
                                .foregroundStyle(Color.warmMid)
                        }
                    }
                }
            }
        }
    }
}

private struct FindingsList: View {
    let title: String
    let findings: [InsightFinding]

    init(_ title: String, findings: [InsightFinding]) {
        self.title = title
        self.findings = findings
    }

    var body: some View {
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(Color.warmMid)
                ForEach(findings) { finding in
                    FindingRow(finding: finding)
                }
            }
        }
    }
}

private struct FindingRow: View {
    let finding: InsightFinding
    @State private var isExpanded = false

    private var confidenceColor: Color {
        switch finding.confidence {
        case .low:    return Color.warmMid
        case .medium: return Color.roseGold
        case .high:   return Color(red: 110/255, green: 140/255, blue: 110/255)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(confidenceColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.headline)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.warmDark)
                    if isExpanded {
                        Text(finding.evidence)
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                            .lineSpacing(3)
                            .transition(.opacity)
                    }
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Color.warmMid)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.creamDeep)
        )
    }
}

private struct BrandVoiceSuggestionRow: View {
    let suggestion: String
    @State private var applied = false
    /// A write that did not happen (#462). Applied used to flip regardless, and
    /// the button then disabled itself, so a failed save was unrecoverable from
    /// this surface.
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: 10) {
            Text(suggestion)
                .font(.light(12))
                .foregroundStyle(Color.warmDark)
                .lineSpacing(3)
            Spacer()
            Button(applied ? "Applied" : "Apply") {
                guard !applied else { return }
                do {
                    try PythonBridge.shared.appendInsightNote(suggestion)
                    saveError = nil
                    withAnimation { applied = true }
                } catch {
                    // Deliberately NOT flipping to Applied: the button stays
                    // live so the write can be tried again, which is the whole
                    // difference between this and a claim (L12).
                    saveError = BrandVoiceSaveText.failed(error.localizedDescription)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(applied ? Color.warmMid : Color.roseGold)
            .disabled(applied)
        }

        if let saveError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseDeep)
                Text(saveError)
                    .font(.light(11))
                    .foregroundStyle(Color.roseDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.creamDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .strokeBorder(Color.creamEdge, lineWidth: 1)
                )
        )
    }
}

// MARK: - Shared helpers

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(Color.roseGold)
    }
}
