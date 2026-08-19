import SwiftUI

// Lifted out of CaptionReviewView.swift (#718). It is pure interaction with no
// long work anywhere near it, and living in a six thousand line file alongside
// eleven calls across to Python made it indistinguishable, to the ownership
// check and to a reader, from a screen holding the progress of a paid model
// run. A hover flag on a drag handle is none of that rule's business.

/// Thin interactive line drawn across a row/column boundary.
///
/// Drag state is managed entirely inside this view via @GestureState, so the
/// parent never re-renders during the drag. Only the handle itself re-renders
/// on each frame — giving smooth, jank-free dragging regardless of how many
/// CollageCellOverlay views are in the parent.
///
/// The line offsets visually while dragging (clamped to minDelta…maxDelta in
/// display pixels). On gesture end the final delta is passed to `onEnded` so
/// the parent can commit the new cell layout once.
struct CollageDividerHandle: View {
    let kind: CollageDivider.Kind
    let displayLength: CGFloat   // width (H) or height (V) in display pixels
    let minDelta: CGFloat        // minimum visual offset in display pixels
    let maxDelta: CGFloat        // maximum visual offset in display pixels
    var onEnded: (CGFloat) -> Void   // called once with the final clamped delta

    @GestureState private var liveDelta: CGFloat = 0
    @State private var isHovering = false

    private var isH: Bool { kind == .horizontal }
    private var isDragging: Bool { liveDelta != 0 }
    private var clampedDelta: CGFloat { min(max(liveDelta, minDelta), maxDelta) }

    var body: some View {
        let hitThickness: CGFloat = 20
        ZStack {
            // Wide transparent hit target
            Color.clear
                .frame(
                    width:  isH ? displayLength : hitThickness,
                    height: isH ? hitThickness  : displayLength
                )

            // Visible line — always present; brighter on hover/drag so it persists after release
            Rectangle()
                .fill(isDragging || isHovering
                      ? Color.roseGold.opacity(0.9)
                      : Color.white.opacity(0.6))
                .frame(
                    width:  isH ? displayLength : 2,
                    height: isH ? 2             : displayLength
                )

            // Directional pill — appears on hover or during drag
            if isDragging || isHovering {
                Image(systemName: isH ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PaintedSurfaces.dragHandleIcon)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isDragging ? PaintedSurfaces.dragHandleActiveFill : PaintedSurfaces.dragHandleFill)
                    .clipShape(Capsule())
            }
        }
        // Visually offset the line during drag — hit area stays at resting position
        .offset(
            x: isH ? 0 : clampedDelta,
            y: isH ? clampedDelta : 0
        )
        .contentShape(
            Rectangle().size(CGSize(
                width:  isH ? displayLength : hitThickness,
                height: isH ? hitThickness  : displayLength
            ))
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .gesture(
            DragGesture(minimumDistance: 2)
                .updating($liveDelta) { val, state, _ in
                    state = isH ? val.translation.height : val.translation.width
                }
                .onEnded { val in
                    let raw = isH ? val.translation.height : val.translation.width
                    onEnded(min(max(raw, minDelta), maxDelta))
                }
        )
    }
}
