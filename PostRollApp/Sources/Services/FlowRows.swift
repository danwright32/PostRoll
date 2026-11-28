import CoreGraphics
import Foundation

/// Where each item of a wrapping row layout goes: left to right, starting a new
/// row when the current one runs out of width.
///
/// A pure function so the packing can be asserted without a window. The layout
/// that uses it supplies only the measurements.
enum FlowRows {

    /// One frame per item, in order, with the origin at the layout's top left.
    ///
    /// `measure(index, width)` is the size item `index` takes when offered
    /// `width`, or the size it would take with no limit when `width` is nil.
    static func frames(count: Int, maxWidth: CGFloat, spacing: CGFloat,
                       measure: (Int, CGFloat?) -> CGSize) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for index in 0..<count {
            var size = measure(index, nil)
            // An item wider than a whole row is measured again at the row's
            // width, which is what lets its text wrap. Held to that width even
            // if it answers with more, so nothing is placed past the edge.
            if size.width > maxWidth {
                size = measure(index, maxWidth)
                size.width = min(size.width, maxWidth)
            }
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }

    /// The space the frames take. As wide as it was offered when the offer was
    /// finite, so the rows keep their leading edge whatever is in them.
    static func size(of frames: [CGRect], maxWidth: CGFloat) -> CGSize {
        let height = frames.map(\.maxY).max() ?? 0
        let width = maxWidth.isFinite ? maxWidth : (frames.map(\.maxX).max() ?? 0)
        return CGSize(width: width, height: height)
    }
}
