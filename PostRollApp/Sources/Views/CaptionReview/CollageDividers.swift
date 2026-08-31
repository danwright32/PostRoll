import SwiftUI


/// A draggable boundary between adjacent collage rows (horizontal) or columns (vertical).
/// Internal rather than private since `CollageDividerHandle` moved to its own
/// file (#718): the handle is the only thing that draws one.
struct CollageDivider {
    enum Kind { case horizontal, vertical }
    let kind: Kind
    let canvasPos: Int      // boundary position in canvas px: y for H, x for V
    let leading: [Int]      // cell indices on the top / left side of the boundary
    let trailing: [Int]     // cell indices on the bottom / right side
    let minPos: Int         // drag clamp — boundary cannot go below this
    let maxPos: Int         // drag clamp — boundary cannot go above this
    let rowCanvasY: Int     // top of the row (vertical dividers only)
    let rowCanvasH: Int     // height of the row (vertical dividers only)
    let actualGapPx: Int    // true pixel gap to the trailing row: about 8 for
                            // normal rows, about 90 for the branded strip
}

extension CollageDivider {
    /// The widest gap an ordinary row boundary has.
    ///
    /// Above it is the branded centre strip, which is not a gap at all: it is
    /// the 90px band Python draws the event title and the wordmark into
    /// (`generate_collage.STRIP_H`).
    static let maxOrdinaryGapPx = 16

    /// Whether this boundary is the branded strip rather than a gap between
    /// two rows.
    ///
    /// A comment on `actualGapPx` already said this divider must not be dragged
    /// or filled, and only the fill honoured it, by testing `<= 16` inline. The
    /// handle loop iterated every divider, so the one boundary that must not
    /// move was the one carrying a full drag handle: dragging it grew the top
    /// row down over the title band, squeezed the row below past its floor, and
    /// left the stale base PNG showing through the uncovered strip, which is
    /// the same photograph appearing twice (#965).
    ///
    /// A property rather than the number written at each call site, so the two
    /// consumers cannot end up disagreeing about which divider this is (L263).
    var isBrandedStrip: Bool { actualGapPx > Self.maxOrdinaryGapPx }

    /// Whether a person may move this boundary.
    var isDraggable: Bool { !isBrandedStrip }
}
/// Infer all row/column boundaries from a flat list of canvas cells.
func computeCollageDividers(_ cells: [CollageCell]) -> [CollageDivider] {
    guard cells.count > 1 else { return [] }
    let gap = 8
    let minCellPx = 80  // minimum cell dimension in canvas pixels

    // Group cells into horizontal rows by y-overlap (shared with the export
    // renderer's gap-fill rects so the two agree on row boundaries).
    let rows = CollageGeometry.groupCellsByRow(cells)

    var result: [CollageDivider] = []

    // Horizontal dividers — one between each consecutive row pair
    for i in 0..<rows.count - 1 {
        let above = rows[i], below = rows[i + 1]
        let boundary     = above.map { $0.y + $0.h }.max()!
        let belowTop     = below.map { $0.y }.min()!
        let actualGapH   = belowTop - boundary
        let leadIdx  = above.compactMap { c in cells.firstIndex { $0.photoPath == c.photoPath } }
        let trailIdx = below.compactMap { c in cells.firstIndex { $0.photoPath == c.photoPath } }
        let minPos   = above.map { $0.y }.min()! + minCellPx
        // From the BOUNDARY, and with no gap term (#965).
        //
        // Dragging down by `delta` moves the boundary to `boundary + delta` and
        // sets every below cell to `h - delta`, so the shortest of them reaches
        // its floor at `delta == minCellH - minCellPx`. The old form measured
        // from `belowTop` and then subtracted the LOCAL `gap` of 8 rather than
        // this divider's own gap, which overshoots by `actualGapH - 8`. On the
        // branded strip that is 82px of a 90px band, and it put the shortest
        // cell below at a height of -2.
        let maxPos   = boundary + (below.map { $0.h }.min()! - minCellPx)
        result.append(CollageDivider(
            kind: .horizontal, canvasPos: boundary,
            leading: leadIdx, trailing: trailIdx,
            minPos: minPos, maxPos: maxPos,
            rowCanvasY: 0, rowCanvasH: 0,
            actualGapPx: actualGapH
        ))
    }

    // Vertical dividers — one between each horizontally adjacent pair within a row
    for row in rows {
        let sorted  = row.sorted { $0.x < $1.x }
        let rowY    = row.map { $0.y }.min()!
        let rowH    = row.map { $0.y + $0.h }.max()! - rowY
        for i in 0..<sorted.count - 1 {
            let left = sorted[i], right = sorted[i + 1]
            let boundary = left.x + left.w + gap / 2
            let leftIdx  = cells.firstIndex { $0.photoPath == left.photoPath }!
            let rightIdx = cells.firstIndex { $0.photoPath == right.photoPath }!
            let minPos   = left.x + minCellPx + gap / 2
            let maxPos   = right.x + right.w - minCellPx - gap / 2
            result.append(CollageDivider(
                kind: .vertical, canvasPos: boundary,
                leading: [leftIdx], trailing: [rightIdx],
                minPos: minPos, maxPos: maxPos,
                rowCanvasY: rowY, rowCanvasH: rowH,
                actualGapPx: gap
            ))
        }
    }

    return result
}
/// Apply a drag delta (canvas pixels) to cells on both sides of a divider.
func applyCollageDividerDelta(
    to cells: [CollageCell], divider: CollageDivider, delta: Int
) -> [CollageCell] {
    // Refused here as well as hidden in the view (#965). Hiding the handle is
    // what stops a person reaching this boundary; refusing the effect is what
    // makes the drag unable to corrupt the layout whatever draws a handle, and
    // a control that exists only where it is drawn is a control the next screen
    // to render one of these gets for free (L196).
    guard divider.isDraggable else { return cells }
    let clamped = min(max(delta, divider.minPos - divider.canvasPos),
                      divider.maxPos - divider.canvasPos)
    var result = cells
    switch divider.kind {
    case .horizontal:
        // Above cells grow/shrink in height; below cells shift down and shrink/grow.
        for idx in divider.leading  { result[idx].h += clamped }
        for idx in divider.trailing { result[idx].y += clamped; result[idx].h -= clamped }
    case .vertical:
        // Left cells grow/shrink in width; right cells shift right and shrink/grow.
        for idx in divider.leading  { result[idx].w += clamped }
        for idx in divider.trailing { result[idx].x += clamped; result[idx].w -= clamped }
    }
    return result
}
