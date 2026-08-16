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
    /// Three lines on a dark backdrop that nothing had ever drawn.
    ///
    /// This carried a floor of its own, 0.005 where the legibility harnesses
    /// asked 0.01, honestly measured against this surface: a lightbox is
    /// deliberately mostly empty backdrop with three short lines in the middle
    /// of it. That is the drift #614 is about, and the check beside it was
    /// weaker than it read: the words-off render switched off the WHOLE view,
    /// backdrop and all, so what it compared the screen against was a blank
    /// image rather than the same screen without its type.
    ///
    /// Now the type alone is switched off and what is measured is the
    /// difference, against the one floor the whole suite uses.
    func testTheMissingFileStateDrawsItsWords() throws {
        let share = WordFootprint.share(try render(wordless: false),
                                        try render(wordless: true))
        print(String(format: "  lightbox, missing file: %.4f", share))

        XCTAssertGreaterThan(share, WordFootprint.drawn, """
            Switching every word off the lightbox changed \
            \(String(format: "%.4f", share)) of the render, which is nothing, so the \
            sentence saying the file is gone is in the view tree and not on the screen. \
            A spinner would read as a slow load of a photo that no longer exists (L10). \
            The backdrop and the close button are marks on the page whatever the words \
            do, so a flat threshold could not have said this (L141).
            """)
    }

    /// The file name is the useful half of that state, so it is drawn rather
    /// than only passed in.
    ///
    /// Measured as the footprint of the words, not as ink: with a name the type
    /// covers more of the screen than without one, and both renders paint the
    /// same backdrop, so ink would be comparing two numbers that are mostly
    /// backdrop either way.
    func testTheMissingFileStateNamesTheFile() throws {
        let withName = WordFootprint.share(try render(wordless: false),
                                           try render(wordless: true))
        let withoutName = WordFootprint.share(
            try render(wordless: false, fileName: ""),
            try render(wordless: true, fileName: ""))

        XCTAssertGreaterThan(withName, withoutName, """
            The lightbox's words are worth the same with a file name \
            (\(String(format: "%.4f", withName))) and without one \
            (\(String(format: "%.4f", withoutName))), so the name of the missing file is \
            not reaching the screen and the person is told only that something is gone.
            """)
    }

    // MARK: - Rendering

    /// The state at the size the window gives it, on nothing but itself: no
    /// page around it, because the lightbox covers everything.
    private func render(wordless: Bool,
                        fileName: String = "DSC_4417.jpg") throws -> NSBitmapImageRep {
        try WordFootprint.hosted(
            PhotoLightboxBody(url: URL(fileURLWithPath: "/photos/\(fileName)"),
                              load: .missing,
                              onDismiss: {})
                .frame(width: 520, height: 300)
                .background(PaintedSurfaces.lightboxBackdrop
                    .composited(over: PaintedSurfaces.page)),
            size: CGSize(width: 520, height: 300),
            wordless: wordless)
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

#if POSTROLL_TESTS
extension PhotoLightboxTests {
    /// The lightbox into the shared review sheet (#623).
    ///
    /// It is the one measured surface that had no dump of its own, and it is
    /// the hardest of them to reach by hand: it only appears over a photo that
    /// has gone missing off disk.
    ///
    /// Both states, because the file name is the useful half of this screen and
    /// the check next door exists to prove it is drawn: a sheet showing only the
    /// named one could not show that.
    func testDumpTheLightboxForReview() throws {
        let states = [("a file that has gone", "DSC_4417.jpg"),
                      ("a file with no name", "")]

        for (name, fileName) in states {
            try ReviewSheet.write(try render(wordless: false, fileName: fileName),
                                  group: Self.reviewGroup, name: name)
        }

        let written = try ReviewSheet.written(group: Self.reviewGroup)
        ReviewSheet.announce(group: Self.reviewGroup, count: written.count)

        XCTAssertEqual(written.count, states.count, """
            \(states.count) lightbox states were rendered and \(written.count) reached \
            \(ReviewSheet.folder.path), so the sheet is missing one and reads exactly \
            like a sheet holding both.
            """)
    }

    fileprivate static let reviewGroup = "lightbox"
}
#endif
