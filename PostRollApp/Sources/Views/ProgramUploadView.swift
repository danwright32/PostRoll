import SwiftUI
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO

struct ProgramUploadView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @State private var isTargeted = false
    @State private var showingFilePicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {

                // Event header
                EventHeader(event: event, subtitle: "Upload Program")

                // Reminder banner — brand-toned, not generic orange
                BrandBanner(
                    icon: "arrow.down.circle",
                    message: "Download the program from your browser first. Salesforce ticketing sites block direct downloads."
                )

                // Drop zone
                ProgramDropZone(
                    isTargeted: $isTargeted,
                    imagePaths: event.programImagePaths,
                    onPickFiles: { showingFilePicker = true },
                    onRemove: removeImages
                )
                .onDrop(of: [.pdf, .image, .fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers)
                }

                if !event.programImagePaths.isEmpty {
                    HStack {
                        Spacer()
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
                    let captured = url
                    Task { @MainActor in
                        let dest = self.permanentCopy(of: captured)
                        self.appendFiles([dest ?? captured])
                    }
                }
            }
        }
        return true
    }

    /// Accepts both image URLs and PDFs. PDFs are rasterised page-by-page to PNG.
    private func appendFiles(_ urls: [URL]) {
        Task {
            var ev = event
            for url in urls {
                if url.pathExtension.lowercased() == "pdf" {
                    let pages = await Task.detached(priority: .userInitiated) {
                        Self.rasterisePDF(at: url)
                    }.value
                    for page in pages where !ev.programImagePaths.contains(page) {
                        ev.programImagePaths.append(page)
                    }
                } else if !ev.programImagePaths.contains(url) {
                    ev.programImagePaths.append(url)
                }
            }
            await MainActor.run { appState.updateEvent(ev) }
        }
    }

    /// Renders each PDF page to a 2× PNG in ~/Documents/PostRoll/programs/.
    /// Uses CoreGraphics throughout — safe to call from a non-main-actor context.
    private nonisolated static func rasterisePDF(at url: URL) -> [URL] {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return [] }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/PostRoll/programs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        var results: [URL] = []

        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            let box   = page.getBoxRect(.mediaBox)
            let scale = CGFloat(2)
            let w     = Int(box.width  * scale)
            let h     = Int(box.height * scale)

            let cs   = CGColorSpaceCreateDeviceRGB()
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: cs, bitmapInfo: info.rawValue) else { continue }

            // White background, then flip-and-scale so PDF draws right-side up
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.drawPDFPage(page)

            guard let img = ctx.makeImage() else { continue }
            let dest = dir.appendingPathComponent("\(stem)_p\(i).png")
            if let dst = CGImageDestinationCreateWithURL(dest as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dst, img, nil)
                if CGImageDestinationFinalize(dst) { results.append(dest) }
            }
        }
        return results
    }

    private func removeImages(at offsets: IndexSet) {
        var ev = event
        ev.programImagePaths.remove(atOffsets: offsets)
        appState.updateEvent(ev)
    }

    private func advanceToOCR() {
        var ev = event
        ev.stage = .programUploaded
        appState.updateEvent(ev)
    }

    private func permanentCopy(of url: URL) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/PostRoll/programs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        return dest
    }
}

// MARK: - EventHeader (reused across stages)

struct EventHeader: View {
    let event: Event
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.name)
                .font(.signPainter(28))
                .foregroundStyle(Color.warmDark)
            Text(subtitle.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(Color.roseGold)
            RoseGoldDivider()
                .padding(.top, 6)
        }
    }
}

// MARK: - BrandBanner

struct BrandBanner: View {
    let icon: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color.roseGold)
                .frame(width: 24)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.warmMid)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.roseGold.opacity(0.07))
        .overlay(
            Rectangle()
                .fill(Color.roseGold.opacity(0.4))
                .frame(width: 2),
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
    let imagePaths: [URL]
    let onPickFiles: () -> Void
    let onRemove: (IndexSet) -> Void

    var body: some View {
        if imagePaths.isEmpty {
            emptyState
        } else {
            filledState
        }
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
                ForEach(imagePaths.indices, id: \.self) { i in
                    ProgramThumbnail(url: imagePaths[i]) {
                        onRemove(IndexSet(integer: i))
                    }
                }
            }
        }
    }
}

private struct ProgramThumbnail: View {
    let url: URL
    let onRemove: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.creamDeep
                        .overlay { ProgressView().controlSize(.small).tint(Color.roseGold) }
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
        .task { image = await Task.detached { NSImage(contentsOf: url) }.value }
    }
}
