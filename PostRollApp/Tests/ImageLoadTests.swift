import XCTest
import AppKit

/// #461: a thumbnail whose file has gone spun forever, because `NSImage?` says
/// the same nil for "not read yet" and "not there".
final class ImageLoadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageLoad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A real PNG on disk, because the whole question is what `NSImage` does
    /// with actual bytes and a stub would only confirm this file's assumption
    /// about it (L52).
    private func writePNG(named name: String) throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        let data = try XCTUnwrap(rep?.representation(using: .png, properties: [:]))
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testAFileThatIsThereLoads() async throws {
        let url = try writePNG(named: "photo.png")
        let load = await ImageLoad.read(url)
        XCTAssertNotNil(load.image, "a real PNG did not load")
        XCTAssertFalse(load.isMissing)
    }

    func testAFileThatIsGoneIsMissingRatherThanStillLoading() async {
        let load = await ImageLoad.read(dir.appendingPathComponent("reclaimed.jpg"))

        // The whole point. `.loading` here is what left a spinner running
        // forever over a photo ArchiveCleanup had reclaimed sixty days after
        // the export (L10).
        XCTAssertEqual(load, .missing)
        XCTAssertNil(load.image)
    }

    func testAFileThatIsNotAnImageIsMissingRatherThanLoaded() async throws {
        // A truncated or corrupt file reads as bytes and decodes to nothing,
        // which is a state a thumbnail has to render as gone rather than as
        // still working.
        let url = dir.appendingPathComponent("not-a-photo.png")
        try Data("this is not a png".utf8).write(to: url)

        let load = await ImageLoad.read(url)

        XCTAssertEqual(load, .missing)
    }

    func testTheThreeStatesAreActuallyDistinct() throws {
        let image = try XCTUnwrap(NSImage(size: NSSize(width: 1, height: 1)) as NSImage?)
        XCTAssertNotEqual(ImageLoad.loading, ImageLoad.missing)
        XCTAssertNotEqual(ImageLoad.loaded(image), ImageLoad.missing)
        XCTAssertNotEqual(ImageLoad.loaded(image), ImageLoad.loading)
    }

    func testAnAlreadyLoadedOptionalIsClassifiedTheSameWay() throws {
        // The call sites that fetch an image alongside a layout file go through
        // `of`, and it has to reach the same verdict as `read` or one screen
        // shows a missing badge where its neighbour shows a spinner.
        XCTAssertEqual(ImageLoad.of(nil), .missing)
        let image = try XCTUnwrap(NSImage(size: NSSize(width: 1, height: 1)) as NSImage?)
        XCTAssertEqual(ImageLoad.of(image), .loaded(image))
    }
}
