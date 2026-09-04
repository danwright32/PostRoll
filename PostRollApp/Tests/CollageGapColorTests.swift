import XCTest
import AppKit
import SwiftUI

/// #1117: what the collage thumbnail samples for its gap colour.
///
/// The thumbnail read the PNG's bytes off the main actor and then decoded them
/// ON it, which is the lazy main-thread decode #966 removed everywhere else.
/// Moving it to `ImageLoad.read` also makes the image SMALLER, and the gap
/// colour is sampled out of those pixels, so the question the issue asks to
/// settle first is whether the answer moves.
///
/// These pin it. A synthetic collage is written to disk with a known gap
/// colour, sampled at full size and again after going through the real decode
/// path, and the two are required to agree.
final class CollageGapColorTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A collage-shaped image: a flat gap colour with a contrasting panel inset
    /// well away from the corner the sampler reads.
    private func makeCollage(gap: NSColor, size: NSSize) throws -> URL {
        let image = NSImage(size: size)
        image.lockFocus()
        gap.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.systemRed.setFill()
        NSRect(x: size.width * 0.2, y: size.height * 0.2,
               width: size.width * 0.6, height: size.height * 0.6).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw XCTSkip("could not build a PNG on this machine") }
        let url = folder.appendingPathComponent("collage.png")
        try png.write(to: url)
        return url
    }

    private func components(_ color: Color) -> (r: Double, g: Double, b: Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return (Double(ns.redComponent), Double(ns.greenComponent),
                Double(ns.blueComponent))
    }

    func testTheGapColourIsTheGapRatherThanTheContent() throws {
        // Asserted as WHICH REGION it sampled, not as an exact triple. Drawing
        // through `lockFocus` goes via the display colour space, so the value
        // that comes back is a converted one: a blue of 0.3 reads as 0.37 on
        // this machine and would read differently on another. Pinning the
        // rendering would make this a test about colour management on whichever
        // Mac ran it (L103, L376).
        //
        // What matters is that it reads the corner, which is the gap, and not
        // the panel inset into the middle.
        let gap = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let url = try makeCollage(gap: gap, size: NSSize(width: 900, height: 1600))
        let full = try XCTUnwrap(NSImage(contentsOf: url))

        let sampled = components(CollagePreviewThumbnail.sampleGapColor(from: full))
        let content = components(Color(nsColor: .systemRed))

        XCTAssertLessThan(sampled.r, sampled.b,
                          "the sample is not the blue-ish gap: \(sampled)")
        XCTAssertGreaterThan(abs(sampled.r - content.r), 0.3,
                             "the sample looks like the red panel inset in the "
                             + "middle rather than the gap around it: \(sampled)")
    }

    @MainActor
    func testTheDecodedSmallImageSamplesTheSameGapColour() async throws {
        // The question #1117 asks to settle before moving the decode. The
        // sampler reads pixel (4, 4), and a downscale maps that to a much larger
        // region of the original: if the gap were narrower than that region, the
        // colour would move and this change could not be made blind.
        let gap = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let url = try makeCollage(gap: gap, size: NSSize(width: 900, height: 1600))

        let atFullSize = components(CollagePreviewThumbnail.sampleGapColor(
            from: NSImage(contentsOf: url)))
        let decoded = await ImageLoad.read(url, fitting: 440)
        let small = components(CollagePreviewThumbnail.sampleGapColor(
            from: decoded.image))

        XCTAssertNotNil(decoded.image, "the decode path returned nothing, so "
                        + "this compares one reading against a fallback")
        XCTAssertEqual(small.r, atFullSize.r, accuracy: 0.02,
                       "the gap colour moved when the image was decoded small")
        XCTAssertEqual(small.g, atFullSize.g, accuracy: 0.02)
        XCTAssertEqual(small.b, atFullSize.b, accuracy: 0.02)
    }

    func testNoImageFallsBackToTheAppsOwnDeepPage() {
        // Its own state, not a black square: an image that could not be read
        // must not be drawn as a colour somebody might take for the gap (L10).
        let fallback = components(CollagePreviewThumbnail.sampleGapColor(from: nil))
        let expected = components(PaintedSurfaces.deepPage)

        XCTAssertEqual(fallback.r, expected.r, accuracy: 0.001)
        XCTAssertEqual(fallback.g, expected.g, accuracy: 0.001)
        XCTAssertEqual(fallback.b, expected.b, accuracy: 0.001)
    }
}
