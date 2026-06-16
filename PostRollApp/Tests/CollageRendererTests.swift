import XCTest
import CoreGraphics

/// Regression coverage for the missing-collage-dividers bug: once the user drags
/// a divider, the override cells move off Python's baked gap positions, so the
/// composited/exported collage must repaint gap strips at the NEW boundaries or
/// the photos butt together with no visible dividers.
final class CollageRendererTests: XCTestCase {

    // Build a cell via a tiny JSON decode (matches the persisted snake_case keys).
    private func makeCell(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ name: String) -> CollageCell {
        let json = """
        {"photo_path":"\(name)","x":\(x),"y":\(y),"w":\(w),"h":\(h)}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(CollageCell.self, from: json)
    }

    func testNoGapRectsForSingleCell() {
        let cells = [makeCell(40, 0, 1000, 1912, "a")]
        XCTAssertTrue(CollageRenderer.gapRects(for: cells).isEmpty)
    }

    func testVerticalGapBetweenAdjacentCellsInRow() {
        // Two cells in one row with an 8px gap (40+575=615, next x=623).
        let cells = [
            makeCell(40, 0, 575, 279, "a"),
            makeCell(623, 0, 417, 279, "b"),
        ]
        let rects = CollageRenderer.gapRects(for: cells)
        XCTAssertEqual(rects.count, 1)
        let r = rects[0]
        XCTAssertEqual(r.minX, 615)
        XCTAssertEqual(r.width, 8)
        XCTAssertEqual(r.minY, 0)
        XCTAssertEqual(r.height, 279)
    }

    func testHorizontalGapBetweenRowsIsFullWidth() {
        // Row 1 bottom at 279, row 2 top at 287 -> 8px full-width divider.
        let cells = [
            makeCell(40, 0, 1000, 279, "a"),
            makeCell(40, 287, 1000, 255, "b"),
        ]
        let rects = CollageRenderer.gapRects(for: cells)
        XCTAssertEqual(rects.count, 1)
        let r = rects[0]
        XCTAssertEqual(r.minY, 279)
        XCTAssertEqual(r.height, 8)
        XCTAssertEqual(r.minX, 0)
        XCTAssertEqual(r.width, CollageRenderer.canvasSize.width)
    }

    func testStripBandIsNotFilled() {
        // A ~90px gap (the branded strip) must be left untouched.
        let cells = [
            makeCell(40, 0, 1000, 911, "a"),
            makeCell(40, 1001, 1000, 911, "b"),
        ]
        XCTAssertTrue(CollageRenderer.gapRects(for: cells).isEmpty)
    }

    func testRealOverrideLayoutProducesEveryDivider() {
        // The exact override saved for "American Renaissance" that triggered the
        // bug report: 2 + 2 + 1 rows above the strip, 3 + 2 rows below it.
        let cells = [
            makeCell(40, 0, 575, 279, "p1"),
            makeCell(623, 0, 417, 279, "p2"),
            makeCell(40, 287, 446, 255, "p3"),
            makeCell(494, 287, 546, 255, "p4"),
            makeCell(40, 550, 1000, 361, "p5"),
            makeCell(40, 1001, 321, 415, "p6"),
            makeCell(369, 1001, 345, 415, "p7"),
            makeCell(722, 1001, 318, 415, "p8"),
            makeCell(40, 1424, 466, 488, "p9"),
            makeCell(514, 1424, 526, 488, "p10"),
        ]
        let rects = CollageRenderer.gapRects(for: cells)

        // Vertical gaps: 1 (row1) + 1 (row2) + 2 (row4) + 1 (row5) = 5.
        let vertical = rects.filter { $0.width <= 16 }
        XCTAssertEqual(vertical.count, 5)

        // Horizontal gaps: row1|row2, row2|row3, row4|row5 = 3. The strip band
        // (row3 bottom 911 -> row4 top 1001 = 90px) is skipped.
        let horizontal = rects.filter { $0.width == CollageRenderer.canvasSize.width }
        XCTAssertEqual(horizontal.count, 3)
        XCTAssertFalse(horizontal.contains { $0.minY == 911 })

        // Every divider is the expected 8px thickness.
        for r in rects {
            XCTAssertEqual(min(r.width, r.height), 8)
        }
    }
}
