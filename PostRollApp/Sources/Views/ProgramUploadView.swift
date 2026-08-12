import SwiftUI
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO
import PDFKit

struct ProgramUploadView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(OCRManager.self) private var ocrManager
    @State private var isTargeted = false
    @State private var showingFilePicker = false
    @State private var isImporting = false
    @State private var eventURL: String = ""
    /// Uploads that did not come in whole, shown until Dan either takes the
    /// readable pages or dismisses them (#368).
    @State private var incompleteUploads: [ProgramImport.Incomplete] = []
    /// What the last import brought in, per file, against what the file itself
    /// said it held (#373). Replaced by the next import rather than accumulated:
    /// it is a statement about that import, not about the event.
    @State private var lastImport: [ProgramImport.Imported] = []

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

                // Why OCR sent the event back here, on the screen it landed on
                // (#374). Without this, pressing Run OCR moved Dan to an
                // earlier screen with nothing said, which reads as the app
                // losing his work rather than as a refusal he can act on.
                if let refusal = ocrManager.refusal(for: event.id) {
                    BrandBanner(
                        icon: "exclamationmark.triangle",
                        message: refusal,
                        style: .error,
                        actions: [BrandBannerAction(label: "Dismiss") {
                            ocrManager.clearRefusal(for: event.id)
                        }]
                    )
                }

                // A file that did not come in whole. Shown here, above the
                // pages, because the pages are what it is a statement about.
                ForEach(incompleteUploads) { upload in
                    BrandBanner(
                        icon: "exclamationmark.triangle",
                        message: upload.message,
                        style: .error,
                        actions: actions(for: upload)
                    )
                }

                // Drop zone
                ProgramDropZone(
                    isTargeted: $isTargeted,
                    isImporting: isImporting,
                    imagePaths: event.programImagePaths,
                    lastImport: lastImport,
                    onPickFiles: { showingFilePicker = true },
                    onRemove: removeImage
                )
                .onDrop(of: [.pdf, .image, .fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers)
                }

                HStack {
                    Button("No program") { skipProgram() }
                        .buttonStyle(BrandOutlineButtonStyle())
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
                    let copied = Self.permanentCopy(of: url)
                    Task { @MainActor in
                        switch copied {
                        case .success(let dest):
                            self.appendFiles([dest])
                        case .failure(let error):
                            // A dropped page that never landed used to vanish
                            // here without a word, which is the same silence
                            // #368 is about.
                            self.report(fileName: url.lastPathComponent,
                                        failure: .couldNotStoreFile(reason: error.localizedDescription))
                        }
                    }
                }
            }
        }
        return true
    }

    /// Accepts both image URLs and PDFs. PDFs are rasterised page-by-page to PNG.
    /// Image files are copied into ~/Documents/PostRoll/programs/ so the stored
    /// path stays valid even if the user later moves or deletes the source.
    ///
    /// A file that did not come in whole adds nothing and is reported instead:
    /// program OCR reads `programImagePaths`, so a short list there becomes the
    /// program (#368).
    private func appendFiles(_ urls: [URL]) {
        isImporting = true
        Task {
            // Collected first, merged into a LIVE read below. Reading the event
            // before these awaits and writing it back afterwards was the worst
            // version of #103: the async gap guarantees the snapshot is stale,
            // so anything saved while the import ran was reverted.
            var uploads: [ProgramImport.Upload] = []
            for url in urls {
                let result = await Task.detached(priority: .userInitiated) {
                    Self.importFile(at: url)
                }.value
                uploads.append(ProgramImport.Upload(source: url, result: result))
            }
            let plan = ProgramImport.plan(for: uploads)
            await MainActor.run {
                addPages(plan.pagesToAdd)
                incompleteUploads.append(contentsOf: plan.incomplete)
                lastImport = plan.imported
                clearNotesForFilesNowWhole(plan)
                isImporting = false
            }
        }
    }

    /// One uploaded file's outcome. A PDF is rasterised page by page; anything
    /// else is copied into the program folder. Both report a failure rather
    /// than returning a path to something that is not there: the copy used to
    /// fall back to the source URL, leaving the event pointing outside
    /// PostRoll's own storage at a file the sweep cannot protect.
    private nonisolated static func importFile(at url: URL) -> ProgramImport.Rasterisation {
        if url.pathExtension.lowercased() == "pdf" {
            return ProgramPDFBuilder.rasterise(pdfAt: url, into: AppPaths.programsDir)
        }
        switch permanentCopy(of: url) {
        case .success(let stored):
            return ProgramImport.Rasterisation(pages: [stored])
        case .failure(let error):
            return ProgramImport.Rasterisation(
                failures: [.couldNotStoreFile(reason: error.localizedDescription)]
            )
        }
    }

    /// Merges pages into the LIVE event, never a captured snapshot (#103).
    private func addPages(_ pages: [URL]) {
        guard !pages.isEmpty,
              var ev = appState.events.first(where: { $0.id == event.id }) else { return }
        for page in pages where !ev.programImagePaths.contains(page) {
            ev.programImagePaths.append(page)
        }
        appState.updateEvent(ev)
        // The refusal was about the pages as they were. Changing them makes it
        // a statement about a set that no longer exists, and a reason shown
        // after it stopped being true is worse than none.
        ocrManager.clearRefusal(for: event.id)
    }

    /// The way forward from a file that came in short. Refusing it is the
    /// default, not a wall: a page that is genuinely damaged in the source PDF
    /// must not make the rest of the program unusable, so Dan can take the
    /// readable pages knowing which one is missing (L54).
    private func actions(for upload: ProgramImport.Incomplete) -> [BrandBannerAction] {
        var actions: [BrandBannerAction] = []
        if !upload.pagesThatWorked.isEmpty {
            let count = upload.pagesThatWorked.count
            actions.append(BrandBannerAction(
                label: "Import the \(count) page\(count == 1 ? "" : "s") that worked"
            ) {
                accept(upload)
                dismiss(upload)
            })
        }
        actions.append(BrandBannerAction(label: "Dismiss") { dismiss(upload) })
        return actions
    }

    /// Takes the readable pages of a program that did not come in whole, and
    /// records that this is what happened. The record is the point: this is the
    /// one route by which a short program legitimately becomes the program, so
    /// it is the one place the shortfall would otherwise vanish (#378).
    private func accept(_ upload: ProgramImport.Incomplete) {
        addPages(upload.pagesThatWorked)
        guard var ev = appState.events.first(where: { $0.id == event.id }) else { return }
        ev.partialProgramNotes[upload.fileName] = ProgramShortfall.acceptanceNote(for: upload)
        appState.updateEvent(ev)
    }

    /// A file that has since come in whole is no longer a partial program, so
    /// its record goes. A re-import that failed the same way leaves it just as
    /// short, so that record stays.
    private func clearNotesForFilesNowWhole(_ plan: ProgramImport.Plan) {
        guard var ev = appState.events.first(where: { $0.id == event.id }) else { return }
        let kept = ProgramShortfall.notes(ev.partialProgramNotes, clearedBy: plan)
        guard kept != ev.partialProgramNotes else { return }
        ev.partialProgramNotes = kept
        appState.updateEvent(ev)
    }

    private func dismiss(_ upload: ProgramImport.Incomplete) {
        incompleteUploads.removeAll { $0.id == upload.id }
    }

    /// Surfaces a file that produced no pages at all.
    private func report(fileName: String, failure: ProgramImport.Failure) {
        incompleteUploads.append(ProgramImport.Incomplete(
            fileName: fileName, pagesThatWorked: [], failures: [failure]
        ))
    }

    private func removeImage(_ url: URL) {
        // Read the live event from AppState: a captured `event` can be stale if
        // the user removes pages in quick succession. Remove by identity (URL),
        // never by index, so the right page goes regardless of render order.
        guard var ev = appState.events.first(where: { $0.id == event.id }) else { return }
        ev.programImagePaths.removeAll { $0 == url }
        appState.updateEvent(ev)
        ocrManager.clearRefusal(for: event.id)
        // Both notices describe the pages as they were. Removing one makes each
        // a statement about a set that no longer exists.
        lastImport = []
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

    /// Copies an uploaded image into the program folder, reporting why it could
    /// not rather than returning nil: the caller has to say what went wrong.
    private nonisolated static func permanentCopy(of url: URL) -> Result<URL, Error> {
        let dir = AppPaths.programsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { return .success(dest) }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return .success(dest)
        } catch {
            return .failure(error)
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

            StageStepBar(event: event)
                .padding(.top, 8)

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

// MARK: - Drop Zone

private struct ProgramDropZone: View {
    @Binding var isTargeted: Bool
    let isImporting: Bool
    let imagePaths: [URL]
    /// What the last import brought in per file, against what each file said it
    /// held. Empty on a screen Dan has merely returned to.
    let lastImport: [ProgramImport.Imported]
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

            // What each file brought in against what it said it held, so a PDF
            // that is itself short (or simply the wrong file) is visible by eye.
            // Nothing in the app can detect that: only Dan knows how many pages
            // the program in his hand has (#373).
            ForEach(lastImport) { file in
                Text(file.summary)
                    .font(.light(11))
                    .foregroundStyle(Color.warmMid.opacity(0.8))
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


// MARK: - Stage step bar

/// The event's screens, reachable directly (#183).
///
/// Before this, `EventDetailView` routed purely on `event.stage`, so exactly
/// one screen was open at a time and moving between them meant walking the back
/// button one screen at a time, each click writing a new stage as a side
/// effect. Getting from Export back to the Thursday reel was two clicks and two
/// stage writes, with nothing saying where you were in the sequence.
///
/// `event.stage` is still the router: this sets it directly instead of stepping
/// through it. What can be opened, and why not when it cannot, is
/// `StageNavigation`, which is pure and tested on its own.
struct StageStepBar: View {
    let event: Event
    @Environment(AppState.self) private var appState

    private var here: EventStage { StageNavigation.step(containing: event.stage) }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(StageNavigation.steps.enumerated()), id: \.element) { index, stage in
                if index > 0 {
                    Rectangle()
                        .fill(Color.creamEdge)
                        .frame(width: 12, height: 1)
                }
                step(stage)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func step(_ stage: EventStage) -> some View {
        let isHere = stage == here
        let blocked = StageNavigation.blockedReason(for: stage, in: event)
        let done = StageNavigation.isBehind(stage, current: event.stage)

        Button {
            guard blocked == nil, !isHere else { return }
            // The LIVE record, never the captured prop: a stage change applied
            // to this screen's snapshot writes back over everything saved
            // since it opened (#103).
            if let ev = EventStageTransition.applying(stage, toEventWithID: event.id,
                                                     in: appState.events) {
                appState.updateEvent(ev)
            }
        } label: {
            Text(StageNavigation.title(stage))
                .font(.system(size: 9, weight: isHere ? .semibold : .regular))
                .tracking(0.6)
                .foregroundStyle(colour(isHere: isHere, done: done, blocked: blocked != nil))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(isHere ? Color.roseGold.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(blocked != nil || isHere)
        // The refusal says which work is missing rather than leaving a control
        // that greys out and explains nothing.
        .help(blocked ?? (isHere ? "You are here" : "Go to \(StageNavigation.title(stage))"))
    }

    private func colour(isHere: Bool, done: Bool, blocked: Bool) -> Color {
        if isHere { return Color.roseGold }
        if blocked { return Color.warmMid.opacity(0.35) }
        return done ? Color.warmMid : Color.warmMid.opacity(0.7)
    }
}
