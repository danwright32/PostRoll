import XCTest

/// #969: the editor's gutter is the one Python drew.
///
/// The gutter between collage tiles was written twice with different values:
/// `let gap = 8` in `CollageDividers.swift` against `GUTTER = 16` in
/// `postroll/media/design_tokens.py`. Python bakes 16px gaps into the base PNG
/// and the editor computed vertical divider positions and drag clamps as though
/// they were 8, so every vertical boundary sat 4px off the gap it was supposed
/// to be centred in, and a drag could squeeze a cell 4px past the 80px floor
/// the save is refused under.
///
/// `tests/fixtures/collage_gutter.json` states the gutter once and carries real
/// layouts from `plan_collage_cells`, so the cells here are what Python
/// actually draws rather than a shape chosen to pass. The Python side asserts
/// those layouts still hold that gutter; this side asserts the editor's
/// geometry is computed from it.
final class CollageGutterParityTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Cell: Decodable {
            let photo_path: String
            let x: Int
            let y: Int
            let w: Int
            let h: Int
        }
        struct Case: Decodable {
            let name: String
            let strip_y: Int
            let cells: [Cell]
        }
        let gutter_px: Int
        let strip_h_px: Int
        let min_cell_px: Int
        let cases: [Case]
    }

    private func loadFixture() throws -> Fixture {
        try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/collage_gutter.json"))
    }

    private func cells(_ c: Fixture.Case) -> [CollageCell] {
        c.cells.map { CollageCell(photoPath: $0.photo_path, x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
    }

    /// Without this every assertion below runs zero times and reports green.
    func testTheContractCarriesLayoutsWithVerticalBoundariesInThem() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 4, "the contract has lost its cases")
        var verticals = 0
        for c in fixture.cases {
            verticals += computeCollageDividers(cells(c)).filter { $0.kind == .vertical }.count
        }
        XCTAssertGreaterThanOrEqual(verticals, 8,
            "no vertical dividers in the contract, so nothing below is measuring one")
    }

    func testTheFloorHoldsAtTheGutterPythonDrew() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(minCollageCellPx, fixture.min_cell_px,
                       "the editor's floor is not the one the contract states")

        for c in fixture.cases {
            let all = cells(c)
            for divider in computeCollageDividers(all) where divider.kind == .vertical {
                let left = all[divider.leading[0]]
                let right = all[divider.trailing[0]]
                let drawnGap = right.x - (left.x + left.w)

                XCTAssertEqual(drawnGap, fixture.gutter_px,
                    "\(c.name): the fixture's own layout does not carry the stated gutter")

                XCTAssertEqual(divider.actualGapPx, drawnGap,
                    "\(c.name): the divider reports a \(divider.actualGapPx)px gap where "
                    + "Python drew \(drawnGap)px")

                XCTAssertEqual(divider.canvasPos, left.x + left.w + drawnGap / 2,
                    "\(c.name): the handle is not centred in the gap Python drew")

                // The clamp is the thing a person actually hits, so it is
                // driven through the real drag rather than by restating its
                // arithmetic here: a test that recomputes the formula agrees
                // with itself whatever the formula is (L107).
                //
                // Dragged as far as it will go, a boundary must leave the cell
                // it is squeezing exactly at the floor, not inside it. The
                // floor a drag stops at and the floor a save is refused under
                // have to be the same number (#967), and with an 8px gutter
                // against Python's 16 this landed at 76.
                let hardLeft = applyCollageDividerDelta(
                    to: all, divider: divider, delta: -Int(1e6))
                XCTAssertEqual(hardLeft[divider.leading[0]].w, fixture.min_cell_px,
                    "\(c.name): dragging fully left leaves the left cell "
                    + "\(hardLeft[divider.leading[0]].w)px wide, not the "
                    + "\(fixture.min_cell_px)px floor a save is refused under")

                let hardRight = applyCollageDividerDelta(
                    to: all, divider: divider, delta: Int(1e6))
                XCTAssertEqual(hardRight[divider.trailing[0]].w, fixture.min_cell_px,
                    "\(c.name): dragging fully right leaves the right cell "
                    + "\(hardRight[divider.trailing[0]].w)px wide, not the "
                    + "\(fixture.min_cell_px)px floor a save is refused under")

                // And the gutter itself survives the drag: the two cells must
                // still be the gutter apart afterwards, or the editor has just
                // written a layout the base PNG does not match.
                XCTAssertEqual(
                    hardLeft[divider.trailing[0]].x
                        - (hardLeft[divider.leading[0]].x + hardLeft[divider.leading[0]].w),
                    drawnGap,
                    "\(c.name): the gutter changed width during a drag")
            }
        }
    }

    /// An ordinary gap must not be mistaken for the branded strip.
    ///
    /// `isBrandedStrip` is `actualGapPx > normalGapLimit`, and the gutter is
    /// exactly the limit, so there is no margin at all: a gutter one pixel
    /// wider would make every ordinary divider read as the band that must never
    /// be dragged, and the editor would silently lose all of its handles.
    func testAnOrdinaryGutterIsStillWiderThanNoMarginFromTheStrip() throws {
        let fixture = try loadFixture()
        XCTAssertLessThanOrEqual(fixture.gutter_px, CollageGeometry.normalGapLimit,
            "a \(fixture.gutter_px)px gutter is past the \(CollageGeometry.normalGapLimit)px "
            + "limit, so every ordinary divider now reads as the branded strip and cannot "
            + "be dragged at all")
        XCTAssertLessThan(CollageGeometry.normalGapLimit, fixture.strip_h_px,
            "the limit has reached the branded strip's own height, so the one boundary "
            + "that must never move would read as an ordinary gap")
    }
}
