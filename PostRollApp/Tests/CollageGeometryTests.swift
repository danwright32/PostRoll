import XCTest
import CoreGraphics

/// Covers the shared collage geometry that the live editor and the export
/// renderer both draw from. Pinning these formulas is what keeps the two
/// paths from drifting (the crop Y-bias 0.4↔0.5 class of bug).
final class CollageGeometryTests: XCTestCase {

    // MARK: - Fill mode

    func testIsFillModeThresholdAtScaleOne() {
        XCTAssertTrue(CollageGeometry.isFillMode(scale: 1.0))
        XCTAssertTrue(CollageGeometry.isFillMode(scale: 1.5))
        XCTAssertFalse(CollageGeometry.isFillMode(scale: 0.99))
    }

    // MARK: - Blur opacity ramp

    func testBlurOpacityRamp() {
        XCTAssertEqual(CollageGeometry.blurOpacity(scale: 1.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(CollageGeometry.blurOpacity(scale: 0.75), 1.0, accuracy: 0.0001)
        // Clamps to 1 below 0.75 and never goes negative above 1.
        XCTAssertEqual(CollageGeometry.blurOpacity(scale: 0.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(CollageGeometry.blurOpacity(scale: 1.5), 0.0, accuracy: 0.0001)
        XCTAssertEqual(CollageGeometry.blurOpacity(scale: 0.9), 0.4, accuracy: 0.0001)
    }

    // MARK: - Placement / crop math

    func testCenteredFillUsesHalfBias() {
        // A 2:1 landscape photo in a 100×100 cell at scale 1, offset 0 → it
        // overflows horizontally and is centred: committed.x = -overflow/2.
        let p = CollageGeometry.placement(
            photoRatio: 2.0, cellW: 100, cellH: 100, offset: CropOffset())
        XCTAssertEqual(p.rendered.width, 200, accuracy: 0.001)
        XCTAssertEqual(p.rendered.height, 100, accuracy: 0.001)
        // overflow.width = 100, centred → -100 * (0.5 + 0) = -50
        XCTAssertEqual(p.committed.width, -50, accuracy: 0.001)
        // No vertical overflow → centred at (cellH - rendered.height)/2 = 0
        XCTAssertEqual(p.committed.height, 0, accuracy: 0.001)
    }

    func testYBiasIsHalfNotPointFour() {
        // A 1:2 portrait photo in a 100×100 cell overflows vertically. At
        // offset.y = +1 the committed offset must pin the bottom edge:
        // committed.y = -overflow.height * (0.5 + 1*0.5) = -overflow.height.
        // With the regressed 0.4 bias it would be -overflow.height*0.9.
        let p = CollageGeometry.placement(
            photoRatio: 0.5, cellW: 100, cellH: 100, offset: CropOffset(x: 0, y: 1, scale: 1))
        XCTAssertEqual(p.rendered.height, 200, accuracy: 0.001)
        let overflowH = p.rendered.height - 100
        XCTAssertEqual(p.committed.height, -overflowH, accuracy: 0.001)
    }

    func testZoomScalesRenderedSize() {
        let p = CollageGeometry.placement(
            photoRatio: 1.0, cellW: 100, cellH: 100, offset: CropOffset(x: 0, y: 0, scale: 2))
        XCTAssertEqual(p.rendered.width, 200, accuracy: 0.001)
        XCTAssertEqual(p.rendered.height, 200, accuracy: 0.001)
    }

    // MARK: - Row grouping

    func testGroupCellsByRowSplitsByVerticalOverlap() {
        func cell(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CollageCell {
            CollageCell(photoPath: "/\(x)_\(y).jpg", x: x, y: y, w: w, h: h)
        }
        // Two cells side by side on top (row 1), one full-width below (row 2).
        let cells = [
            cell(0, 0, 500, 400),
            cell(540, 0, 500, 400),
            cell(0, 420, 1040, 400),
        ]
        let rows = CollageGeometry.groupCellsByRow(cells)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[1].count, 1)
    }

    func testGroupCellsByRowEmpty() {
        XCTAssertTrue(CollageGeometry.groupCellsByRow([]).isEmpty)
    }
}
