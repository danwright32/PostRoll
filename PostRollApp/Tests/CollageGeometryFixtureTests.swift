import XCTest

/// #168: the Swift crop geometry satisfies the same contract as the Python one.
///
/// `CollageGeometry.placement` draws the live editor and the SwiftUI export
/// compositor. `crop_to_fill` in `postroll/media/generate_collage.py` renders
/// the Thursday reel strip, the exported MP4 and the collage base PNG. The math
/// is written twice, in two languages, and nothing but the shared fixture stops
/// the two drifting. When they drift Dan sees one framing on screen and gets
/// another in the exported file, which makes the preview a liar. It has already
/// shipped once, as a 0.4-versus-0.5 vertical bias.
///
/// The fixture is read from the repo, not copied into the bundle: a copied file
/// is a second version able to drift from the one Python reads, which is the
/// whole thing being fixed.
final class CollageGeometryFixtureTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Expected: Decodable {
            let rendered_w: Double
            let rendered_h: Double
            let draw_x: Double
            let draw_y: Double
        }
        struct Case: Decodable {
            let name: String
            let photo_w: Double
            let photo_h: Double
            let cell_w: Double
            let cell_h: Double
            let offset_x: Double
            let offset_y: Double
            let zoom: Double
            let expected: Expected
        }
        let zoom_floor: Double
        let top_anchored_y: Double
        let tolerance_px: Double
        let cases: [Case]
    }

    private func loadFixture() throws -> Fixture {
        return try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/crop_geometry.json"))
    }

    func testSwiftSatisfiesTheSharedCropContract() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 10,
                                    "an empty or gutted fixture would pass vacuously")

        for c in fixture.cases {
            let (rendered, committed) = CollageGeometry.placement(
                photoRatio: CGFloat(c.photo_w / c.photo_h),
                cellW: CGFloat(c.cell_w),
                cellH: CGFloat(c.cell_h),
                offset: CropOffset(x: c.offset_x, y: c.offset_y, scale: c.zoom))

            XCTAssertEqual(Double(rendered.width), c.expected.rendered_w,
                           accuracy: fixture.tolerance_px, "\(c.name): rendered width")
            XCTAssertEqual(Double(rendered.height), c.expected.rendered_h,
                           accuracy: fixture.tolerance_px, "\(c.name): rendered height")
            XCTAssertEqual(Double(committed.width), c.expected.draw_x,
                           accuracy: fixture.tolerance_px, "\(c.name): horizontal draw offset")
            XCTAssertEqual(Double(committed.height), c.expected.draw_y,
                           accuracy: fixture.tolerance_px, "\(c.name): vertical draw offset")
        }
    }

    /// The fixture states the rule's two magic numbers. If Swift moves one and
    /// the fixture does not, every expected value above is being measured
    /// against a rule this side no longer follows.
    func testTheFixtureConstantsMatchThisSide() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(CropOffset.topAnchoredY, fixture.top_anchored_y)

        // The zoom floor is applied inside `placement` rather than exposed, so
        // it is asserted by behaviour: anything below the floor must render at
        // exactly the floor's size.
        let below = CollageGeometry.placement(
            photoRatio: 1.5, cellW: 340, cellH: 500,
            offset: CropOffset(x: 0, y: -1, scale: 0.01))
        let atFloor = CollageGeometry.placement(
            photoRatio: 1.5, cellW: 340, cellH: 500,
            offset: CropOffset(x: 0, y: -1, scale: fixture.zoom_floor))
        XCTAssertEqual(below.rendered, atFloor.rendered)
        XCTAssertEqual(below.committed, atFloor.committed)
    }

    /// Below fill there is nothing to discard, so an offset cannot pan the
    /// photo. The editor enforces this by refusing to commit a pan on an axis
    /// without overflow, and the renderers have to agree or a leftover offset
    /// from a larger zoom moves the export away from the preview.
    func testAnOffsetCannotPanAnAxisThatHasSlack() {
        let centred = CollageGeometry.placement(
            photoRatio: 1.5, cellW: 500, cellH: 340,
            offset: CropOffset(x: 0, y: -1, scale: 0.5))
        let hardLeft = CollageGeometry.placement(
            photoRatio: 1.5, cellW: 500, cellH: 340,
            offset: CropOffset(x: -1, y: -1, scale: 0.5))
        let hardRight = CollageGeometry.placement(
            photoRatio: 1.5, cellW: 500, cellH: 340,
            offset: CropOffset(x: 1, y: 1, scale: 0.5))

        XCTAssertEqual(centred.committed, hardLeft.committed)
        XCTAssertEqual(centred.committed, hardRight.committed)
    }
}
