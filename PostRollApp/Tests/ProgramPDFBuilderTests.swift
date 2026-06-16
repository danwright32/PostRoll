import XCTest
import PDFKit
import AppKit

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
