import SwiftUI

struct ExportView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var exportState: ExportState = .ready
    @State private var showingFolderPicker = false

    enum ExportState {
        case ready
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
            BrandBanner(
                icon: "folder",
                message: "Choose a destination folder. PostRoll will create a dated subfolder with all captions, blog draft, and checklist ready to use."
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
        defer { destinationRoot.stopAccessingSecurityScopedResource() }

        do {
            let folder = try EventExporter.export(event: event, to: destinationRoot)
            exportState = .done(folder)
        } catch {
            exportState = .failed(error.localizedDescription)
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
