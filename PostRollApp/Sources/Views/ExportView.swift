import SwiftUI

struct ExportView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var exportState: ExportState = .ready
    @State private var showingFolderPicker = false
    @State private var exportedFolder: URL? = nil   // set after text export so media gen can use it

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

            HStack {
                Spacer()
                Button("Choose Destination…") { showingFolderPicker = true }
                    .buttonStyle(BrandButtonStyle())
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
            Text("Stories + collage: ~30s. Reels: 2–5 min each.")
                .font(.light(12))
                .foregroundStyle(Color.warmMid)

            // Let user skip media generation if they just want the text
            Button("Skip — use text export only") {
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

            HStack(spacing: Spacing.md) {
                Button("Open in Finder") { NSWorkspace.shared.open(folder) }
                    .buttonStyle(BrandButtonStyle())
                Button("Export Again") { exportState = .ready }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.roseGold)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            BrandBanner(icon: "exclamationmark.triangle", message: message)
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
                    try await PythonBridge.shared.runMediaGeneration(
                        event: event,
                        outputDir: folder.deletingLastPathComponent()
                    )
                } catch {
                    // Media generation failure is non-fatal — text export already succeeded
                    print("[ExportView] media generation failed (non-fatal): \(error.localizedDescription)")
                }

                await MainActor.run { exportState = .done(folder) }
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
        guard let r = result else { return [] }
        return DayName.allCases.filter { r[$0] != nil }
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
            Text(caption?.caption.prefix(60).appending(caption?.caption.count ?? 0 > 60 ? "…" : "") ?? "—")
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

            // Copy photos
            let photos = event.days[day.rawValue]?.photoPaths ?? []
            for (i, photo) in photos.enumerated() {
                let ext = photo.pathExtension
                let dest = dayDir.appendingPathComponent("photo_\(String(format: "%02d", i + 1)).\(ext)")
                try? FileManager.default.copyItem(at: photo, to: dest)
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
        let collabs = performers.compactMap { $0.name.isEmpty ? nil : $0.name }.joined(separator: ", ")
        let collabLine = collabs.isEmpty ? "(no performers listed)" : collabs

        var lines: [String] = [
            "# PostRoll — \(event.name) (\(event.isoDate))",
            "",
        ]

        for day in DayName.allCases {
            guard !(event.days[day.rawValue]?.photoPaths.isEmpty ?? true) else { continue }
            lines += [
                "### \(day.displayName)",
                "",
                "- [ ] Post to Instagram, Facebook, TikTok, Pinterest, Bluesky",
                "- [ ] Add as Instagram collaborators: \(collabLine)",
                "- [ ] Tag story with performer and venue accounts",
                "",
            ]
        }

        lines += [
            "## Post-Week",
            "",
            "- [ ] Add Instagram post link to one-year follow-up",
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
