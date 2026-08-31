import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// #966: a photo is decoded for the frame it is drawn in, once.
///
/// The freeze Dan reported was the main thread decoding full size JPEGs inside
/// the CoreAnimation commit, every time the app came back to the front, because
/// macOS discards SwiftUI's cached image surfaces whenever it leaves. Two
/// things fix it and both are asserted here: the bitmap behind an 80pt square
/// is sized for an 80pt square, and it is produced once rather than re-derived
/// from the original on every cold draw.
@MainActor
final class ImageDownsamplingTests: XCTestCase {

    /// A real JPEG on disk, at the shape of the source photos this app reads.
    ///
    /// Written rather than committed: a fixture large enough to make the point
    /// is a megabyte of binary in the repo, and what matters about it is its
    /// DIMENSIONS, which are stated here where the assertions can see them.
    private func writeJPEG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downsample-\(UUID().uuidString).jpg")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Not a flat fill: a single colour compresses to almost nothing and
        // would not exercise a decode worth measuring.
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                context.setFillColor(red: Double(x % 255) / 255, green: Double(y % 255) / 255,
                                     blue: 0.4, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// One read, unwrapped. `XCTUnwrap` takes an autoclosure, which cannot
    /// carry an `await`, so the read happens here and the unwrap after it.
    private func loaded(_ url: URL, fitting points: CGFloat) async throws -> NSImage {
        let load = await ImageLoad.read(url, fitting: points)
        return try XCTUnwrap(load.image)
    }

    /// The same read, straight to the pixel dimensions behind it.
    private func pixels(_ url: URL, fitting points: CGFloat) async throws
        -> (width: Int, height: Int) {
        try backingPixels(try await loaded(url, fitting: points))
    }

    private func backingPixels(_ image: NSImage) throws -> (width: Int, height: Int) {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return (cg.width, cg.height)
    }

    override func setUp() async throws {
        // Every test here decides for itself whether it is measuring a cold
        // read or a warm one, so none of them may inherit another's cache. A
        // suite that can only ever reach the warm path proves nothing about the
        // draw this exists to fix.
        await ThumbnailStore.shared.clear()
    }

    // MARK: - Sized for the frame

    func testAnEightyPointThumbnailIsNotBackedByAFullSizePhoto() async throws {
        let url = try writeJPEG(width: 2500, height: 1667)
        defer { try? FileManager.default.removeItem(at: url) }

        let size = try await pixels(url, fitting: 80)
        let allowed = ImageLoad.pixelSize(for: 80)

        XCTAssertLessThanOrEqual(max(size.width, size.height), allowed,
                                 "an 80pt square backed by \(size.width)x\(size.height)")
        // The positive control. Without it this passes on a reader that returns
        // a one pixel image, or nothing at all (L159).
        XCTAssertGreaterThan(min(size.width, size.height), 1)
    }

    func testALargerFrameGetsALargerBitmap() async throws {
        // The size has to actually be USED. Decoding everything to one fixed
        // small size would satisfy the assertion above and make the lightbox
        // soft, with nothing reporting it.
        let url = try writeJPEG(width: 2500, height: 1667)
        defer { try? FileManager.default.removeItem(at: url) }

        let small = try await pixels(url, fitting: 80)
        let large = try await pixels(url, fitting: 800)
        XCTAssertGreaterThan(large.width, small.width)
        XCTAssertLessThanOrEqual(large.width, ImageLoad.pixelSize(for: 800))
    }

    func testAPhotoSmallerThanItsFrameIsNotBlownUp() async throws {
        // ImageIO's thumbnail is a MAXIMUM, not a target. Upscaling a small
        // file would cost memory to make it blurrier.
        let url = try writeJPEG(width: 120, height: 90)
        defer { try? FileManager.default.removeItem(at: url) }

        let size = try await pixels(url, fitting: 800)
        XCTAssertEqual(size.width, 120)
        XCTAssertEqual(size.height, 90)
    }

    // MARK: - The size it REPORTS is the size it always reported

    func testTheImageStillMeasuresAsTheFullPhoto() async throws {
        // Several screens compute geometry from `image.size`: the collage cell
        // overlay derives its crop overflow from it and says in its own comment
        // that it is Python's `effective_scale` arithmetic, and Python reads the
        // original file. A thumbnail's rounded dimensions there would move the
        // preview away from what renders, silently (L263).
        let url = try writeJPEG(width: 2500, height: 1667)
        defer { try? FileManager.default.removeItem(at: url) }

        let byThisLoader = try await loaded(url, fitting: 80)
        let byAppKit = try XCTUnwrap(NSImage(data: try Data(contentsOf: url)))
        XCTAssertEqual(byThisLoader.size, byAppKit.size)
    }

    // MARK: - Produced once

    func testTheSamePhotoAtTheSameSizeIsDecodedOnce() async throws {
        let url = try writeJPEG(width: 2500, height: 1667)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try await loaded(url, fitting: 80)
        let again = try await loaded(url, fitting: 80)
        let firstCG = try XCTUnwrap(first.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let againCG = try XCTUnwrap(again.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue(firstCG === againCG, "the second read decoded the file again")
    }

    func testEditingThePhotoInPlaceRetiresTheCachedCopy() async throws {
        // Photos here are edited in place: a crop rewrites the file and leaves
        // the path alone. A cache keyed on the path alone would serve the
        // picture from before the edit forever, and the person would watch
        // their change not happen (L40).
        let url = try writeJPEG(width: 2500, height: 1667)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try await loaded(url, fitting: 80)

        let replacement = try writeJPEG(width: 1000, height: 1000)
        defer { try? FileManager.default.removeItem(at: replacement) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: replacement, to: url)

        let after = try await loaded(url, fitting: 80)
        XCTAssertNotEqual(before.size, after.size, "the edited file kept its old thumbnail")
    }

    func testTwoSizesOfOnePhotoAreSeparateEntries() async throws {
        // Keyed on the path alone, the lightbox and the grid would hand each
        // other their own bitmap and one of the two would be wrong.
        let url = try writeJPEG(width: 2500, height: 1667)
        defer { try? FileManager.default.removeItem(at: url) }

        let small = try await pixels(url, fitting: 80)
        let large = try await pixels(url, fitting: 800)
        let smallAgain = try await pixels(url, fitting: 80)
        XCTAssertEqual(small.width, smallAgain.width)
        XCTAssertNotEqual(small.width, large.width)
    }

    // MARK: - The key

    func testAnUnreadableFileIsAMissRatherThanACacheEntry() async throws {
        // The key is built from a stat. A cache that cannot tell whether its
        // subject changed must answer nothing rather than answer stale (L215).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString).jpg")
        XCTAssertNil(ThumbnailStore.key(url, maxPixel: 160))
    }
}
