import Foundation
import AppKit
import CoreGraphics
import CoreText
import PDFKit
import Vision

// MARK: - ProgramPDFBuilder

/// Bundles an event's program pages into a single, searchable PDF.
///
/// Program pages are stored on disk as individual image files (PNG/JPG) in
/// `AppPaths.programsDir`. A PDF upload is rasterised to one PNG per page
/// (`<stem>_p<N>.png`) AND the original PDF is retained alongside it as
/// `<stem>.pdf`. So at build time each page is one of two kinds:
///
/// - A rasterised PDF page whose source PDF still exists and carries a real
///   text layer: the original page is embedded verbatim (`drawPDFPage`), which
///   preserves the crisp vector text exactly rather than re-OCRing a raster.
/// - Anything else (a directly uploaded image, or a scanned PDF page with no
///   text): the image is drawn and an invisible Vision OCR text layer is laid
///   over it, the way a document scanner produces a searchable PDF.
///
/// The source PDF is discovered from the page's own filename, so page order and
/// per-page removals are honoured by reading `programImagePaths` — no separate
/// provenance map to keep in sync.
struct ProgramPDFBuilder {
    enum BuildError: LocalizedError {
        case noPages
        case unreadableImage(URL)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noPages:
                return "This event has no program pages to export."
            case .unreadableImage(let url):
                return "Couldn't read program page \"\(url.lastPathComponent)\"."
            case .encodingFailed:
                return "Couldn't assemble the program PDF."
            }
        }
    }

    // MARK: - Filename convention

    /// Name of the PNG written for page `page` (1-based) of a rasterised PDF.
    static func rasterizedPageName(stem: String, page: Int) -> String {
        "\(stem)_p\(page).png"
    }

    /// Name the original PDF is retained under, next to its rasterised pages.
    static func retainedSourceName(stem: String) -> String {
        "\(stem).pdf"
    }

    /// Identity of a page set: the ordered page filenames. A baked program PDF
    /// is stamped with this; when the current pages no longer match (a page was
    /// added, removed, or reordered after the bake), the cache is stale and must
    /// be rebuilt. Filename-based so relocating the data root doesn't invalidate.
    static func fingerprint(of pages: [URL]) -> String {
        pages.map(\.lastPathComponent).joined(separator: "|")
    }

    /// Inverse of `rasterizedPageName`: given a page image, the source PDF and
    /// 1-based page number it came from, when that retained PDF exists on disk.
    static func sourcePDFPage(for pageImage: URL) -> (pdfURL: URL, page: Int)? {
        let name = pageImage.deletingPathExtension().lastPathComponent
        guard let marker = name.range(of: "_p", options: .backwards),
              let page = Int(name[marker.upperBound...]), page >= 1 else { return nil }
        let stem = String(name[..<marker.lowerBound])
        let pdfURL = pageImage.deletingLastPathComponent()
            .appendingPathComponent(retainedSourceName(stem: stem))
        guard FileManager.default.fileExists(atPath: pdfURL.path) else { return nil }
        return (pdfURL, page)
    }

    // MARK: - Build

    /// Build a single searchable PDF from the page images, preserving order.
    /// Each image becomes one page — embedding the original PDF page when it
    /// carries native text, otherwise drawing the image with an OCR text layer.
    /// Throws if the list is empty or a non-PDF-backed page can't be read.
    /// Runs OCR on raster pages, so call it off the main thread.
    static func makePDF(from imagePaths: [URL]) throws -> Data {
        guard !imagePaths.isEmpty else { throw BuildError.noPages }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw BuildError.encodingFailed
        }

        var sourceCache: [String: LoadedPDF?] = [:]
        for url in imagePaths {
            if let source = sourcePDFPage(for: url),
               let pdf = loadedPDF(at: source.pdfURL, cache: &sourceCache),
               pdf.hasText(onPage: source.page),
               let cgPage = pdf.document.page(at: source.page) {
                embedPDFPage(cgPage, into: context)
                continue
            }

            guard let nsImage = NSImage(contentsOf: url),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw BuildError.unreadableImage(url)
            }
            renderImagePage(cgImage, into: context)
        }

        context.closePDF()
        guard data.length > 0 else { throw BuildError.encodingFailed }
        return data as Data
    }

    /// Build the searchable PDF and write it to `destination`, returning it.
    /// Used to pre-generate the downloadable program at upload time, while the
    /// page scans (and retained source PDFs) still exist — ArchiveCleanup
    /// reclaims those 60 days after a shoot is exported.
    @discardableResult
    static func writePDF(from imagePaths: [URL], to destination: URL) throws -> URL {
        let data = try makePDF(from: imagePaths)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
        return destination
    }

    // MARK: - Rasterising an upload

    /// Rasterises each page of `url` to a 2× PNG in `dir` (named by
    /// `rasterizedPageName`) and retains the original PDF alongside them as
    /// `<stem>.pdf`, so `makePDF` can later embed the source pages verbatim.
    /// Returns the page image URLs in order. Uses PDFKit so page orientation
    /// (including /Rotate) is handled correctly.
    static func rasterise(pdfAt url: URL, into dir: URL, scale: CGFloat = 2) -> [URL] {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return [] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent

        let retainedSource = dir.appendingPathComponent(retainedSourceName(stem: stem))
        if !FileManager.default.fileExists(atPath: retainedSource.path) {
            try? FileManager.default.copyItem(at: url, to: retainedSource)
        }

        var results: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size   = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image  = page.thumbnail(of: size, for: .mediaBox)

            guard let tiff      = image.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiff),
                  let pngData   = bitmapRep.representation(using: .png, properties: [:])
            else { continue }

            let dest = dir.appendingPathComponent(rasterizedPageName(stem: stem, page: i + 1))
            try? pngData.write(to: dest)
            results.append(dest)
        }
        return results
    }

    // MARK: - Source PDF loading

    /// A retained source PDF, opened once per build for both text detection
    /// (PDFKit) and content embedding (Core Graphics).
    private final class LoadedPDF {
        let document: CGPDFDocument
        private let kit: PDFDocument

        init?(url: URL) {
            guard let document = CGPDFDocument(url as CFURL),
                  let kit = PDFDocument(url: url) else { return nil }
            self.document = document
            self.kit = kit
        }

        /// Whether `page` (1-based) has an extractable text layer worth keeping.
        /// A scanned PDF page returns no text, so we OCR its raster instead.
        func hasText(onPage page: Int) -> Bool {
            guard let text = kit.page(at: page - 1)?.string else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func loadedPDF(at url: URL, cache: inout [String: LoadedPDF?]) -> LoadedPDF? {
        let key = url.path
        if let cached = cache[key] { return cached }
        let loaded = LoadedPDF(url: url)
        cache[key] = loaded
        return loaded
    }

    // MARK: - Page rendering

    /// Embeds a source PDF page verbatim, preserving its vector text and layout.
    private static func embedPDFPage(_ page: CGPDFPage, into context: CGContext) {
        let mediaBox = page.getBoxRect(.mediaBox)
        // Pages with a /Rotate of 90 or 270 present swapped dimensions.
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        var pageRect = (rotation == 90 || rotation == 270)
            ? CGRect(x: 0, y: 0, width: mediaBox.height, height: mediaBox.width)
            : CGRect(x: 0, y: 0, width: mediaBox.width, height: mediaBox.height)

        context.beginPage(mediaBox: &pageRect)
        context.saveGState()
        // getDrawingTransform folds in the page's own /Rotate, so we draw upright.
        let transform = page.getDrawingTransform(.mediaBox, rect: pageRect, rotate: 0, preserveAspectRatio: true)
        context.concatenate(transform)
        context.clip(to: mediaBox)
        context.drawPDFPage(page)
        context.restoreGState()
        context.endPage()
    }

    /// Draws an image page and overlays an invisible OCR text layer.
    private static func renderImagePage(_ cgImage: CGImage, into context: CGContext) {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        var box = CGRect(x: 0, y: 0, width: width, height: height)

        context.beginPage(mediaBox: &box)
        context.draw(cgImage, in: box)
        drawTextLayer(for: cgImage, pageSize: CGSize(width: width, height: height), into: context)
        context.endPage()
    }

    /// OCRs the page image and draws each recognised string as invisible text
    /// (PDF text render mode 3) positioned over the matching pixels. Vision's
    /// normalised, bottom-left-origin boxes map directly onto the PDF's y-up
    /// coordinate space, so no flipping is needed.
    private static func drawTextLayer(for cgImage: CGImage, pageSize: CGSize, into context: CGContext) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return }
        guard let observations = request.results, !observations.isEmpty else { return }

        context.saveGState()
        context.setTextDrawingMode(.invisible)

        for obs in observations {
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let b = obs.boundingBox
            let rect = CGRect(x: b.minX * pageSize.width,
                              y: b.minY * pageSize.height,
                              width: b.width * pageSize.width,
                              height: b.height * pageSize.height)
            guard rect.width > 1, rect.height > 1 else { continue }

            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.8, nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let line = CTLineCreateWithAttributedString(attributed)

            // Scale the invisible glyphs horizontally to span the OCR box, so a
            // text selection lines up with the printed word rather than trailing
            // off or stopping short.
            let typographicWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textMatrix = typographicWidth > 0
                ? CGAffineTransform(scaleX: rect.width / CGFloat(typographicWidth), y: 1)
                : .identity
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
            CTLineDraw(line, context)
        }

        context.restoreGState()
    }
}
