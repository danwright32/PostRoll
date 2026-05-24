import SwiftUI
import AppKit

/// Renders a Wednesday collage by compositing the base PNG (which contains
/// Python's masonry photos and the branded centre strip) with SwiftUI photo
/// cells drawn at the supplied crop offsets. The cell overlays cover the
/// base photo regions, so the result is the strip from Python plus photos
/// rendered with the same math as the in-app live preview.
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

private struct StaticCollageView: View {
    let baseImage: NSImage
    let cells: [CollageCell]
    let cellPhotos: [String: NSImage]
    let cropOffsets: [String: CropOffset]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: baseImage)
                .resizable()
                .frame(width: CollageRenderer.canvasSize.width,
                       height: CollageRenderer.canvasSize.height)

            ForEach(cells.indices, id: \.self) { idx in
                let cell = cells[idx]
                let photoKey = URL(fileURLWithPath: cell.photoPath).absoluteString
                let offset = cropOffsets[photoKey] ?? CropOffset()
                if let photo = cellPhotos[cell.photoPath] {
                    StaticCollageCellView(
                        photo: photo,
                        offset: offset,
                        cellW: CGFloat(cell.w),
                        cellH: CGFloat(cell.h)
                    )
                    .position(
                        x: CGFloat(cell.x) + CGFloat(cell.w) / 2,
                        y: CGFloat(cell.y) + CGFloat(cell.h) / 2
                    )
                }
            }
        }
        .frame(width: CollageRenderer.canvasSize.width,
               height: CollageRenderer.canvasSize.height)
    }
}

/// Mirror of `CollageCellOverlay`'s rendering — same math, no interactivity.
/// Keep these formulas in sync with `CollageCellOverlay` in CaptionReviewView.
private struct StaticCollageCellView: View {
    let photo: NSImage
    let offset: CropOffset
    let cellW: CGFloat
    let cellH: CGFloat

    private var photoRatio: CGFloat {
        guard photo.size.height > 0 else { return 1 }
        return photo.size.width / photo.size.height
    }

    private var rendered: CGSize {
        let zoom = CGFloat(max(0.25, offset.scale))
        if photoRatio > cellW / cellH {
            return CGSize(width: cellH * photoRatio * zoom, height: cellH * zoom)
        } else {
            return CGSize(width: cellW * zoom, height: cellW / photoRatio * zoom)
        }
    }

    private var overflow: CGSize {
        CGSize(width: rendered.width - cellW, height: rendered.height - cellH)
    }

    private var isFillMode: Bool { offset.scale >= 1.0 }

    private var committedOffset: CGSize {
        let cw = overflow.width > 0
            ? -overflow.width * (0.5 + CGFloat(offset.x) * 0.5)
            : (cellW - rendered.width) / 2
        let ch = overflow.height > 0
            ? -overflow.height * (0.5 + CGFloat(offset.y) * 0.5)
            : (cellH - rendered.height) / 2
        return CGSize(width: cw, height: ch)
    }

    private var blurOpacity: Double {
        max(0, min(1, (1.0 - Double(offset.scale)) * 4))
    }

    var body: some View {
        Canvas { context, size in
            let img = Image(nsImage: photo)
            if isFillMode {
                let drawRect = CGRect(
                    x: committedOffset.width, y: committedOffset.height,
                    width: rendered.width, height: rendered.height
                )
                context.draw(img, in: drawRect)
            } else {
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(white: 0.08))
                )
                if blurOpacity > 0 {
                    var blurCtx = context
                    blurCtx.addFilter(.blur(radius: 24))
                    blurCtx.draw(img, in: CGRect(origin: .zero, size: size))
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(.black.opacity(0.3 * blurOpacity))
                    )
                }
                let drawRect = CGRect(
                    x: committedOffset.width, y: committedOffset.height,
                    width: rendered.width, height: rendered.height
                )
                context.draw(img, in: drawRect)
            }
        }
        .frame(width: cellW, height: cellH)
    }
}
