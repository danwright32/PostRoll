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

    // MARK: - Hairline

    /// The ring must land immediately OUTSIDE the cell, never inside it, or the
    /// line eats a row of the photograph. Stroking a rect with lineWidth 1
    /// centres the line on the rect's edge, so the rect has to be outset by half
    /// the line width: centred on x - 0.5, the stroke covers pixel column x - 1.
    /// This is the same ring generate_collage.py bakes into the base PNG
    /// (draw_hairlines), and the two must not drift by a pixel or the export
    /// shows a doubled line.
    func testHairlineRectSitsJustOutsideTheCell() {
        let ring = CollageGeometry.hairlineRect(x: 48, y: 100, w: 984, h: 400)
        XCTAssertEqual(ring.minX, 47.5)
        XCTAssertEqual(ring.minY, 99.5)
        XCTAssertEqual(ring.maxX, 1032.5)
        XCTAssertEqual(ring.maxY, 500.5)
        // The cell itself is fully enclosed, so no stroke falls inside it.
        XCTAssertTrue(ring.contains(CGRect(x: 48, y: 100, width: 984, height: 400)))
    }

    func testHairlineRectGrowsByExactlyOneLineWidth() {
        let ring = CollageGeometry.hairlineRect(x: 0, y: 0, w: 100, h: 50)
        XCTAssertEqual(ring.width, 100 + CollageGeometry.hairlineWidth)
        XCTAssertEqual(ring.height, 50 + CollageGeometry.hairlineWidth)
    }
}

/// Dan shoots performing arts: the subject sits in the upper part of the frame,
/// so a centred crop quietly eats into it. Every surface that auto-crops now
/// discards from the BOTTOM only, and the top of the photograph always survives
/// (#167). Both draw paths take their unset offset from `CropOffset()`, so the
/// default is the whole of the change and is pinned here.
final class TopAnchoredCropTests: XCTestCase {

    func testAnUnsetOffsetKeepsTheTopOfThePhoto() {
        // A 1:2 portrait photo in a 100×100 cell overflows vertically by 100.
        let p = CollageGeometry.placement(
            photoRatio: 0.5, cellW: 100, cellH: 100, offset: CropOffset())

        XCTAssertEqual(p.rendered.height, 200, accuracy: 0.001)
        XCTAssertEqual(p.committed.height, 0, accuracy: 0.001,
                       "0 means the photo's top row sits on the cell's top edge, so the crop comes off the bottom")
    }

    func testACentredCropIsNoLongerTheDefault() {
        let centred = CollageGeometry.placement(
            photoRatio: 0.5, cellW: 100, cellH: 100, offset: CropOffset(x: 0, y: 0, scale: 1))

        XCTAssertEqual(centred.committed.height, -50, accuracy: 0.001,
                       "explicitly centred still centres")
        XCTAssertNotEqual(centred.committed.height, CollageGeometry.placement(
            photoRatio: 0.5, cellW: 100, cellH: 100, offset: CropOffset()).committed.height,
                          "the default must not be the centred value any more")
    }

    func testAnExplicitUserCropStillWins() {
        let bottom = CollageGeometry.placement(
            photoRatio: 0.5, cellW: 100, cellH: 100, offset: CropOffset(x: 0, y: 1, scale: 1))

        XCTAssertEqual(bottom.committed.height, -100, accuracy: 0.001,
                       "dragging to keep the bottom still keeps the bottom")
    }

    func testAZoomedOutPhotoStaysCentredRatherThanPinningToTheTop() {
        // scale < 1: the photo is smaller than its cell and sits on a blurred
        // background. There is no crop to take off the bottom, so the default
        // must not shove it against the top edge.
        let p = CollageGeometry.placement(
            photoRatio: 1.0, cellW: 100, cellH: 100, offset: CropOffset(x: 0, y: -1, scale: 0.5))

        XCTAssertEqual(p.rendered.height, 50, accuracy: 0.001)
        XCTAssertEqual(p.committed.height, 25, accuracy: 0.001, "centred in the cell")
    }

    func testTheDefaultIsTopAnchoredOnTheModelItself() {
        XCTAssertEqual(CropOffset().y, -1.0)
        XCTAssertEqual(CropOffset().x, 0.0, "horizontal framing is unchanged")
        XCTAssertEqual(CropOffset().scale, 1.0)
    }

    func testAStoredOffsetWithNoYDecodesTopAnchored() throws {
        let json = Data(#"{"x":0.2,"scale":1.0}"#.utf8)

        let decoded = try JSONDecoder().decode(CropOffset.self, from: json)

        XCTAssertEqual(decoded.y, -1.0)
        XCTAssertEqual(decoded.x, 0.2, accuracy: 0.0001)
    }
}
