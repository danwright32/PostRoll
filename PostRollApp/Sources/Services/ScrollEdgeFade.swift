import Foundation

/// Whether a scrolling region should show a fade at its clipped edge (#190).
///
/// macOS hides scrollbars until a scroll gesture starts, so an overflowing list
/// looks exactly like a complete one. In the tagging sheet that means everyone
/// below the cut is effectively invisible: on a programme with thirty
/// performers, most of the cast cannot be found by someone who does not know to
/// scroll, and they would reasonably conclude the person is not there.
///
/// The rule is the whole of L76: show it while content continues past the edge,
/// and stop showing it once the end is reached, so the hint means something.
///
/// Axis neutral, and named that way since #539. The arithmetic never cared
/// which way the region runs: a strip of thumbnails that continues to the right
/// looks exactly like one that ends, the same way a column does, so it is the
/// same predicate rather than a second copy of it.
enum ScrollEdgeFade {

    /// Slack for floating point and sub-pixel layout, so a list that exactly
    /// fits does not show a permanent fade over nothing.
    static let tolerance: CGFloat = 1

    /// Content continues past the far edge: below a column, right of a strip.
    static func showsTrailingEdge(contentLength: CGFloat,
                                  viewportLength: CGFloat,
                                  scrollOffset: CGFloat) -> Bool {
        guard contentLength > viewportLength + tolerance else { return false }
        let remaining = contentLength - viewportLength - scrollOffset
        return remaining > tolerance
    }

    /// Content continues past the near edge: above a column, left of a strip.
    static func showsLeadingEdge(scrollOffset: CGFloat) -> Bool {
        scrollOffset > tolerance
    }
}
