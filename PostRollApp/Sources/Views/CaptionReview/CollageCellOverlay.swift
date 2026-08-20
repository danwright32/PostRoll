import SwiftUI
import AppKit

/// Individual cell overlay inside the collage.
///
/// Mirrors Python's crop_to_fill math exactly so the live SwiftUI preview
/// matches the regenerated PNG with no position jump.
///
/// Python model (crop_to_fill):
///   fill_scale chosen so photo covers both cell dimensions.
///   effective = fill_scale × zoom  (zoom = cropOffset.scale)
///   overflow_x = rendered_w − cell_w
///   left       = overflow_x × (0.5 + ox × 0.5)   → SwiftUI offset_x = −left
///
/// scale ≥ 1 → photo overflows cell; drag to pan.
/// scale < 1 → photo smaller than cell; blur background fades in; no drag.
struct CollageCellOverlay: View {
    @Binding var cropOffset: CropOffset
    let isSelected: Bool
    var isDragTarget: Bool = false
    let cellW: CGFloat
    let cellH: CGFloat
    let photoURL: URL
    let onTap: () -> Void
    let onDragEnd: () -> Void

    // @State (not @GestureState) so we can reset it explicitly in onEnded — same
    // transaction as the cropOffset write — eliminating the cross-transaction race
    // that caused @GestureState reset to arrive before the binding update, briefly
    // rendering the photo at the old position (visible snap-back).
    @State private var dragTranslation: CGSize = .zero
    @State private var photo: NSImage? = nil

    private var isMoved: Bool { cropOffset.x != 0 || cropOffset.y != 0 || cropOffset.scale != 1.0 }
    private var isFillMode: Bool { CollageGeometry.isFillMode(scale: cropOffset.scale) }
    private var isDragging: Bool { dragTranslation != .zero }

    // MARK: - Photo geometry (mirrors Python's fill_scale logic)

    /// Photo aspect ratio (width / height). Defaults to 1 until the image loads.
    private var photoRatio: CGFloat {
        guard let s = photo?.size, s.height > 0 else { return 1 }
        return s.width / s.height
    }

    /// Rendered size + committed pan offset — shared with the export renderer
    /// via CollageGeometry so the live crop can't drift from the exported one.
    private var placement: (rendered: CGSize, committed: CGSize) {
        CollageGeometry.placement(photoRatio: photoRatio, cellW: cellW, cellH: cellH, offset: cropOffset)
    }

    /// Rendered photo size at the current zoom — same math as Python's effective_scale.
    private var rendered: CGSize { placement.rendered }

    /// Overflow in each axis (≥ 0 when photo overflows; < 0 when photo is smaller).
    private var overflow: CGSize {
        CGSize(width: rendered.width - cellW, height: rendered.height - cellH)
    }

    /// Offset that makes the SwiftUI view show the same crop as the export.
    private var committedOffset: CGSize { placement.committed }

    /// Live offset: committed base + drag translation, but only in axes where the
    /// photo overflows the cell. If overflow is zero in an axis, there's nothing to
    /// pan — adding dragTranslation only makes it jump back on release.
    private var liveOffset: CGSize {
        CGSize(
            width:  committedOffset.width  + (isDragging && overflow.width  > 0 ? dragTranslation.width  : 0),
            height: committedOffset.height + (isDragging && overflow.height > 0 ? dragTranslation.height : 0)
        )
    }

    /// How much the blur background shows: fades from 0 at scale 1 to 1 at scale 0.75.
    private var blurOpacity: Double {
        CollageGeometry.blurOpacity(scale: cropOffset.scale)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // ── Photo canvas ───────────────────────────────────────────────────
            // Canvas draws into a fixed-size texture — anything outside its bounds
            // is never rendered, giving guaranteed clipping without relying on the
            // SwiftUI offset+clipped combo (which can leak when offset is large).
            Canvas { context, size in
                guard let photo = self.photo else {
                    // Opaque placeholder — blocks the base PNG from showing through
                    // while this cell's photo is still loading. Without this, the
                    // uncropped Python PNG bleeds through the transparent canvas, then
                    // the overlay pops to the saved crop offset (visually a jump).
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(.black.opacity(0.85))
                    )
                    return
                }
                let img = Image(nsImage: photo)

                if isFillMode {
                    // Fill mode: draw photo at the current pan/crop position.
                    let drawRect = CGRect(
                        x: liveOffset.width,  y: liveOffset.height,
                        width: rendered.width, height: rendered.height
                    )
                    context.draw(img, in: drawRect)
                } else {
                    // Blur mode: blurred background + centered sharp photo.
                    // Opaque base prevents the underlying collage PNG from bleeding
                    // through the Gaussian filter's semi-transparent edge fringe.
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(CollageGeometry.blurBackgroundColor)
                    )
                    if blurOpacity > 0 {
                        var blurCtx = context
                        blurCtx.addFilter(.blur(radius: CollageGeometry.blurRadius))
                        blurCtx.draw(img, in: CGRect(origin: .zero, size: size))
                        // Darkening scrim proportional to blur opacity
                        context.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .color(.black.opacity(CollageGeometry.scrimDarkness * blurOpacity))
                        )
                    }
                    // Sharp photo placed via liveOffset so drag is visible on any
                    // axis that still overflows even when zoomed out (e.g. landscape
                    // photo in portrait cell at scale 0.9).
                    let drawRect = CGRect(
                        x: liveOffset.width,  y: liveOffset.height,
                        width: rendered.width, height: rendered.height
                    )
                    context.draw(img, in: drawRect)
                }
            }
            .frame(width: cellW, height: cellH)
            .allowsHitTesting(false)

            // ── Selection / drag-target / adjusted-state border ───────────────
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    isDragTarget ? Color.roseGold
                        : (isSelected || isDragging) ? Color.roseGold
                        : (isMoved ? Color.roseGold.opacity(0.5) : Color.clear),
                    lineWidth: isDragTarget ? 3 : (isSelected || isDragging) ? 2 : 1
                )
                .overlay {
                    if isDragTarget {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(PaintedSurfaces.dropTargetFill)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isMoved && !isSelected && !isDragging && !isDragTarget {
                        Circle().fill(PaintedSurfaces.dropTargetMarker).frame(width: 7, height: 7).padding(4)
                    }
                }
        }
        .frame(width: cellW, height: cellH)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { val in
                    guard overflow.width > 0 || overflow.height > 0 else { return }
                    // Clamp translation so the photo never exposes the cell boundary.
                    // liveOffset = committedOffset + dragTranslation must stay in [-overflow, 0].
                    let clampedX: CGFloat = overflow.width > 0
                        ? min(-committedOffset.width,  max(-overflow.width  - committedOffset.width,  val.translation.width))
                        : 0
                    let clampedY: CGFloat = overflow.height > 0
                        ? min(-committedOffset.height, max(-overflow.height - committedOffset.height, val.translation.height))
                        : 0
                    dragTranslation = CGSize(width: clampedX, height: clampedY)
                }
                .onEnded { val in
                    // Reset translation FIRST — in the same transaction as the
                    // cropOffset write — so SwiftUI renders exactly once with
                    // dragTranslation=0 and the new committed offset. No snap-back.
                    dragTranslation = .zero
                    let dist = hypot(val.translation.width, val.translation.height)
                    if dist < 5 {
                        onTap()
                    } else if overflow.width > 0 || overflow.height > 0 {
                        // Commit pan only in axes where there's overflow to pan through.
                        // Works in fill mode AND when slightly zoomed out, as long as
                        // the photo still overflows the cell on at least one axis.
                        if overflow.width > 0 {
                            let ovX = Double(overflow.width)
                            cropOffset.x = min(1, max(-1, cropOffset.x - 2 * Double(val.translation.width) / ovX))
                        }
                        if overflow.height > 0 {
                            let ovY = Double(overflow.height)
                            cropOffset.y = min(1, max(-1, cropOffset.y - 2 * Double(val.translation.height) / ovY))
                        }
                        onDragEnd()
                    }
                }
        )
        .task(id: photoURL) {
            photo = nil  // clear stale image before loading so old photo never renders at new crop offset
            photo = await ImageLoad.read(photoURL).image
        }
    }
}
