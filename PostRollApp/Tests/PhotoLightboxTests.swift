import XCTest
import SwiftUI
import AppKit

/// The full size photo, drawn by one view rather than two (#602).
///
/// It existed twice, 97% identical: `ReviewPhotoOverlay` in caption review and
/// `PhotoPreviewOverlay` in photo assignment. The 3% was a behaviour: one of
/// them dismissed on Escape and the other did not, which nobody chose. That is
/// what two copies do, and #598 is the direct example, where every colour in
/// its missing-file state had to be named twice in one change.
@MainActor
final class PhotoLightboxTests: XCTestCase {

    // MARK: - There is one of it

    /// Counted through the backdrop it paints, which is the one thing only a
    /// lightbox draws. Counting the type name instead would pass the moment a
    /// third copy was given a fourth name, which is exactly how the second one
    /// arrived.
    func testOnlyOneViewDrawsTheLightbox() throws {
        let drawers = try sourceFiles().filter {
            try source($0).contains("PaintedSurfaces.lightboxBackdrop")
        }

        XCTAssertEqual(drawers.count, 1, """
            \(drawers.count) files paint the lightbox backdrop: \
            \(drawers.joined(separator: ", ")). A second copy of this view drifted \
            into dismissing on Escape on one screen and not the other, and every \
            colour on it had to be named twice. One view, used by both.
            """)
    }

    /// Escape closes it, wherever it is opened from.
    ///
    /// The behaviour the two copies disagreed about. Asserted on the source
    /// because a keyboard shortcut cannot be pressed in a headless render, and
    /// scoped to the file that draws the backdrop rather than searched for
    /// anywhere, so an unrelated cancel shortcut elsewhere cannot answer for it
    /// (L135).
    func testTheLightboxDismissesOnEscape() throws {
        for relative in try sourceFiles() {
            let code = try source(relative)
            guard code.contains("PaintedSurfaces.lightboxBackdrop") else { continue }

            XCTAssertTrue(code.contains("keyboardShortcut(.cancelAction)"), """
                \(relative) draws the lightbox and does not close it on Escape, so a \
                photo opened full screen from that screen can only be dismissed by \
                finding the close button or clicking the backdrop.
                """)
        }
    }

    // MARK: - It says when the file is gone

    /// The missing-file state, rendered (#602).
    ///
    /// Three lines on a dark backdrop that nothing had ever drawn. Measured
    /// against the same view with its words switched off, not against a flat
    /// threshold, because the backdrop is itself a mark on the page and would
    /// answer for the type (L141).
    func testTheMissingFileStateDrawsItsWords() throws {
        let words = inkCoverage(try render(wordless: false))
        let backdropOnly = inkCoverage(try render(wordless: true))

        print(String(format: "  lightbox, missing file: %.4f words, %.4f backdrop",
                     words, backdropOnly))

        // A lower floor than the 0.01 the two legibility harnesses use, and the
        // reason is the surface rather than a weaker standard: a lightbox is
        // deliberately mostly empty backdrop, with three short lines in the
        // middle of it, and it measures 0.0111. What makes that meaningful is
        // the line below: the same view with its words switched off measures
        // 0.0000, so every one of those pixels is type.
        XCTAssertGreaterThan(words, 0.005, """
            The lightbox rendered almost nothing but its backdrop \
            (\(String(format: "%.4f", words))), so the sentence saying the file is \
            gone is in the view tree and not on the screen. A spinner would read as \
            a slow load of a photo that no longer exists (L10).
            """)
        XCTAssertGreaterThan(words, backdropOnly * 3, """
            The lightbox measures \(String(format: "%.4f", words)) with its words and \
            \(String(format: "%.4f", backdropOnly)) with them switched off. The words \
            have to be worth far more than the backdrop and the close button, or this \
            check is reading the chrome.
            """)
    }

    /// The file name is the useful half of that state, so it is drawn rather
    /// than only passed in.
    func testTheMissingFileStateNamesTheFile() throws {
        let withName = inkCoverage(try render(wordless: false))
        let withoutName = inkCoverage(try render(wordless: false, fileName: ""))

        XCTAssertGreaterThan(withName, withoutName, """
            The lightbox measures the same with a file name and without one, so the \
            name of the missing file is not reaching the screen and the person is \
            told only that something is gone.
            """)
    }

    // MARK: - Rendering

    /// The state at the size the window gives it, on nothing but itself: no
    /// page around it, because the lightbox covers everything.
    private func render(wordless: Bool,
                        fileName: String = "DSC_4417.jpg") throws -> NSBitmapImageRep {
        let view = PhotoLightboxBody(
            url: URL(fileURLWithPath: "/photos/\(fileName)"),
            load: .missing,
            onDismiss: {})
            .opacity(wordless ? 0 : 1)
            .frame(width: 520, height: 300)
            .background(PaintedSurfaces.lightboxBackdrop.composited(over: PaintedSurfaces.page))

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "AppKit produced no bitmap for the lightbox")
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The share of pixels differing noticeably from the most common colour,
    /// which IS the background. The same measurement the two legibility
    /// harnesses use.
    private func inkCoverage(_ rep: NSBitmapImageRep) -> Double {
        var luminances: [Double] = []
        for y in Swift.stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in Swift.stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                luminances.append(0.299 * c.redComponent
                                  + 0.587 * c.greenComponent
                                  + 0.114 * c.blueComponent)
            }
        }
        guard !luminances.isEmpty else { return 0 }
        let background = luminances.sorted()[luminances.count / 2]
        return Double(luminances.filter { abs($0 - background) > 0.12 }.count)
            / Double(luminances.count)
    }

    // MARK: - Reading the tree

    private func sourceFiles() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .filter { !$0.hasSuffix("PaintedSurfaces.swift") }
            .sorted()

        // A sweep that reads nothing objects to nothing (L98).
        XCTAssertGreaterThan(files.count, 20,
                             "the sweep found \(files.count) source files, so it is "
                             + "proving nothing about the ones it did not read")
        return files
    }

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/\(relative)")
        return SwiftSourceText.withoutComments(
            try String(contentsOf: url, encoding: .utf8))
    }
}
