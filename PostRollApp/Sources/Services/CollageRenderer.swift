import SwiftUI
import AppKit

/// Renders a Wednesday collage by compositing the base PNG (which contains
/// Python's masonry photos and the branded centre strip) with the user's
/// per photo crop/zoom, producing the same image the in app live preview shows.
///
/// Everything is drawn into a SINGLE `Canvas` sized to the 1080x1920 canvas, in
/// absolute coordinates, with each photo clipped to its cell rect. We do NOT lay
/// cells out with `.position()` / `.frame()` and feed that through `ImageRenderer`
/// — that path mis-handles `.position()` and scatters the cells (each offset by
/// roughly half its size). A single Canvas is pure deterministic drawing, so the
/// export stays pixel faithful to the live preview.
@MainActor
enum CollageRenderer {

    nonisolated static let canvasSize = CollageGeometry.canvasSize

    /// Returns true on success. The output PNG is written at canvas resolution.
    static func render(
        baseURL: URL,
        cells: [CollageCell],
        cropOffsets: [String: CropOffset],
        outputURL: URL
    ) -> Bool {
        guard let baseImage = NSImage(contentsOf: baseURL) else { return false }
        var cellPhotos: [String: NSImage] = [:]
        for cell in cells {
            if cellPhotos[cell.photoPath] != nil { continue }
            if let img = NSImage(contentsOf: URL(fileURLWithPath: cell.photoPath)) {
                cellPhotos[cell.photoPath] = img
            }
        }

        let view = StaticCollageView(
            baseImage: baseImage,
            cells: cells,
            cellPhotos: cellPhotos,
            cropOffsets: cropOffsets,
            gapColor: sampleGapColor(from: baseImage)
        )

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(canvasSize)
        renderer.scale = 1.0
        renderer.isOpaque = true

        guard let cgImage = renderer.cgImage else { return false }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: outputURL)
            return true
        } catch {
            return false
        }
    }

    /// Cream divider strips between cells, matching the live editor's gap fill.
    ///
    /// Python bakes 8px gaps into the base PNG at its ORIGINAL masonry positions.
    /// The moment the user drags a divider the override cells move, so those baked
    /// gaps no longer line up and stale photo content shows through the new gaps.
    /// The live editor (CaptionReviewView) repaints `gap_color` strips at the
    /// CURRENT cell boundaries; the composited preview and the export render
    /// through this type, so they must do the same or the dividers vanish.
    ///
    /// Returns absolute-canvas rectangles to fill, skipping the wide (~90px)
    /// branded-strip band so the centre logo/text is never painted over.
    nonisolated static func gapRects(for cells: [CollageCell]) -> [CGRect] {
        guard cells.count > 1 else { return [] }
        let gapLimit = CollageGeometry.normalGapLimit
        let canvasW = canvasSize.width

        // Group cells into rows by vertical overlap (shared with the editor's
        // divider computation so the two can't disagree on row boundaries).
        let rows = CollageGeometry.groupCellsByRow(cells)

        var rects: [CGRect] = []

        // Horizontal dividers — full-width strips between consecutive rows.
        for i in 0..<(rows.count - 1) {
            let boundary = rows[i].map { $0.y + $0.h }.max()!
            let belowTop = rows[i + 1].map { $0.y }.min()!
            let gap = belowTop - boundary
            if gap > 0 && gap <= gapLimit {
                rects.append(CGRect(x: 0, y: boundary, width: Int(canvasW), height: gap))
            }
        }

        // Vertical dividers — row-height strips between adjacent cells in a row.
        for row in rows {
            let sorted = row.sorted { $0.x < $1.x }
            let rowTop = row.map { $0.y }.min()!
            let rowH = row.map { $0.y + $0.h }.max()! - rowTop
            for i in 0..<(sorted.count - 1) {
                let leftEdge = sorted[i].x + sorted[i].w
                let gap = sorted[i + 1].x - leftEdge
                if gap > 0 && gap <= gapLimit {
                    rects.append(CGRect(x: leftEdge, y: rowTop, width: gap, height: rowH))
                }
            }
        }

        return rects
    }

    private static func sampleGapColor(from image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return Color.creamDeep }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        guard let c = bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB)
        else { return Color.creamDeep }
        return Color(
            red:   Double(c.redComponent),
            green: Double(c.greenComponent),
            blue:  Double(c.blueComponent)
        )
    }
}

/// Single Canvas that draws the base PNG then every cropped photo in absolute
/// canvas coordinates. The geometry (`rendered` / `overflow` / `committedOffset`
/// / blur mode) is the SAME math as `CollageCellOverlay` in CaptionReviewView,
/// just expressed at each cell's absolute origin instead of inside a per cell view.
private struct StaticCollageView: View {
    let baseImage: NSImage
    let cells: [CollageCell]
    let cellPhotos: [String: NSImage]
    let cropOffsets: [String: CropOffset]
    let gapColor: Color

    var body: some View {
        Canvas { context, size in
            // Base PNG fills the whole canvas (Python's strip + masonry photos).
            context.draw(
                Image(nsImage: baseImage),
                in: CGRect(origin: .zero, size: size)
            )

            // Repaint clean gap_color dividers at the current cell boundaries.
            // Without this, an override that moved a divider leaves the photos
            // butting against stale PNG content with no visible gaps.
            for rect in CollageRenderer.gapRects(for: cells) {
                context.fill(Path(rect), with: .color(gapColor))
            }

            for cell in cells {
                guard let photo = cellPhotos[cell.photoPath] else { continue }
                let key = URL(fileURLWithPath: cell.photoPath).absoluteString
                let offset = cropOffsets[key] ?? CropOffset()

                let cellW = CGFloat(cell.w)
                let cellH = CGFloat(cell.h)
                let cellOrigin = CGPoint(x: CGFloat(cell.x), y: CGFloat(cell.y))
                let cellRect = CGRect(origin: cellOrigin, size: CGSize(width: cellW, height: cellH))

                let photoRatio: CGFloat = photo.size.height > 0
                    ? photo.size.width / photo.size.height
                    : 1
                let (rendered, committed) = CollageGeometry.placement(
                    photoRatio: photoRatio, cellW: cellW, cellH: cellH, offset: offset)
                let isFillMode = CollageGeometry.isFillMode(scale: offset.scale)

                let img = Image(nsImage: photo)

                // Clip to the cell so any overflow is cropped, exactly like the
                // live overlay's fixed size Canvas.
                var cellCtx = context
                cellCtx.clip(to: Path(cellRect))

                let drawRect = CGRect(
                    x: cellOrigin.x + committed.width,
                    y: cellOrigin.y + committed.height,
                    width: rendered.width,
                    height: rendered.height
                )

                if isFillMode {
                    cellCtx.draw(img, in: drawRect)
                } else {
                    // Blur mode (zoomed out): opaque base + optional blurred fill
                    // + darkening scrim + the sharp photo centered.
                    cellCtx.fill(Path(cellRect), with: .color(CollageGeometry.blurBackgroundColor))
                    let blurOpacity = CollageGeometry.blurOpacity(scale: offset.scale)
                    if blurOpacity > 0 {
                        var blurCtx = cellCtx
                        blurCtx.addFilter(.blur(radius: CollageGeometry.blurRadius))
                        blurCtx.draw(img, in: cellRect)
                        cellCtx.fill(Path(cellRect), with: .color(.black.opacity(CollageGeometry.scrimDarkness * blurOpacity)))
                    }
                    cellCtx.draw(img, in: drawRect)
                }
            }

            // Hairline LAST: the gap repaint above would erase the ring Python
            // baked into the base PNG, so restroke it over the finished gutters.
            for cell in cells {
                let ring = CollageGeometry.hairlineRect(
                    x: CGFloat(cell.x), y: CGFloat(cell.y),
                    w: CGFloat(cell.w), h: CGFloat(cell.h))
                context.stroke(Path(ring), with: .color(CollageGeometry.hairlineColor),
                               lineWidth: CollageGeometry.hairlineWidth)
            }
        }
        .frame(width: CollageRenderer.canvasSize.width,
               height: CollageRenderer.canvasSize.height)
    }
}
