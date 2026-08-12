import XCTest
import AppKit

/// writeVerifiedPDF is what makes "delete the scans once the PDF exists" safe:
/// it refuses to report success for a file that isn't really there (#80).
final class VerifiedProgramPDFWriteTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VerifiedPDFWrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testWritesAPDFThatIsActuallyOnDisk() throws {
        let page = dir.appendingPathComponent("p1.png")
        try makePNG().write(to: page)
        let dest = dir.appendingPathComponent("out/program.pdf")

        let written = try ProgramPDFBuilder.writeVerifiedPDF(from: [page], to: dest)

        XCTAssertEqual(written, dest)
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int
        XCTAssertGreaterThan(size ?? 0, 0)
    }

    func testAnUnwritableDestinationThrowsRatherThanReportingSuccess() throws {
        let page = dir.appendingPathComponent("p1.png")
        try makePNG().write(to: page)
        // A destination whose parent is an existing FILE can't be created.
        let blocker = dir.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let dest = blocker.appendingPathComponent("program.pdf")

        XCTAssertThrowsError(try ProgramPDFBuilder.writeVerifiedPDF(from: [page], to: dest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testNoPagesIsAnErrorNotAnEmptyPDF() {
        let dest = dir.appendingPathComponent("program.pdf")
        XCTAssertThrowsError(try ProgramPDFBuilder.writeVerifiedPDF(from: [], to: dest))
    }

    private func makePNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.white.drawSwatch(in: NSRect(x: 0, y: 0, width: 20, height: 20))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            // A failure, not a skip: encoding a bitmap in process has no
            // reason to fail, and a skip here would report the whole suite
            // green while the test it feeds never ran (#224).
            XCTFail("could not encode the test PNG, so nothing below was exercised")
            throw ProgramFixtureError.couldNotEncodePNG
        }
        return png
    }
}
