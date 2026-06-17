import SwiftUI
import CoreGraphics

/// Single source of the collage crop/zoom/blur/gap geometry.
///
/// The live editor (`CollageCellOverlay` in CaptionReviewView) and the
/// export/preview renderer (`CollageRenderer` / `StaticCollageView`) are two
/// separate draw paths that must produce pixel-identical output. They kept
/// drifting when the math was duplicated by hand (the crop Y-bias 0.4↔0.5 bug,
/// the missing gap dividers). Both paths now compute their geometry here so a
/// change lands in one place.
enum CollageGeometry {
    static let canvasSize = CGSize(width: 1080, height: 1920)

    /// Gaps up to this many canvas px are real cell dividers (~8px); anything
    /// wider is the ~90px branded centre strip and is left untouched.
    static let normalGapLimit = 16

    static let blurRadius: CGFloat = 24
    /// Opaque base painted behind a zoomed-out photo so the base PNG can't bleed
    /// through the Gaussian filter's translucent edge fringe.
    static let blurBackgroundColor = Color(white: 0.08)
    /// Darkening scrim multiplier over the blurred background.
    static let scrimDarkness: Double = 0.3

    /// Photo overflows its cell (zoomed in) at scale ≥ 1; below that it's the
    /// zoomed-out "blur" presentation centred over a blurred background.
    static func isFillMode(scale: Double) -> Bool { scale >= 1.0 }

    /// Blur background opacity: 0 at scale 1, ramping to 1 by scale 0.75.
    static func blurOpacity(scale: Double) -> Double {
        max(0, min(1, (1.0 - scale) * 4))
    }

    /// The rendered photo size and committed (bias-centred) draw offset for a
    /// photo of aspect `photoRatio` filling a `cellW`×`cellH` cell under `offset`.
    /// This is the crop/pan math both draw paths share — the editor adds live
    /// drag translation on top of `committed`; the renderer uses it as-is.
    static func placement(
        photoRatio: CGFloat, cellW: CGFloat, cellH: CGFloat, offset: CropOffset
    ) -> (rendered: CGSize, committed: CGSize) {
        let zoom = CGFloat(max(0.25, offset.scale))
        let rendered: CGSize = photoRatio > cellW / cellH
            ? CGSize(width: cellH * photoRatio * zoom, height: cellH * zoom)   // landscape in portrait cell
            : CGSize(width: cellW * zoom, height: cellW / photoRatio * zoom)   // portrait/square

        let overflowW = rendered.width - cellW
        let overflowH = rendered.height - cellH
        let committedW: CGFloat = overflowW > 0
            ? -overflowW * (0.5 + CGFloat(offset.x) * 0.5)
            : (cellW - rendered.width) / 2
        let committedH: CGFloat = overflowH > 0
            ? -overflowH * (0.5 + CGFloat(offset.y) * 0.5)
            : (cellH - rendered.height) / 2
        return (rendered, CGSize(width: committedW, height: committedH))
    }

    /// Group cells into horizontal rows by vertical overlap — the basis for both
    /// the editor's divider handles and the renderer's gap-fill rects.
    static func groupCellsByRow(_ cells: [CollageCell]) -> [[CollageCell]] {
        guard !cells.isEmpty else { return [] }
        let byY = cells.sorted { $0.y < $1.y }
        var rows: [[CollageCell]] = []
        var current: [CollageCell] = [byY[0]]
        for cell in byY.dropFirst() {
            if cell.y < (current.map { $0.y + $0.h }.max() ?? 0) {
                current.append(cell)
            } else {
                rows.append(current)
                current = [cell]
            }
        }
        rows.append(current)
        return rows
    }
}
