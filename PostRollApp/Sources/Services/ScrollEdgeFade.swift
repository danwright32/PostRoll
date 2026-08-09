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
enum ScrollEdgeFade {

    /// Slack for floating point and sub-pixel layout, so a list that exactly
    /// fits does not show a permanent fade over nothing.
    static let tolerance: CGFloat = 1

    /// Content continues below the visible area.
    static func showsBottom(contentHeight: CGFloat,
                            viewportHeight: CGFloat,
                            scrollOffset: CGFloat) -> Bool {
        guard contentHeight > viewportHeight + tolerance else { return false }
        let remaining = contentHeight - viewportHeight - scrollOffset
        return remaining > tolerance
    }

    /// Content continues above the visible area.
    static func showsTop(scrollOffset: CGFloat) -> Bool {
        scrollOffset > tolerance
    }
}
