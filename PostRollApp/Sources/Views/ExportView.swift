import SwiftUI

struct ExportView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(ExportManager.self) private var exportManager
    @Environment(PostingPresetStore.self) private var presetStore
    @Environment(GenerationManager.self) private var genManager

    @State private var showingFolderPicker = false
    @State private var lastExportFolder: URL? = nil
    @State private var pendingSingleDay: DayName? = nil

    /// Export progress is owned app-scoped by ExportManager so it survives this
    /// view being torn down on an event switch (`.id(event.id)` remount) and
    /// drives the sidebar "Exporting…" pill. `nil` run = the ready screen.
    private var run: ExportManager.Run? { exportManager.run(for: event.id) }
    private var mediaElapsed: Int { run?.elapsedSeconds ?? 0 }
    private var estimatedMediaSeconds: Double? { run?.estimatedMediaSeconds }

    private var result: WeekGenerationResult? { event.weekResult }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                EventHeader(event: event, subtitle: "Export")
                    .padding([.horizontal, .top], Spacing.xl)
                    .padding(.bottom, Spacing.md)

                switch run?.phase {
                case .none:
                    readyContent
                case .exportingText:
                    progressContent(label: "Exporting captions & blog…")
                case .generatingMedia(let folder):
                    mediaProgressContent(folder: folder)
                case .done(let folder, let mediaError):
                    doneContent(folder: folder, mediaError: mediaError)
                case .failed(let msg):
                    errorContent(msg)
                }
            }
        }
        .background(Color.cream)
        .onAppear {
            if let path = UserDefaults.standard.string(forKey: "lastExportFolder") {
                let candidate = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    lastExportFolder = candidate
                }
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let dest = urls.first {
                let scopedDay = pendingSingleDay
                pendingSingleDay = nil
                lastExportFolder = dest
                exportManager.start(eventID: event.id, to: dest, onlyDay: scopedDay, appState: appState)
            } else {
                pendingSingleDay = nil
            }
        }
    }

    // MARK: - States

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            StageBackButton(label: "Back to caption review") {
                var ev = event
                ev.stage = .captionsReviewed
                appState.updateEvent(ev)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.sm)

            BrandBanner(
                icon: "folder",
                message: "Exports captions and blog draft, then generates story images, Wednesday collage, Thursday scroll reel, Friday before/after, and Tuesday speed edit reel (where inputs are provided). Requires ffmpeg for reels."
            )
            .padding(.horizontal, Spacing.xl)

            presetPicker
                .padding(.horizontal, Spacing.xl)

            ExportSummaryCard(event: event, result: result) { day in
                if let dest = lastExportFolder {
                    exportManager.start(eventID: event.id, to: dest, onlyDay: day, appState: appState)
                } else {
                    pendingSingleDay = day
                    showingFolderPicker = true
                }
            }
            .padding(.horizontal, Spacing.xl)

            VStack(alignment: .trailing, spacing: Spacing.sm) {
                if let last = lastExportFolder {
                    HStack {
                        Spacer()
                        Button("Export to \"\(last.lastPathComponent)\"") {
                            exportManager.start(eventID: event.id, to: last, appState: appState)
                        }
                            .buttonStyle(BrandButtonStyle())
                    }
                    HStack {
                        Spacer()
                        // Clear any single-day scope left behind by a cancelled
                        // picker: the completion handler never fires on cancel,
                        // and a stale value would silently turn this full
                        // export into a single-day one.
                        Button("Choose different folder…") {
                            pendingSingleDay = nil
                            showingFolderPicker = true
                        }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.roseGold)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Choose Destination…") {
                            pendingSingleDay = nil
                            showingFolderPicker = true
                        }
                            .buttonStyle(BrandButtonStyle())
                    }
                }
            }
            .padding(Spacing.xl)
            .disabled(isRegenerating)
        }
    }

    private var isRegenerating: Bool { genManager.isRunning(event.id) }

    /// App wide posting layout. Switching it rebuilds Sunday/Monday/Wednesday
    /// (their captions and media change) so the affected days are regenerated.
    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.md) {
                Text("Posting layout")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.warmDark)
                Picker("Posting layout", selection: Binding(
                    get: { presetStore.selected },
                    set: { applyPreset($0) }
                )) {
                    ForEach(PostingPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .disabled(isRegenerating)
            }
            if isRegenerating {
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small).tint(Color.roseGold)
                    Text("Rebuilding Sunday, Monday, and Wednesday for the new layout…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmDark.opacity(0.8))
                }
            } else {
                Text(presetStore.selected == .balanced
                     ? "Sunday, Monday, and Wednesday each post a 4 photo carousel with a collage story."
                     : "Sunday and Monday post a single photo; Wednesday posts a 10 photo carousel with a collage story.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmDark.opacity(0.7))
            }
        }
    }

    /// Persist the new preset and regenerate the days it governs. Their previews
    /// are cleared first so a failed regen can't leave the export copying stale
    /// assets from the previous layout.
    private func applyPreset(_ newValue: PostingPreset) {
        guard newValue != presetStore.selected else { return }
        presetStore.selected = newValue
        presetStore.save()

        guard var ev = appState.events.first(where: { $0.id == event.id }) else { return }
        let governed = DayName.allCases.filter { newValue.format(for: $0) != nil }
        let affected = Set(governed
            .filter { !(ev.days[$0.rawValue]?.photoPaths.isEmpty ?? true) }
            .map { $0.rawValue })
        guard !affected.isEmpty else { return }

        for day in affected { ev.previewMediaPaths.removeValue(forKey: day) }
        appState.updateEvent(ev)
        genManager.start(eventID: event.id, retryDays: affected, appState: appState,
                         regenerateGraphics: true)
    }

    private func progressContent(label: String) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer().frame(height: Spacing.xl)
            ProgressView()
                .controlSize(.large)
                .tint(Color.roseGold)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.warmDark)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    private func mediaProgressContent(folder: URL) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer().frame(height: Spacing.xl)
            ProgressView()
                .controlSize(.large)
                .tint(Color.roseGold)
            Text("Generating visual assets…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.warmDark)

            // Elapsed clock vs estimated total — mirrors the first generation
            // screen. The estimate is content-aware: copying approved previews
            // is near-instant, regenerating reels takes minutes.
            HStack(spacing: Spacing.xs) {
                Image(systemName: "timer")
                    .font(.system(size: 11))
                Text(mediaElapsedFormatted)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                if let est = estimatedMediaSeconds {
                    Text("/ \(TimingStore.formatClock(est))")
                        .font(.light(12))
                }
            }
            .foregroundStyle(Color.warmMid)

            Text("Approved previews copy instantly. Reels take longer only when they need regenerating.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            // Let user skip media generation if they just want the text
            Button("Skip, text export only") {
                exportManager.skipMedia(eventID: event.id)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.warmMid)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    private var mediaElapsedFormatted: String {
        String(format: "%d:%02d", mediaElapsed / 60, mediaElapsed % 60)
    }

    private func doneContent(folder: URL, mediaError: String?) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer().frame(height: Spacing.lg)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.roseGold.opacity(0.7))
                .padding(.top, Spacing.xl)

            Text("Export complete")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.warmDark)

            Text(folder.lastPathComponent)
                .font(.light(12))
                .foregroundStyle(Color.warmMid)

            RoseGoldDivider()
                .frame(width: 80)

            if let mediaErr = mediaError {
                BrandBanner(
                    icon: "exclamationmark.triangle",
                    message: "Captions + blog exported. Visual assets failed: \(mediaErr). Check that ffmpeg is installed.",
                    style: .warning
                )
                .frame(maxWidth: 400)
            }

            Text("This event is now archived. Use the archive button in the sidebar to revisit it.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            HStack(spacing: Spacing.md) {
                Button("Open in Finder") { NSWorkspace.shared.open(folder) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.roseGold)
                Button("Done") {
                    exportManager.clear(eventID: event.id)
                    appState.selectedEventID = nil
                }
                .buttonStyle(BrandButtonStyle())
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            BrandBanner(icon: "exclamationmark.triangle", message: message, style: .error)
                .padding(.horizontal, Spacing.xl)
            HStack {
                Spacer()
                Button("Try Again") { exportManager.clear(eventID: event.id) }
                    .buttonStyle(BrandButtonStyle())
            }
            .padding(Spacing.xl)
        }
    }

}

// MARK: - Export summary card

private struct ExportSummaryCard: View {
    let event: Event
    let result: WeekGenerationResult?
    let onExportDay: (DayName) -> Void

    private var daysWithContent: [DayName] {
        DayName.allCases.filter { day in
            if result?[day] != nil { return true }
            if day == .friday, let pd = event.days[day.rawValue],
               (pd.rawPhotoPath != nil || pd.editedPhotoPath != nil || !pd.photoPaths.isEmpty) {
                return true
            }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(daysWithContent, id: \.self) { day in
                ExportDayRow(day: day, caption: result?[day]) {
                    onExportDay(day)
                }
            }
            if result?.blog != nil {
                Divider().background(Color.creamEdge)
                ExportBlogRow(blog: result?.blog)
            }
        }
        .padding(Spacing.md)
        .background(Color.creamDeep)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.creamEdge, lineWidth: 1)
        )
    }
}

private struct ExportDayRow: View {
    let day: DayName
    let caption: DayCaption?
    let onExportJustThisDay: () -> Void

    private var summary: String {
        if day == .friday { return "Before / after story" }
        guard let c = caption?.caption, !c.isEmpty else { return "" }
        return String(c.prefix(60)) + (c.count > 60 ? "…" : "")
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(day.displayName.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.0)
                .foregroundStyle(Color.warmMid)
                .frame(width: 70, alignment: .leading)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.roseGold)
            Text(summary)
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
                .lineLimit(1)
            Spacer(minLength: Spacing.sm)
            Button("Export just this day", action: onExportJustThisDay)
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Color.roseGold)
        }
    }
}

private struct ExportBlogRow: View {
    let blog: BlogOutput?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text("BLOG")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.0)
                .foregroundStyle(Color.warmMid)
                .frame(width: 70, alignment: .leading)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.roseGold)
            Text(blog?.title ?? "Draft")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
                .lineLimit(1)
        }
    }
}

// EventExporter moved to Sources/Services/EventExporter.swift so it can be unit
// tested without pulling in this SwiftUI view.
