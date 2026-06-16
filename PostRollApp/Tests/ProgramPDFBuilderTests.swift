import XCTest
import PDFKit
import AppKit
import CoreGraphics
import CoreText

/// Coverage for `ProgramPDFBuilder`, which bundles an event's program pages
/// (always stored as individual images, even when uploaded as one PDF) back
/// into a single downloadable PDF.
final class ProgramPDFBuilderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("program-pdf-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Write a solid-colour PNG of the given size and return its URL.
    private func makePNG(_ name: String, size: NSSize) throws -> URL {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Couldn't encode test PNG")
        }
        let url = dir.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    /// Write a white PNG with `text` drawn large and black, for OCR coverage.
    private func makeTextPNG(_ name: String, text: String, size: NSSize) throws -> URL {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: size.height * 0.4),
            .foregroundColor: NSColor.black,
        ]
        let str = text as NSString
        let textSize = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: (size.width - textSize.width) / 2,
                             y: (size.height - textSize.height) / 2),
                 withAttributes: attrs)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Couldn't encode test PNG")
        }
        let url = dir.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    /// Write a born-digital, single-page PDF with `text` as a real (selectable)
    /// text layer, via AppKit's PDF rendering so it embeds a proper ToUnicode
    /// map and PDFKit can extract it. Empty `text` yields a page with no
    /// extractable text, standing in for a scanned PDF page.
    @MainActor
    private func makeTextPDF(_ name: String, text: String, size: CGSize) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let rect = NSRect(origin: .zero, size: size)
        let textView = NSTextView(frame: rect)
        textView.font = NSFont.systemFont(ofSize: 24)
        textView.string = text
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        try textView.dataWithPDF(inside: rect).write(to: url)
        return url
    }

    @MainActor
    func testEmbedsNativePDFTextLayerVerbatim() throws {
        // A rasterised PDF page whose retained source carries real text should
        // embed that source page — preserving its exact text. Prove it by making
        // the raster a BLANK page: only embedding (not OCR) can surface the text.
        _ = try makeTextPDF("KochelProgram.pdf", text: "Allegro con brio",
                            size: CGSize(width: 600, height: 300))
        let raster = try makePNG("KochelProgram_p1.png", size: NSSize(width: 800, height: 600))

        let data = try ProgramPDFBuilder.makePDF(from: [raster])
        let extracted = try XCTUnwrap(PDFDocument(data: data)?.string)
        XCTAssertTrue(extracted.contains("Allegro con brio"),
                      "Expected the verbatim source text, got: \"\(extracted)\"")
    }

    @MainActor
    func testFallsBackToOCRWhenSourcePDFHasNoTextLayer() throws {
        // A scanned PDF page (no extractable text) should not be embedded blank;
        // the raster gets OCR'd instead so the page is still searchable.
        _ = try makeTextPDF("ScanProgram.pdf", text: "",
                            size: CGSize(width: 400, height: 300))
        let raster = try makeTextPNG("ScanProgram_p1.png", text: "PROGRAM",
                                     size: NSSize(width: 600, height: 300))

        let data = try ProgramPDFBuilder.makePDF(from: [raster])
        let extracted = (try XCTUnwrap(PDFDocument(data: data)?.string)).uppercased()
        XCTAssertTrue(extracted.contains("PROGRAM"),
                      "Expected OCR fallback text, got: \"\(extracted)\"")
    }

    @MainActor
    func testSourcePDFPageResolvesByFilenameConvention() throws {
        _ = try makeTextPDF("Recital.pdf", text: "x", size: CGSize(width: 200, height: 200))
        let raster = dir.appendingPathComponent("Recital_p3.png")

        let resolved = try XCTUnwrap(ProgramPDFBuilder.sourcePDFPage(for: raster))
        XCTAssertEqual(resolved.page, 3)
        XCTAssertEqual(resolved.pdfURL.lastPathComponent, "Recital.pdf")

        // A directly uploaded image (no _p marker, no sibling PDF) has no source.
        XCTAssertNil(ProgramPDFBuilder.sourcePDFPage(for: dir.appendingPathComponent("snapshot.png")))
    }

    @MainActor
    func testRasteriseWritesPagesAndRetainsOriginalPDF() throws {
        // Build a two-page born-digital PDF to rasterise.
        let p1 = try makeTextPDF("a.pdf", text: "Movement I", size: CGSize(width: 400, height: 300))
        let p2 = try makeTextPDF("b.pdf", text: "Movement II", size: CGSize(width: 400, height: 300))
        let combined = PDFDocument()
        combined.insert(try XCTUnwrap(PDFDocument(url: p1)?.page(at: 0)?.copy() as? PDFPage), at: 0)
        combined.insert(try XCTUnwrap(PDFDocument(url: p2)?.page(at: 0)?.copy() as? PDFPage), at: 1)
        let source = dir.appendingPathComponent("DcinyProgram.pdf")
        XCTAssertTrue(combined.write(to: source))

        let out = dir.appendingPathComponent("out")
        let pages = ProgramPDFBuilder.rasterise(pdfAt: source, into: out)

        // One PNG per page, named by the shared convention, written to disk.
        XCTAssertEqual(pages.map(\.lastPathComponent),
                       ["DcinyProgram_p1.png", "DcinyProgram_p2.png"])
        for page in pages {
            XCTAssertTrue(FileManager.default.fileExists(atPath: page.path))
        }

        // The original PDF is retained next to the pages, intact (2 pages).
        let retained = out.appendingPathComponent("DcinyProgram.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path),
                      "original PDF should be retained for verbatim embedding")
        XCTAssertEqual(PDFDocument(url: retained)?.pageCount, 2)

        // And a rasterised page resolves back to that retained source.
        let resolved = try XCTUnwrap(ProgramPDFBuilder.sourcePDFPage(for: pages[1]))
        XCTAssertEqual(resolved.page, 2)
        XCTAssertEqual(resolved.pdfURL.path, retained.path)
    }

    func testBundlesEachImageAsAPageInOrder() throws {
        let pages = [
            try makePNG("page1.png", size: NSSize(width: 120, height: 160)),
            try makePNG("page2.png", size: NSSize(width: 120, height: 160)),
            try makePNG("page3.png", size: NSSize(width: 120, height: 160)),
        ]

        let data = try ProgramPDFBuilder.makePDF(from: pages)
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.pageCount, 3)
    }

    func testEmbedsSearchableOCRTextLayer() throws {
        // A page with a large, clearly printed word should come back searchable
        // in the assembled PDF via the invisible OCR text layer.
        let page = try makeTextPNG("cover.png", text: "PROGRAM", size: NSSize(width: 600, height: 300))

        let data = try ProgramPDFBuilder.makePDF(from: [page])
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let extracted = (doc.string ?? "").uppercased()
        XCTAssertTrue(extracted.contains("PROGRAM"),
                      "Expected OCR'd text layer to contain \"PROGRAM\", got: \"\(extracted)\"")
    }

    func testEmptyInputThrowsNoPages() {
        XCTAssertThrowsError(try ProgramPDFBuilder.makePDF(from: [])) { error in
            guard case ProgramPDFBuilder.BuildError.noPages = error else {
                return XCTFail("Expected .noPages, got \(error)")
            }
        }
    }

    func testUnreadableImageThrows() throws {
        let bad = dir.appendingPathComponent("not-an-image.png")
        FileManager.default.createFile(atPath: bad.path, contents: Data("garbage".utf8))

        XCTAssertThrowsError(try ProgramPDFBuilder.makePDF(from: [bad])) { error in
            guard case ProgramPDFBuilder.BuildError.unreadableImage = error else {
                return XCTFail("Expected .unreadableImage, got \(error)")
            }
        }
    }
}
