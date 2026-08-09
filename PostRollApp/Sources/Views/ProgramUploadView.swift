import SwiftUI
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO
import PDFKit

struct ProgramUploadView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @State private var isTargeted = false
    @State private var showingFilePicker = false
    @State private var isImporting = false
    @State private var eventURL: String = ""

    init(event: Event) {
        self.event = event
        _eventURL = State(initialValue: event.eventURL)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {

                // Event header
                EventHeader(event: event, subtitle: "Upload Program")

                // Reminder banner — brand-toned, not generic orange
                BrandBanner(
                    icon: "arrow.down.circle",
                    message: "Download the program from your browser first. Salesforce ticketing sites block direct downloads. For faster OCR, remove bio pages and ads — cast list and program pages only."
                )

                // Optional event page URL — used by caption + blog generators
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("EVENT PAGE URL (OPTIONAL)")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(Color.roseGold)
                    TextField("https://dciny.org/events/…", text: $eventURL)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmDark)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.xs)
                                .fill(Color.creamDeep)
                                .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                                    .strokeBorder(Color.creamEdge, lineWidth: 1))
                        )
                        .onChange(of: eventURL) { _, url in
                            // Live read, never the captured prop (#103).
                            guard var ev = appState.events.first(where: { $0.id == event.id })
                            else { return }
                            ev.eventURL = url
                            appState.updateEvent(ev)
                        }
                }

                // Drop zone
                ProgramDropZone(
                    isTargeted: $isTargeted,
                    isImporting: isImporting,
                    imagePaths: event.programImagePaths,
                    onPickFiles: { showingFilePicker = true },
                    onRemove: removeImage
                )
                .onDrop(of: [.pdf, .image, .fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers)
                }

                HStack {
                    Button("No program") { skipProgram() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmMid)
                    Spacer()
                    if !event.programImagePaths.isEmpty && !isImporting {
                        Button("Run OCR") { advanceToOCR() }
                            .buttonStyle(BrandButtonStyle())
                    }
                }
            }
            .padding(Spacing.xl)
        }
        .background(Color.cream)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { appendFiles(urls) }
        }
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in self.appendFiles([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    guard let url else { return }
                    // Copy synchronously here — the temp URL is invalidated as soon
                    // as this closure returns, so the copy can't be deferred.
                    guard let dest = Self.permanentCopy(of: url) else { return }
                    Task { @MainActor in self.appendFiles([dest]) }
                }
            }
        }
        return true
    }

    /// Accepts both image URLs and PDFs. PDFs are rasterised page-by-page to PNG.
    /// Image files are copied into ~/Documents/PostRoll/programs/ so the stored
    /// path stays valid even if the user later moves or deletes the source.
    private func appendFiles(_ urls: [URL]) {
        isImporting = true
        Task {
            // Collected first, merged into a LIVE read below. Reading the event
            // before these awaits and writing it back afterwards was the worst
            // version of #103: the async gap guarantees the snapshot is stale,
            // so anything saved while the import ran was reverted.
            var added: [URL] = []
            for url in urls {
                if url.pathExtension.lowercased() == "pdf" {
                    let pages = await Task.detached(priority: .userInitiated) {
                        Self.rasterisePDF(at: url)
                    }.value
                    for page in pages where !added.contains(page) {
                        added.append(page)
                    }
                } else {
                    let stored = await Task.detached(priority: .userInitiated) {
                        Self.permanentCopy(of: url) ?? url
                    }.value
                    if !added.contains(stored) {
                        added.append(stored)
                    }
                }
            }
            await MainActor.run {
                if var ev = appState.events.first(where: { $0.id == event.id }) {
                    for page in added where !ev.programImagePaths.contains(page) {
                        ev.programImagePaths.append(page)
                    }
                    appState.updateEvent(ev)
                }
                isImporting = false
            }
        }
    }

    /// Rasterises each PDF page to a 2× PNG in ~/Documents/PostRoll/programs/
    /// and retains the original PDF alongside them, so the downloadable program
    /// keeps born-digital text. See `ProgramPDFBuilder.rasterise`.
    private nonisolated static func rasterisePDF(at url: URL) -> [URL] {
        ProgramPDFBuilder.rasterise(pdfAt: url, into: AppPaths.programsDir)
    }

    private func removeImage(_ url: URL) {
        // Read the live event from AppState: a captured `event` can be stale if
        // the user removes pages in quick succession. Remove by identity (URL),
        // never by index, so the right page goes regardless of render order.
        guard var ev = appState.events.first(where: { $0.id == event.id }) else { return }
        ev.programImagePaths.removeAll { $0 == url }
        appState.updateEvent(ev)
    }

    private func advanceToOCR() {
        // Live read, never the captured prop, which is a snapshot from
        // when this screen was built and reverts anything saved since (#103).
        guard let ev = EventStageTransition.applying(
                .programUploaded, toEventWithID: event.id, in: appState.events)
        else { return }
        appState.updateEvent(ev)
        // Baked from the same live event that was just stored, so the bake and
        // the record agree on which pages exist.
        buildProgramPDF(for: ev)
    }

    /// Bakes the whole program into one searchable PDF (OCR text layer) and
    /// stores it on the event. Done here, while the page scans are freshly
    /// imported, because ArchiveCleanup reclaims those scans 60 days after
    /// export — after which the PDF is the only copy of the program left.
    ///
    /// Owned by ProgramPDFBakery rather than a detached Task started here: a
    /// failure has to be recorded rather than dropped by a `try?`, and a second
    /// bake must not start while one is in flight (#80).
    private func buildProgramPDF(for ev: Event) {
        ProgramPDFBakery.shared.bake(event: ev, appState: appState)
    }

    private func skipProgram() {
        // Live read: the captured prop is a snapshot from when this screen was
        // built, and writing it back reverts anything saved since (#103).
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.ocrResult = OCRResult()
        ev.ocrReviewDone = true
        ev.stage = .ocrDone
        appState.updateEvent(ev)
    }

    private nonisolated static func permanentCopy(of url: URL) -> URL? {
        let dir = AppPaths.programsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}

// MARK: - EventHeader (reused across stages)

struct EventHeader: View {
    let event: Event
    let subtitle: String
    @Environment(AppState.self) private var appState
    @State private var isEditing = false
    @State private var editName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isEditing {
                TextField("Event name", text: $editName, onCommit: commitRename)
                    .font(.signPainter(28))
                    .foregroundStyle(Color.warmDark)
                    .textFieldStyle(.plain)
                    .onExitCommand { isEditing = false }
            } else {
                HStack(spacing: 6) {
                    Text(event.name)
                        .font(.signPainter(28))
                        .foregroundStyle(Color.warmDark)
                    Button {
                        editName = event.name
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.warmMid.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Rename event")
                }
            }
            Text(subtitle.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(Color.roseGold)
            RoseGoldDivider()
                .padding(.top, 6)
        }
    }

    private func commitRename() {
        let trimmed = editName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty,
           var ev = appState.events.first(where: { $0.id == event.id }) {
            // Live read (#103): renaming must not revert other saved work.
            ev.name = trimmed
            appState.updateEvent(ev)
        }
        isEditing = false
    }
}

// MARK: - BrandBanner

enum BrandBannerStyle {
    case info     // instructional — roseGold border, subtle bg
    case warning  // action needed — heavier roseGold border
    case error    // something wrong — roseDeep border
}

/// One escape-hatch action rendered as a button below a BrandBanner's
/// message (e.g. the Friday "< 3 usable clips" banner's "Import more
/// clips" / "Skip clips, keep story-only" pair, #135).
struct BrandBannerAction: Identifiable {
    let id = UUID()
    let label: String
    let action: () -> Void
}

struct BrandBanner: View {
    let icon: String
    let message: String
    var style: BrandBannerStyle = .info
    /// Optional action buttons shown below the message. Empty by default so
    /// every existing call site is unaffected.
    var actions: [BrandBannerAction] = []

    private var borderColor: Color {
        switch style {
        case .info:    return Color.roseGold.opacity(0.4)
        case .warning: return Color.roseGold.opacity(0.75)
        case .error:   return Color.roseDeep
        }
    }
    private var borderWidth: CGFloat {
        switch style {
        case .info:    return 2
        case .warning: return 3
        case .error:   return 3
        }
    }
    private var bgColor: Color {
        switch style {
        case .info:    return Color.roseGold.opacity(0.07)
        case .warning: return Color.roseGold.opacity(0.10)
        case .error:   return Color.roseDeep.opacity(0.08)
        }
    }
    private var iconColor: Color {
        switch style {
        case .info:    return Color.roseGold
        case .warning: return Color.roseGold
        case .error:   return Color.roseDeep
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmMid)
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: Spacing.md) {
                        ForEach(actions) { action in
                            Button(action.label, action: action.action)
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.roseGold)
                        }
                    }
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bgColor)
        .overlay(
            Rectangle()
                .fill(borderColor)
                .frame(width: borderWidth),
            alignment: .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}

// MARK: - Stage Back Button (reused across stages)

struct StageBackButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Color.warmMid)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Drop Zone

private struct ProgramDropZone: View {
    @Binding var isTargeted: Bool
    let isImporting: Bool
    let imagePaths: [URL]
    let onPickFiles: () -> Void
    let onRemove: (URL) -> Void

    var body: some View {
        if isImporting {
            importingState
        } else if imagePaths.isEmpty {
            emptyState
        } else {
            filledState
        }
    }

    private var importingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
                .tint(Color.roseGold)
            Text("Importing…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.warmDark)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180)
        .background(Color.creamDeep)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Color.roseGold.opacity(0.3),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 40))
                .foregroundStyle(Color.roseGold.opacity(0.5))
            VStack(spacing: 4) {
                Text("Drop program photos here")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.warmDark)
                Text("PDF · JPEG · PNG · HEIC")
                    .font(.light(11))
                    .foregroundStyle(Color.warmMid)
            }
            Button("Choose Files…", action: onPickFiles)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.roseGold)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180)
        .background(Color.creamDeep)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(
                    isTargeted ? Color.roseGold : Color.roseGold.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
    }

    private var filledState: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("\(imagePaths.count) page\(imagePaths.count == 1 ? "" : "s")")
                    .font(.light(12))
                    .foregroundStyle(Color.warmMid)
                Spacer()
                Button("Add more…", action: onPickFiles)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.roseGold)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: Spacing.sm) {
                // Identify each thumbnail by its URL, not its index. Index identity
                // makes SwiftUI think the last page was removed on any deletion.
                ForEach(imagePaths, id: \.self) { url in
                    ProgramThumbnail(url: url) {
                        onRemove(url)
                    }
                }
            }
        }
    }
}

private struct ProgramThumbnail: View {
    let url: URL
    let onRemove: () -> Void

    private enum LoadState { case loading, loaded(NSImage), missing }
    @State private var state: LoadState = .loading

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch state {
                case .loading:
                    Color.creamDeep
                        .overlay { ProgressView().controlSize(.small).tint(Color.roseGold) }
                case .loaded(let image):
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                case .missing:
                    Color.creamDeep.overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.roseDeep)
                            Text("File missing")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.warmMid)
                        }
                    }
                }
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(Color.creamEdge, lineWidth: 0.5)
            )

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.cream, Color.warmDark.opacity(0.7))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .padding(4)
        }
        .task {
            let captured = url
            let result: LoadState = await Task.detached {
                guard FileManager.default.fileExists(atPath: captured.path) else { return .missing }
                if let img = NSImage(contentsOf: captured) { return .loaded(img) }
                return .missing
            }.value
            state = result
        }
    }
}
