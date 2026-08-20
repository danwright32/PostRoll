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
    let actualGapPx: Int    // true pixel gap to the trailing row — ~8 for normal rows,
                            // ~90 for the strip divider (which should not be dragged or filled)
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
        let maxPos   = belowTop + (below.map { $0.h }.min()! - minCellPx) - gap
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
