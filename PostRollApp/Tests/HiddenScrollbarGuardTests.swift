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
/// a scroll region that hides its indicator has to be a `FadingScrollView`,
/// which draws the edge itself.
///
/// #468 scoped this to vertical regions and said so, on the reasoning that a row
/// of thumbnails reads differently from a column of controls. It reads
/// differently and it fails identically: a strip that continues sideways looks
/// exactly like one that ends, and the person scrolls neither. #539 widened the
/// scan to both axes and taught FadingScrollView the horizontal case.
final class HiddenScrollbarGuardTests: XCTestCase {

    private static var viewsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
    }

    /// Lines declaring a `ScrollView` with its indicator hidden, on either axis.
    static func hiddenScrollViews(in text: String) -> [Int] {
        SwiftSourceText.withoutComments(text)
            .components(separatedBy: .newlines)
            .enumerated()
            .filter { _, line in
                line.contains("ScrollView(") && line.contains("showsIndicators: false")
            }
            .map { index, _ in index + 1 }
    }

    func testNoViewHidesAScrollbarWithoutDrawingTheEdge() throws {
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
            offenders += Self.hiddenScrollViews(in: text)
                .map { "\(url.lastPathComponent):\($0)" }
        }

        XCTAssertGreaterThan(scanned, 5, "the scan read almost no views, so it proves nothing")
        XCTAssertTrue(offenders.isEmpty, """
            These scroll regions hide their indicator, and macOS hides \
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

        XCTAssertTrue(code.contains("ScrollEdgeFade.showsLeadingEdge"),
                      "the near edge is not asked about, so it either never fades or always does")
        XCTAssertTrue(code.contains("ScrollEdgeFade.showsTrailingEdge"),
                      "the far edge is not asked about")
    }

    func testTheScannerSeesTheShapeItLooksFor() {
        XCTAssertEqual(
            Self.hiddenScrollViews(in: "ScrollView(.vertical, showsIndicators: false) {"),
            [1])
    }

    func testAHorizontalRegionIsInScopeToo() {
        XCTAssertEqual(
            Self.hiddenScrollViews(in: "ScrollView(.horizontal, showsIndicators: false) {"),
            [1], "a strip that continues sideways fails the same way a column does (#539)")
    }

    /// A comment describing the shape is not the shape (L103).
    func testACommentIsNotAScrollView() {
        XCTAssertTrue(Self.hiddenScrollViews(
            in: "// was ScrollView(.vertical, showsIndicators: false) once").isEmpty)
    }
}
