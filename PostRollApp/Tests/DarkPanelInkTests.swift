import XCTest
import SwiftUI
import AppKit

/// #1414: type on the dark preview panel is drawn in ink for the dark panel.
///
/// The reel and collage editors sit on `storyPanel`, near black, and drew their
/// hints, the pace warning and their text buttons in ink chosen for the cream
/// page: dark brown on near black, which Dan called basically unreadable.
/// Nothing reported it, because each of those names was registered as a pair
/// against the page and nowhere else. A pair is only as good as the surfaces it
/// is registered on (L213, L569).
///
/// The collage editor is ALSO drawn on the page, in the media strip, so no one
/// fixed colour can be right for it. The panel says what it is instead, and the
/// views ask it for ink by role.
final class DarkPanelInkTests: XCTestCase {

    // MARK: - Every role is measured where it is used

    /// Each role of each surface is in the shipping pair list against that
    /// surface's own fill, which is what `testEverySurfaceIsReadableAgainstWhatIsBehindIt`
    /// measures. Enumerated from the types, so a third surface or a fifth role
    /// cannot arrive unmeasured (L113).
    func testEveryInkRoleIsRegisteredAgainstItsOwnSurface() {
        for surface in InkSurface.allCases {
            let fill = PaintedSurfaces.fill(of: surface)
            for role in PaintedSurfaces.ink(on: surface).roles {
                let pair = PaintedSurfaces.all.first {
                    $0.surface == "\(surface) ink" && $0.element == role.name
                }
                XCTAssertNotNil(pair, "\(surface) ink / \(role.name) is not measured")
                XCTAssertEqual(pair.map { describe($0.background) }, describe(fill),
                               "\(surface) ink / \(role.name) is measured against the wrong fill")
            }
        }
    }

    /// The swap banner's wash is drawn over whichever surface the reel editor
    /// is on, so its words are measured over the wash on the dark panel too.
    func testTheSwapBannerIsMeasuredOnTheDarkPanel() {
        XCTAssertTrue(PaintedSurfaces.all.contains {
            $0.surface == "storyPanel ink on the swap banner" && $0.element == "strong"
        })
    }

    func testTheDarkPanelDoesNotUseThePagesInk() {
        // The defect itself, stated so a shortcut that hands the panel the
        // page's roles cannot pass by being self consistent (L70).
        let page = PaintedSurfaces.ink(on: .page)
        let panel = PaintedSurfaces.ink(on: .storyPanel)
        XCTAssertNotEqual(describe(page.sentence), describe(panel.sentence))
        XCTAssertNotEqual(describe(page.accentText), describe(panel.accentText))
    }

    // MARK: - The panel carries its ink, and the views take it

    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func code(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Painting the panel and saying what it is are one call, so a new dark
    /// panel cannot be filled while everything inside it keeps page ink.
    func testTheDarkPanelIsOnlyPaintedThroughItsModifier() throws {
        var offenders: [String] = []
        var scanned = 0
        for entry in RepoFixture.files(under: sourcesDirectory, withExtension: "swift") {
            scanned += 1
            guard !entry.relativePath.hasSuffix("PaintedSurfaces.swift") else { continue }
            if try code(at: entry.url).contains(".background(PaintedSurfaces.storyPanel)") {
                offenders.append(entry.relativePath)
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the sweep is not reading Sources at all")
        XCTAssertEqual(offenders, [],
                       "these fill the dark panel without .storyPanelSurface(), so what "
                       + "is inside it is never told it is on the dark panel")
    }

    /// The views drawn on the dark panel name no page ink of their own.
    ///
    /// A list, because which views a panel holds is decided at the call site
    /// and not visible from here. Each carries the reason it is on it, so the
    /// next one added knows what the list is for (L233).
    func testViewsDrawnOnTheDarkPanelTakeTheirInkFromTheSurface() throws {
        let onTheDarkPanel = [
            // Thursday's reel editor, only ever drawn on the panel.
            "Views/CaptionReview/ReelStripPreviewThumbnail.swift",
            // The collage editor, on the panel in caption review and on the
            // page in the media strip.
            "Views/CaptionReview/CollagePreviewThumbnail.swift",
        ]
        let pageInk = try NSRegularExpression(
            pattern: #"PaintedSurfaces\.(secondaryText|bodyText|tertiaryText|pageAccentText|iconAccent|quietMark)\b"#)
        for path in onTheDarkPanel {
            let source = try code(at: sourcesDirectory.appendingPathComponent(path))
            let matches = pageInk.matches(in: source, range: NSRange(source.startIndex..., in: source))
                .compactMap { Range($0.range, in: source).map { String(source[$0]) } }
            XCTAssertEqual(matches, [], "\(path) draws in page ink, which is unreadable on the dark panel")
        }
    }

    private func describe(_ colour: Color) -> String {
        let c = NSColor(colour).usingColorSpace(.sRGB)!
        return String(format: "%.3f %.3f %.3f %.3f",
                      c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }
}

