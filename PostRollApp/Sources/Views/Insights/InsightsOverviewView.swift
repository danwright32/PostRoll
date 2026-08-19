import SwiftUI
import AppKit

struct InsightsOverviewView: View {
    @Environment(AnalyticsStore.self) private var analyticsStore
    @Environment(HashtagStore.self) private var hashtagStore
    @Environment(AppState.self) private var appState
    /// Both runs belong to the app, not to this screen (#718).
    ///
    /// They used to live here in `@State`: the in flight flag, the start time
    /// the elapsed clock is measured from, and the error message. Clicking
    /// Events in the sidebar destroys this view and took all three with it, so
    /// a run still going, one that had finished and one that had failed all
    /// looked identical, because all three showed nothing. This screen now
    /// READS them.
    @Environment(InsightsWorkManager.self) private var insightsWork

    private var importRun: InsightsWorkManager.Outcome? {
        insightsWork.outcome(for: .importCSV)
    }
    private var reportRun: InsightsWorkManager.Outcome? {
        insightsWork.outcome(for: .generateReport)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {

                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("INSTAGRAM INSIGHTS")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(PaintedSurfaces.bodyText)
                        if let last = analyticsStore.lastImport {
                            let f: DateFormatter = {
                                let d = DateFormatter()
                                d.dateStyle = .medium
                                d.timeStyle = .none
                                return d
                            }()
                            Text("Last import \(f.string(from: last)) · \(analyticsStore.feedPosts.count) feed, \(analyticsStore.storyPosts.count) stories")
                                .font(.light(11))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                        }
                    }
                    Spacer()
                    Button {
                        importCSV()
                    } label: {
                        Label(insightsWork.isRunning(.importCSV) ? "Importing…" : "Import CSV",
                              systemImage: "square.and.arrow.down")
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                    }
                    .buttonStyle(.plain)
                    .disabled(insightsWork.isRunning(.importCSV))
                    .help("Import Meta Business Suite CSV export (allows multiple files)")
                }

                if insightsWork.isRunning(.importCSV) {
                    LongRunIndicator(label: "Reading the CSV files…",
                                     startedAt: insightsWork.startedAt(.importCSV),
                                     silenceThreshold: LongRunState.localWorkSilenceThreshold)
                }

                // Numbers produced by the old timezone reading (#549). Placed
                // directly under the Import CSV button rather than somewhere
                // that merely describes it, because this is the one control
                // that clears the notice, and it clears itself the moment an
                // import lands (L111).
                if AnalyticsStaleness.isStale(postCount: analyticsStore.posts.count,
                                              lastImport: analyticsStore.lastImport) {
                    // The notice itself is its own view so it can be rendered
                    // and measured like every other notice (#559). What stays
                    // here is the decision to show it, which needs the store.
                    AnalyticsStalenessNotice()
                }

                RoseGoldDivider()

                if let summary = importRun?.success {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(PaintedSurfaces.insightConfidenceHigh)
                        Text(summary)
                            .font(.light(12))
                            .foregroundStyle(PaintedSurfaces.bodyText)
                    }
                    .transition(.opacity)
                }

                if let error = importRun?.note {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(PaintedSurfaces.iconAccent)
                        Text(error)
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
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
                            Label(insightsWork.isRunning(.generateReport)
                                      ? "Analyzing…" : "Generate Insights",
                                  systemImage: "sparkles")
                        }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(insightsWork.isRunning(.generateReport))

                        if insightsWork.isRunning(.generateReport) {
                            // A paid Claude pass over the whole post history,
                            // behind an indefinite spinner with no elapsed time
                            // and no stall state until #460, and behind nothing
                            // at all once the sidebar moved off Insights (#718).
                            LongRunIndicator(label: "Analyzing your posts…",
                                             startedAt: insightsWork.startedAt(.generateReport))
                                .padding(.leading, 4)
                        }
                        Spacer()
                    }

                    if let genError = reportRun?.note {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(PaintedSurfaces.iconAccent)
                            Text(genError)
                                .font(.light(11))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
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
        .background(PaintedSurfaces.page)
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

        // Choosing the files is this screen's business; reading them is not.
        // What may be claimed about the result lives with the run, so a refused
        // write still says so when Dan comes back to look (#439, #718).
        insightsWork.startImport(of: panel.urls, into: analyticsStore)
    }

    private func generateInsights() {
        insightsWork.startReport(store: analyticsStore,
                                 globalHashtags: hashtagStore.globalTags)
    }
}

// MARK: - Empty state

private struct InsightsEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("No Instagram data yet.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PaintedSurfaces.bodyText)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                InstructionRow(number: "1", text: "Open **business.facebook.com** on your Mac.")
                InstructionRow(number: "2", text: "Left sidebar → **Insights** → **Content** tab.")
                InstructionRow(number: "3", text: "Click **Export Data** (top right), choose **CSV** + **post-level**.")
                InstructionRow(number: "4", text: "Repeat for **stories** if you want those analyzed too.")
                InstructionRow(number: "5", text: "Click **Import CSV** above and select your files.")
            }

            Text("Meta exports stories and feed posts as separate CSVs. Import both at once for the full picture.")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(PaintedSurfaces.deepPage)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)
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
                .foregroundStyle(PaintedSurfaces.pageAccentText)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.light(12))
                .foregroundStyle(PaintedSurfaces.bodyText)
        }
    }
}

// MARK: - Report View

/// Internal rather than private so the review sheet can draw it (#645).
///
/// It is handed its report and reads nothing, which is what makes it safe to
/// render in a test: the screen around it fetches from the analytics store
/// and would go to disk (L2).
struct InsightReportView: View {
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
                        .foregroundStyle(PaintedSurfaces.bodyText)
                    Text("Generated \(dateFormatter.string(from: report.generatedAt)) · \(report.feedCount) feed, \(report.storyCount) stories")
                        .font(.light(11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
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
                        .foregroundStyle(PaintedSurfaces.bodyText)
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
                        .foregroundStyle(PaintedSurfaces.secondaryText)
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
                            // A bullet drawn beside each caveat, not a word of
                            // it, so it is hidden rather than announced ahead of
                            // every line (#538).
                            Text("·")
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                                .accessibilityHidden(true)
                            Text(caveat)
                                .font(.light(11))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
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
                    .foregroundStyle(PaintedSurfaces.secondaryText)
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
        case .low:    return PaintedSurfaces.insightConfidenceLow
        case .medium: return PaintedSurfaces.insightConfidenceMedium
        case .high:   return PaintedSurfaces.insightConfidenceHigh
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
                        .foregroundStyle(PaintedSurfaces.bodyText)
                    if isExpanded {
                        Text(finding.evidence)
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            .lineSpacing(3)
                            .transition(.opacity)
                    }
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(PaintedSurfaces.deepPage)
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
                .foregroundStyle(PaintedSurfaces.bodyText)
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
            .foregroundStyle(applied ? PaintedSurfaces.secondaryText : PaintedSurfaces.pageAccentText)
            .disabled(applied)
        }

        if let saveError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                Text(saveError)
                    .font(.light(11))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(PaintedSurfaces.deepPage)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)
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
            .foregroundStyle(PaintedSurfaces.pageAccentText)
    }
}
