import SwiftUI

struct ExportView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var exportState: ExportState = .ready
    @State private var showingFolderPicker = false
    @State private var exportedFolder: URL? = nil   // set after text export so media gen can use it
    @State private var lastExportFolder: URL? = nil
    @State private var mediaGenerationError: String? = nil
    @State private var pendingSingleDay: DayName? = nil

    enum ExportState {
        case ready
        case exportingText
        case generatingMedia(URL)   // folder where text export landed
        case done(URL)
        case failed(String)
    }

    private var result: WeekGenerationResult? { event.weekResult }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                EventHeader(event: event, subtitle: "Export")
                    .padding([.horizontal, .top], Spacing.xl)
                    .padding(.bottom, Spacing.md)

                switch exportState {
                case .ready:
                    readyContent
                case .exportingText:
                    progressContent(label: "Exporting captions & blog…")
                case .generatingMedia(let folder):
                    mediaProgressContent(folder: folder)
                case .done(let folder):
                    doneContent(folder: folder)
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
                runExport(to: dest, onlyDay: scopedDay)
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

            ExportSummaryCard(event: event, result: result) { day in
                if let dest = lastExportFolder {
                    runExport(to: dest, onlyDay: day)
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
                        Button("Export to \"\(last.lastPathComponent)\"") { runExport(to: last) }
                            .buttonStyle(BrandButtonStyle())
                    }
                    HStack {
                        Spacer()
                        Button("Choose different folder…") { showingFolderPicker = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.roseGold)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Choose Destination…") { showingFolderPicker = true }
                            .buttonStyle(BrandButtonStyle())
                    }
                }
            }
            .padding(Spacing.xl)
        }
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
            Text("Stories + collage: ~30s. Reels: 2 to 5 min each.")
                .font(.light(12))
                .foregroundStyle(Color.warmMid)

            // Let user skip media generation if they just want the text
            Button("Skip, text export only") {
                exportState = .done(folder)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.warmMid)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    private func doneContent(folder: URL) -> some View {
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

            if let mediaErr = mediaGenerationError {
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
                Button("Try Again") { exportState = .ready }
                    .buttonStyle(BrandButtonStyle())
            }
            .padding(Spacing.xl)
        }
    }

    // MARK: - Export logic

    private func runExport(to destinationRoot: URL, onlyDay: DayName? = nil) {
        guard destinationRoot.startAccessingSecurityScopedResource() else {
            exportState = .failed("Could not access the selected folder.")
            return
        }

        UserDefaults.standard.set(destinationRoot.path, forKey: "lastExportFolder")
        lastExportFolder = destinationRoot
        exportState = .exportingText

        let scopedDays: Set<DayName>? = onlyDay.map { [$0] }
        let capturedEvent = event

        Task {
            do {
                // Step 1: text export (fast, on background thread)
                let folder = try await Task.detached {
                    defer { destinationRoot.stopAccessingSecurityScopedResource() }
                    return try EventExporter.export(
                        event: capturedEvent,
                        to: destinationRoot,
                        days: scopedDays
                    )
                }.value

                await MainActor.run { exportState = .generatingMedia(folder) }

                // Step 2: copy assets from the already-approved preview files where
                // possible, and only invoke Python for days whose preview files are
                // missing or stale. The common case (everything previewed on the
                // previous screen) skips Python entirely.
                let previewPaths = capturedEvent.previewMediaPaths
                let daysToProcess: [DayName] = onlyDay.map { [$0] } ?? DayName.allCases

                var daysNeedingPython: [String] = []
                var copiedURLs: [URL] = []

                for day in daysToProcess {
                    let hasContent = (capturedEvent.weekResult?[day] != nil)
                        || (day == .friday && capturedEvent.days[day.rawValue] != nil)
                    guard hasContent else { continue }

                    if let assets = previewPaths[day.rawValue],
                       !assets.isEmpty,
                       assets.values.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                        // All preview files for this day exist — copy directly, no Python needed
                        let dayDir = folder.appendingPathComponent(day.folderName)
                        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
                        for (_, srcPath) in assets {
                            let src = URL(fileURLWithPath: srcPath)
                            let dest = dayDir.appendingPathComponent(src.lastPathComponent)
                            try? FileManager.default.removeItem(at: dest)
                            if (try? FileManager.default.copyItem(at: src, to: dest)) != nil {
                                copiedURLs.append(dest)
                            }
                        }
                    } else {
                        // Preview missing or files deleted — Python will regenerate this day
                        daysNeedingPython.append(day.rawValue)
                    }
                }

                if daysNeedingPython.isEmpty {
                    // Every asset was copied from preview — skip Python entirely
                } else {
                    // Run Python only for the days that don't have complete previews
                    do {
                        let freshPaths = try await PythonBridge.shared.runMediaGeneration(
                            event: capturedEvent,
                            outputDir: folder.deletingLastPathComponent(),
                            days: daysNeedingPython
                        )
                        // For the Python-regenerated days, overwrite fresh PNGs with any
                        // approved previews that do exist (partial-preview edge case)
                        var overriddenPNGs: [URL] = []
                        for day in daysToProcess where daysNeedingPython.contains(day.rawValue) {
                            guard let assets = previewPaths[day.rawValue] else { continue }
                            let dayDir = folder.appendingPathComponent(day.folderName)
                            for (_, srcPath) in assets where srcPath.hasSuffix(".png") {
                                guard FileManager.default.fileExists(atPath: srcPath) else { continue }
                                let src = URL(fileURLWithPath: srcPath)
                                let dest = dayDir.appendingPathComponent(src.lastPathComponent)
                                try? FileManager.default.removeItem(at: dest)
                                if (try? FileManager.default.copyItem(at: src, to: dest)) != nil {
                                    overriddenPNGs.append(dest)
                                }
                            }
                        }
                        _ = freshPaths  // generated to disk; user opens via Finder
                    } catch {
                        await MainActor.run { mediaGenerationError = error.localizedDescription }
                    }
                }

                await MainActor.run {
                    exportState = .done(folder)
                    NotificationService.shared.notifyExportComplete(eventName: event.name)
                }
            } catch {
                await MainActor.run {
                    destinationRoot.stopAccessingSecurityScopedResource()
                    exportState = .failed(error.localizedDescription)
                }
            }
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

// MARK: - EventExporter

struct EventExporter {
    /// Export one event. Pass `days = nil` (the default) to export the whole week;
    /// pass a specific set to export only those days — in which case the master
    /// CAPTIONS.txt / CHECKLIST.md and Blog are left untouched so they keep
    /// reflecting the last full export.
    static func export(event: Event, to root: URL, days: Set<DayName>? = nil) throws -> URL {
        let folderName = "\(slug(event.org))_\(slug(event.name))_\(event.isoDate)"
        let folder = root.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = event.weekResult
        let isFullExport = (days == nil)

        // Per-day folders — only Wednesday's carousel photos are copied
        // directly by Swift (in the user's assigned order). All other day
        // artifacts — story.png, reels, collage, before/after — come from
        // the Python media generator. Per-day caption.txt / alt_text.txt
        // files are no longer written; the master CAPTIONS.txt at the root
        // is the single source of truth for caption + alt text.
        for day in DayName.allCases {
            if let days, !days.contains(day) { continue }
            guard result?[day] != nil else { continue }
            let dayDir = folder.appendingPathComponent(day.folderName)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

            if day == .wednesday {
                let photos = event.days[day.rawValue]?.photoPaths ?? []
                if !photos.isEmpty {
                    let carouselDir = dayDir.appendingPathComponent("carousel")
                    try? FileManager.default.createDirectory(at: carouselDir, withIntermediateDirectories: true)
                    for (i, photo) in photos.enumerated() {
                        let ext = photo.pathExtension
                        let dest = carouselDir.appendingPathComponent("\(String(format: "%02d", i + 1)).\(ext)")
                        try? FileManager.default.copyItem(at: photo, to: dest)
                    }
                }
            }
        }

        // Blog draft and master CAPTIONS.txt are only written on a full
        // export. Single-day exports leave them untouched so they keep
        // reflecting the last full export.
        if isFullExport {
            if let blog = result?.blog {
                let blogDir = folder.appendingPathComponent("0. Blog")
                try FileManager.default.createDirectory(at: blogDir, withIntermediateDirectories: true)
                let md = "# \(blog.title)\n\n\(blog.body)\n"
                try md.write(to: blogDir.appendingPathComponent("draft.md"),
                             atomically: true, encoding: .utf8)

                for (i, photo) in event.blogPhotoPaths.enumerated() {
                    let ext = photo.pathExtension
                    let dest = blogDir.appendingPathComponent("photo_\(String(format: "%02d", i + 1)).\(ext)")
                    try? FileManager.default.copyItem(at: photo, to: dest)
                }
            }

            let masterCaptions = masterCaptionText(event: event, result: result)
            try masterCaptions.write(to: folder.appendingPathComponent("CAPTIONS.txt"),
                                      atomically: true, encoding: .utf8)
        }

        return folder
    }

    // MARK: - Text generators

    private static func masterCaptionText(event: Event, result: WeekGenerationResult?) -> String {
        var sections: [String] = []
        for day in DayName.allCases {
            guard let cap = result?[day] else { continue }
            var block = "=== \(day.displayName.uppercased()) ===\n\(cap.formatted)"
            if !cap.altTexts.isEmpty {
                let altBody: String
                if day == .wednesday {
                    let photoPaths = event.days[day.rawValue]?.photoPaths ?? []
                    altBody = cap.altTexts.enumerated()
                        .map { idx, altText in
                            // Use the trailing number from the filename (e.g. "-277.jpg" → "277")
                            // and fall back to position if the pattern isn't found.
                            let label: String
                            if idx < photoPaths.count {
                                let stem = photoPaths[idx].deletingPathExtension().lastPathComponent
                                if let dash = stem.range(of: "-", options: .backwards) {
                                    let num = String(stem[dash.upperBound...])
                                    label = num.isEmpty ? "\(idx + 1)" : num
                                } else {
                                    label = "\(idx + 1)"
                                }
                            } else {
                                label = "\(idx + 1)"
                            }
                            return "\(label): \(altText)"
                        }
                        .joined(separator: "\n")
                } else {
                    altBody = cap.altTexts[0]
                }
                block += "\n\nALT TEXT:\n\(altBody)"
            }
            sections.append(block)
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Slug

    static func slug(_ text: String) -> String {
        var result = text.lowercased()
        result = result.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "_",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
