import Foundation
import AppKit
import CoreGraphics
import CoreText
import Vision

// MARK: - ProgramPDFBuilder

/// Bundles an event's program pages into a single, searchable PDF.
///
/// Program pages are always stored on disk as individual image files (PNG/JPG)
/// in `AppPaths.programsDir`, even when the original upload was one multi-page
/// PDF (the upload flow rasterises each page to its own PNG). There is no
/// retained "original PDF", so a download has to rebuild one from those pages.
///
/// Each page image is drawn into a PDF page with an invisible OCR text layer
/// (Apple's Vision) laid over it at the recognised positions, so the resulting
/// PDF is selectable and searchable — the same trick a document scanner uses.
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

    /// Build a single searchable PDF from the page images, preserving order.
    /// Each image becomes one page with an invisible OCR text layer. Throws if
    /// the list is empty or any image can't be read (rather than silently
    /// dropping pages). Runs OCR on every page, so call it off the main thread.
    static func makePDF(from imagePaths: [URL]) throws -> Data {
        guard !imagePaths.isEmpty else { throw BuildError.noPages }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw BuildError.encodingFailed
        }

        for url in imagePaths {
            guard let nsImage = NSImage(contentsOf: url),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw BuildError.unreadableImage(url)
            }
            renderPage(cgImage, into: context)
        }

        context.closePDF()
        guard data.length > 0 else { throw BuildError.encodingFailed }
        return data as Data
    }

    /// Build the searchable PDF and write it to `destination`, returning it.
    /// Used to pre-generate the downloadable program at upload time, while the
    /// page scans still exist — ArchiveCleanup reclaims those scans 60 days
    /// after a shoot is exported, so the PDF has to be baked before then.
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

    // MARK: - Page rendering

    private static func renderPage(_ cgImage: CGImage, into context: CGContext) {
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
