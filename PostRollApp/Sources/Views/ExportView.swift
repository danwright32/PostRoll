import SwiftUI

struct ExportView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var exportState: ExportState = .ready
    @State private var showingFolderPicker = false
    @State private var exportedFolder: URL? = nil   // set after text export so media gen can use it
    @State private var lastExportFolder: URL? = nil
    @State private var mediaGenerationError: String? = nil

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
                runExport(to: dest)
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

            ExportSummaryCard(event: event, result: result)
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

    private func runExport(to destinationRoot: URL) {
        guard destinationRoot.startAccessingSecurityScopedResource() else {
            exportState = .failed("Could not access the selected folder.")
            return
        }

        UserDefaults.standard.set(destinationRoot.path, forKey: "lastExportFolder")
        lastExportFolder = destinationRoot
        exportState = .exportingText

        Task {
            do {
                // Step 1: text export (fast, on background thread)
                let folder = try await Task.detached {
                    defer { destinationRoot.stopAccessingSecurityScopedResource() }
                    return try EventExporter.export(event: self.event, to: destinationRoot)
                }.value

                // Step 2: generate stories + collage via Python
                await MainActor.run { exportState = .generatingMedia(folder) }
                do {
                    let imagePaths = try await PythonBridge.shared.runMediaGeneration(
                        event: event,
                        outputDir: folder.deletingLastPathComponent()
                    )

                    // Overwrite freshly-generated static PNGs with the exact approved
                    // preview files. This guarantees the exported graphics match what
                    // was reviewed, pixel-for-pixel. Videos (reels) come from the
                    // fresh run above and are left untouched.
                    var approvedPNGPaths: [URL] = []
                    if !event.previewMediaPaths.isEmpty {
                        let destSlug = "\(EventExporter.slug(event.org))_\(EventExporter.slug(event.name))_\(event.isoDate)"
                        let mediaBase = folder.deletingLastPathComponent().appendingPathComponent(destSlug)
                        for (dayKey, assetPaths) in event.previewMediaPaths {
                            for (_, srcPath) in assetPaths {
                                guard srcPath.hasSuffix(".png"),
                                      FileManager.default.fileExists(atPath: srcPath) else { continue }
                                let src = URL(fileURLWithPath: srcPath)
                                let dayDir = mediaBase.appendingPathComponent(dayKey)
                                let dest = dayDir.appendingPathComponent(src.lastPathComponent)
                                try? FileManager.default.removeItem(at: dest)
                                if (try? FileManager.default.copyItem(at: src, to: dest)) != nil {
                                    approvedPNGPaths.append(dest)
                                }
                            }
                        }
                    }

                    // Open the approved PNGs in Preview (fall back to fresh ones if no preview was done)
                    let pngsToOpen = approvedPNGPaths.isEmpty ? imagePaths : approvedPNGPaths
                    if !pngsToOpen.isEmpty {
                        let previewApp = URL(fileURLWithPath: "/System/Applications/Preview.app")
                        if FileManager.default.fileExists(atPath: previewApp.path) {
                            NSWorkspace.shared.open(
                                pngsToOpen,
                                withApplicationAt: previewApp,
                                configuration: .init(),
                                completionHandler: nil
                            )
                        }
                    }
                } catch {
                    // Media generation failure is non-fatal — text export already succeeded
                    await MainActor.run { mediaGenerationError = error.localizedDescription }
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
                ExportDayRow(day: day, caption: result?[day])
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
    static func export(event: Event, to root: URL) throws -> URL {
        let folderName = "\(slug(event.org))_\(slug(event.name))_\(event.isoDate)"
        let folder = root.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = event.weekResult

        // Per-day folders
        for day in DayName.allCases {
            guard let caption = result?[day] else { continue }
            let dayDir = folder.appendingPathComponent(day.rawValue)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

            // caption.txt
            let captionText = caption.formatted
            try captionText.write(to: dayDir.appendingPathComponent("caption.txt"),
                                  atomically: true, encoding: .utf8)

            // alt_texts.txt
            if !caption.altTexts.isEmpty {
                let altBody = caption.altTexts.enumerated()
                    .map { "Photo \($0.offset + 1): \($0.element)" }
                    .joined(separator: "\n")
                try altBody.write(to: dayDir.appendingPathComponent("alt_texts.txt"),
                                  atomically: true, encoding: .utf8)
            }

            // Copy photos — day-specific rules:
            // • Tuesday/Thursday: reel is the deliverable; source photos not copied.
            // • Wednesday: photos go in a carousel/ subfolder (10 for the carousel post).
            // • All other days: copy all assigned photos flat.
            let photos = event.days[day.rawValue]?.photoPaths ?? []
            switch day {
            case .tuesday, .thursday:
                break  // reel handles these days; no need to copy source photos
            case .wednesday:
                if !photos.isEmpty {
                    let carouselDir = dayDir.appendingPathComponent("carousel")
                    try? FileManager.default.createDirectory(at: carouselDir, withIntermediateDirectories: true)
                    for (i, photo) in photos.enumerated() {
                        let ext = photo.pathExtension
                        let dest = carouselDir.appendingPathComponent("\(String(format: "%02d", i + 1)).\(ext)")
                        try? FileManager.default.copyItem(at: photo, to: dest)
                    }
                }
            default:
                for (i, photo) in photos.enumerated() {
                    let ext = photo.pathExtension
                    let dest = dayDir.appendingPathComponent("photo_\(String(format: "%02d", i + 1)).\(ext)")
                    try? FileManager.default.copyItem(at: photo, to: dest)
                }
            }
        }

        // Blog draft
        if let blog = result?.blog {
            let blogDir = folder.appendingPathComponent("blog")
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

        // Master CAPTIONS.txt
        let masterCaptions = masterCaptionText(event: event, result: result)
        try masterCaptions.write(to: folder.appendingPathComponent("CAPTIONS.txt"),
                                  atomically: true, encoding: .utf8)

        // CHECKLIST.md
        let checklist = checklistText(event: event)
        try checklist.write(to: folder.appendingPathComponent("CHECKLIST.md"),
                             atomically: true, encoding: .utf8)

        return folder
    }

    // MARK: - Text generators

    private static func masterCaptionText(event: Event, result: WeekGenerationResult?) -> String {
        var sections: [String] = []
        for day in DayName.allCases {
            guard let cap = result?[day] else { continue }
            sections.append("=== \(day.displayName.uppercased()) ===\n\(cap.formatted)")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func checklistText(event: Event) -> String {
        let performers = event.ocrResult?.performers ?? []
        let fallbackCollabs = performers.compactMap { $0.name.isEmpty ? nil : $0.name }.joined(separator: ", ")
        let fallbackCollabLine = fallbackCollabs.isEmpty ? "(no performers listed)" : fallbackCollabs

        var lines: [String] = [
            "# PostRoll: \(event.name) (\(event.isoDate))",
            "",
        ]

        for day in DayName.allCases {
            let pd = event.days[day.rawValue]
            guard !(pd?.photoPaths.isEmpty ?? true) else { continue }

            // Prefer day-specific handles + names; fall back to OCR performers
            let handles = pd?.tagHandles ?? []
            let names   = pd?.nameMentions ?? []
            let collabParts = handles + names
            let collabLine = collabParts.isEmpty ? fallbackCollabLine : collabParts.joined(separator: ", ")

            lines += ["### \(day.displayName)", ""]

            switch day {
            case .sunday, .monday:
                lines += [
                    "- [ ] Post photo + caption to Instagram, Facebook, TikTok, Pinterest, Bluesky",
                    "- [ ] Add as Instagram collaborators: \(collabLine)",
                    "- [ ] Post \(day.rawValue)/story.png as story to Instagram + Facebook",
                    "- [ ] Tag story with performer and venue accounts",
                ]
            case .tuesday:
                let hasReel = pd?.screenRecordingPath != nil
                    && pd?.rawPhotoPath != nil
                    && pd?.editedPhotoPath != nil
                if hasReel {
                    lines += [
                        "- [ ] Post speed edit reel + caption to Instagram, Facebook, TikTok, Pinterest, Bluesky",
                        "- [ ] Add as Instagram collaborators: \(collabLine)",
                        "- [ ] Post tuesday/before_after.png as story to Instagram + Facebook",
                        "- [ ] Tag story with performer and venue accounts",
                    ]
                } else {
                    lines += [
                        "- [ ] Post photo + caption to Instagram, Facebook, TikTok, Pinterest, Bluesky",
                        "- [ ] Add as Instagram collaborators: \(collabLine)",
                        "- [ ] Post tuesday/story.png as story to Instagram + Facebook",
                        "- [ ] Tag story with performer and venue accounts",
                    ]
                }
            case .wednesday:
                lines += [
                    "- [ ] Post carousel (10 photos) + caption to Instagram, Facebook, TikTok, Pinterest, Bluesky",
                    "- [ ] Add as Instagram collaborators: \(collabLine)",
                    "- [ ] Post wednesday/collage.png as story to Instagram + Facebook",
                    "- [ ] Tag story with performer and venue accounts",
                ]
            case .thursday:
                lines += [
                    "- [ ] Post scroll reel + caption to Instagram, Facebook, TikTok, Pinterest, Bluesky",
                    "- [ ] Add as Instagram collaborators: \(collabLine)",
                ]
            case .friday:
                let hasBeforeAfter = pd?.rawPhotoPath != nil && pd?.editedPhotoPath != nil
                lines += [
                    "- [ ] Post friday/\(hasBeforeAfter ? "before_after" : "story").png as story to Instagram + Facebook",
                    "- [ ] Save story to Instagram highlights",
                ]
            }

            lines += [""]
        }

        lines += [
            "## Post-Week",
            "",
            "- [ ] Add Instagram post link to OmniFocus one-year follow-up",
            "- [ ] Promote Tuesday reel to followers",
            "",
        ]

        return lines.joined(separator: "\n")
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
