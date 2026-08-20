import SwiftUI

/// Gives its content the height it asks for, up to a ceiling (#743).
///
/// `.frame(maxHeight:)` will not do this for a scroll region: a scroll view is
/// greedy along its own axis, so it takes the whole ceiling whatever it holds,
/// and one warning would sit in a band sized for four. Measuring the content
/// into `@State` and framing to that will not do it either, because the height
/// then arrives on the NEXT layout pass, and a single-pass renderer
/// (`ImageRenderer`, which the legibility harness draws with) sees a height of
/// zero and renders nothing at all.
///
/// A `Layout` asks the content how tall it would like to be and answers in the
/// same pass, so the region is exactly as tall as it needs to be and never
/// taller than it may be.
struct CappedHeight<Content: View>: View {
    let maximum: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        Capping(maximum: maximum) { content() }
    }

    private struct Capping: Layout {
        let maximum: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                          cache: inout ()) -> CGSize {
            // Asked with no height proposed, which is how a view is asked what
            // it would LIKE to be rather than told what it gets.
            let wanted = subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            }
            let width = wanted.map(\.width).max() ?? 0
            let height = wanted.map(\.height).max() ?? 0
            return CGSize(width: proposal.width ?? width, height: min(height, maximum))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) {
            for subview in subviews {
                subview.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width,
                                                         height: bounds.height))
            }
        }
    }
}
