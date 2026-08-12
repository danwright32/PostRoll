import XCTest
import CoreGraphics

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
