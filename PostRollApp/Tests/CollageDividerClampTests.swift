import XCTest

/// #965: the branded strip is not a boundary anyone may drag, and no drag may
/// squeeze a cell past its floor.
///
/// Dragging the divider directly above the branded centre strip let the top row
/// grow down over the title band. The title disappeared behind the photograph,
/// the row below was squeezed past its floor into a NEGATIVE height, and the
/// stale base PNG showed through the uncovered strip, so the same photo
/// appeared twice. It is not preview only: `CollageRenderer.render` composites
/// the same override cells over the same base PNG, so the broken layout is what
/// gets exported and what is written back to events.json.
///
/// Three faults on one drag, and all three are here:
///
/// 1. The strip boundary got a drag handle although the type's own comment said
///    it must not be dragged. Only the gap fill honoured that.
/// 2. The clamp measured from the row below's top and subtracted a hardcoded
///    8px gap rather than this divider's real one, overshooting by 82px on a
///    90px band.
/// 3. Nothing repainted the band a drag vacated. That one is a consequence of
///    the first two: with the strip boundary immovable, no cell can cross the
///    band, so nothing can uncover it.
final class CollageDividerClampTests: XCTestCase {

    /// Python's own numbers, from `generate_collage.py`.
    private let stripHeight = 90
    private let ordinaryGap = 8
    /// `computeCollageDividers`' floor for a cell's smaller dimension.
    private let minCellPx = 80

    private func cell(_ name: String, x: Int, y: Int, w: Int, h: Int) -> CollageCell {
        CollageCell(photoPath: "/\(name).jpg", x: x, y: y, w: w, h: h)
    }

    /// The shape Dan reported it on: a full width photo, the branded strip, a
    /// two photo row, then a full width photo.
    private func batteryDanceShape() -> [CollageCell] {
        let top = 0
        let topH = 400
        let stripTop = top + topH
        let rowTop = stripTop + stripHeight
        let rowH = 300
        let bottomTop = rowTop + rowH + ordinaryGap
        return [
            cell("top", x: 0, y: top, w: 1080, h: topH),
            cell("mid-left", x: 0, y: rowTop, w: 536, h: rowH),
            cell("mid-right", x: 544, y: rowTop, w: 536, h: rowH),
            cell("bottom", x: 0, y: bottomTop, w: 1080, h: 380),
        ]
    }

    private func horizontals(_ cells: [CollageCell]) -> [CollageDivider] {
        computeCollageDividers(cells).filter { $0.kind == .horizontal }
    }

    // MARK: - The strip is not a gap

    func testTheStripBoundaryIsRecognisedAsTheBrandedStrip() {
        let strip = horizontals(batteryDanceShape())
            .first { $0.actualGapPx == stripHeight }
        XCTAssertNotNil(strip, "the shape under test has no strip boundary in it")
        XCTAssertTrue(strip!.isBrandedStrip)
        XCTAssertFalse(strip!.isDraggable)
    }

    func testAnOrdinaryRowBoundaryIsStillDraggable() {
        // The positive control. Without it every assertion here is satisfied by
        // a rule that refuses every divider, which would take the editor away
        // rather than fix it (L159).
        let ordinary = horizontals(batteryDanceShape())
            .first { $0.actualGapPx == ordinaryGap }
        XCTAssertNotNil(ordinary, "the shape under test has no ordinary boundary in it")
        XCTAssertTrue(ordinary!.isDraggable)
    }

    func testADragOnTheStripBoundaryChangesNothing() {
        // The effect, not the handle. Hiding the handle is what stops a person
        // reaching it; refusing here is what makes the drag unable to corrupt
        // the layout whatever draws a handle (L196).
        let cells = batteryDanceShape()
        let strip = horizontals(cells).first { $0.isBrandedStrip }!
        XCTAssertEqual(applyCollageDividerDelta(to: cells, divider: strip, delta: 200), cells)
        XCTAssertEqual(applyCollageDividerDelta(to: cells, divider: strip, delta: -200), cells)
    }

    // MARK: - No drag squeezes a cell past its floor

    func testDraggingAnOrdinaryBoundaryToItsCeilingLeavesTheFloorExactlyMet() {
        // The quantity being protected, not a proxy for it (L63). The old clamp
        // left the shortest cell below at minus two pixels here.
        let cells = batteryDanceShape()
        for divider in horizontals(cells) where divider.isDraggable {
            let maxDelta = divider.maxPos - divider.canvasPos
            let dragged = applyCollageDividerDelta(to: cells, divider: divider, delta: maxDelta)
            let shortest = divider.trailing.map { dragged[$0].h }.min()!
            XCTAssertEqual(shortest, minCellPx,
                           "the ceiling leaves the shortest cell below at \(shortest)px")
        }
    }

    /// A layout whose row gap is the widest an ORDINARY boundary can have.
    ///
    /// 16px is still draggable, and it is where the two formulas part company:
    /// the old one subtracted a fixed 8 from the row below's top, so it left
    /// this drag 8px of overshoot and a 72px cell. In the shape Dan reported it
    /// on, every draggable gap happens to be exactly 8, where the two agree, so
    /// a fixture built only from that shape cannot tell them apart (L504).
    private func widestOrdinaryGapShape() -> [CollageCell] {
        let gap = CollageDivider.maxOrdinaryGapPx
        return [
            cell("top", x: 0, y: 0, w: 1080, h: 400),
            cell("below", x: 0, y: 400 + gap, w: 1080, h: 300),
        ]
    }

    func testNoDragInEitherDirectionEverProducesACellUnderTheFloor() {
        for cells in [batteryDanceShape(), widestOrdinaryGapShape()] {
        for divider in computeCollageDividers(cells) {
            for delta in stride(from: -600, through: 600, by: 7) {
                let dragged = applyCollageDividerDelta(to: cells, divider: divider, delta: delta)
                for c in dragged {
                    XCTAssertGreaterThanOrEqual(
                        min(c.w, c.h), minCellPx,
                        "a \(divider.kind) drag of \(delta) left a cell at \(c.w)x\(c.h)")
                }
            }
        }
        }
    }

    func testTheCeilingDoesNotDependOnTheGapAboveIt() {
        // The actual defect in the arithmetic: the clamp subtracted the LOCAL
        // 8px gap rather than this divider's own, so the wider the real gap the
        // further the overshoot. Two shapes identical but for the gap must give
        // the same room to drag.
        func room(gap: Int) -> Int {
            let cells = [
                cell("top", x: 0, y: 0, w: 1080, h: 400),
                cell("below", x: 0, y: 400 + gap, w: 1080, h: 300),
            ]
            let d = horizontals(cells)[0]
            return d.maxPos - d.canvasPos
        }
        XCTAssertEqual(room(gap: ordinaryGap), room(gap: stripHeight))
        XCTAssertEqual(room(gap: ordinaryGap), 300 - minCellPx)
    }
}
