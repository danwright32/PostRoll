import XCTest

/// #468: a region that clips its content has to say so at rest.
///
/// macOS hides scrollbars until a scroll gesture starts, so an overflowing
/// region looks exactly like a complete one: the person reads what fits and
/// never learns the rest existed (L76). Hiding the indicator EXPLICITLY, on a
/// region that is also height capped, removes the last thing that would have
/// told them.
///
/// #190 fixed that for the performer suggestion list. The caption editor's left
/// column was the same shape and had never been swept, which is the usual way a
/// fixed class comes back (L30). So the question is asked of the whole tree:
/// a vertical scroll region that hides its indicator has to be a
/// `FadingScrollView`, which draws the edge itself.
final class HiddenScrollbarGuardTests: XCTestCase {

    private static var viewsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
    }

    /// Lines declaring a vertical `ScrollView` with its indicator hidden.
    ///
    /// Horizontal regions are a different question with a different answer (a
    /// row of thumbnails that continues sideways reads differently from a
    /// column of controls that continues down), so they are not in scope here
    /// and saying so is the point of the filter rather than an oversight.
    static func hiddenVerticalScrollViews(in text: String) -> [Int] {
        SwiftSourceText.withoutComments(text)
            .components(separatedBy: .newlines)
            .enumerated()
            .filter { _, line in
                line.contains("ScrollView(") && line.contains("showsIndicators: false")
                    && !line.contains(".horizontal")
            }
            .map { index, _ in index + 1 }
    }

    func testNoViewHidesAVerticalScrollbarWithoutDrawingTheEdge() throws {
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: Self.viewsDir,
                                                   includingPropertiesForKeys: nil)
        var scanned = 0
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            // The one that is allowed to: it is the thing that draws the edge.
            guard url.lastPathComponent != "FadingScrollView.swift" else { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            offenders += Self.hiddenVerticalScrollViews(in: text)
                .map { "\(url.lastPathComponent):\($0)" }
        }

        XCTAssertGreaterThan(scanned, 5, "the scan read almost no views, so it proves nothing")
        XCTAssertTrue(offenders.isEmpty, """
            These vertical scroll regions hide their indicator, and macOS hides \
            it anyway until a gesture starts, so nothing at rest says the content \
            continues past the edge and the person reads what fits.

            Use FadingScrollView, which draws the edge while there is more and \
            stops once the end is reached:

            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The component has to actually ask `ScrollEdgeFade`, in both directions.
    /// A fade drawn unconditionally is a permanent smudge over content that has
    /// ended, which is the half of L76 that stops the hint meaning anything.
    func testTheFadingScrollViewAsksAboutBothEdges() throws {
        let source = try String(
            contentsOf: Self.viewsDir.appendingPathComponent("FadingScrollView.swift"),
            encoding: .utf8)
        let code = SwiftSourceText.withoutComments(source)

        XCTAssertTrue(code.contains("ScrollEdgeFade.showsTop"),
                      "the top edge is not asked about, so it either never fades or always does")
        XCTAssertTrue(code.contains("ScrollEdgeFade.showsBottom"),
                      "the bottom edge is not asked about")
    }

    func testTheScannerSeesTheShapeItLooksFor() {
        XCTAssertEqual(
            Self.hiddenVerticalScrollViews(in: "ScrollView(.vertical, showsIndicators: false) {"),
            [1])
    }

    func testAHorizontalRegionIsNotInScope() {
        XCTAssertTrue(Self.hiddenVerticalScrollViews(
            in: "ScrollView(.horizontal, showsIndicators: false) {").isEmpty)
    }

    /// A comment describing the shape is not the shape (L103).
    func testACommentIsNotAScrollView() {
        XCTAssertTrue(Self.hiddenVerticalScrollViews(
            in: "// was ScrollView(.vertical, showsIndicators: false) once").isEmpty)
    }
}
