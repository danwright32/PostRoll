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

    static let canvasSize = CGSize(width: 1080, height: 1920)

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
            cropOffsets: cropOffsets
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

    var body: some View {
        Canvas { context, size in
            // Base PNG fills the whole canvas (Python's strip + masonry photos).
            context.draw(
                Image(nsImage: baseImage),
                in: CGRect(origin: .zero, size: size)
            )

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
                let zoom = CGFloat(max(0.25, offset.scale))
                let rendered: CGSize = photoRatio > cellW / cellH
                    ? CGSize(width: cellH * photoRatio * zoom, height: cellH * zoom)
                    : CGSize(width: cellW * zoom, height: cellW / photoRatio * zoom)
                let overflow = CGSize(width: rendered.width - cellW, height: rendered.height - cellH)
                let isFillMode = offset.scale >= 1.0
                let committed = CGSize(
                    width: overflow.width > 0
                        ? -overflow.width * (0.5 + CGFloat(offset.x) * 0.5)
                        : (cellW - rendered.width) / 2,
                    height: overflow.height > 0
                        ? -overflow.height * (0.5 + CGFloat(offset.y) * 0.5)
                        : (cellH - rendered.height) / 2
                )

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
                    cellCtx.fill(Path(cellRect), with: .color(Color(white: 0.08)))
                    let blurOpacity = max(0, min(1, (1.0 - Double(offset.scale)) * 4))
                    if blurOpacity > 0 {
                        var blurCtx = cellCtx
                        blurCtx.addFilter(.blur(radius: 24))
                        blurCtx.draw(img, in: cellRect)
                        cellCtx.fill(Path(cellRect), with: .color(.black.opacity(0.3 * blurOpacity)))
                    }
                    cellCtx.draw(img, in: drawRect)
                }
            }
        }
        .frame(width: CollageRenderer.canvasSize.width,
               height: CollageRenderer.canvasSize.height)
    }
}
