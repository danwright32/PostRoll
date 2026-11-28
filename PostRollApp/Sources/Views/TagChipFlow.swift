import SwiftUI

// The chips of the tagging sheet: the wrapping rows they sit in, and the
// suggestion chip itself. Callers can rely on no chip being laid out wider
// than the width the rows were given.

/// What the tagging sheet's chips and the region around them agree on.
enum TagChipMetrics {
    /// The tagging sheet's column of chips, beside the photo.
    static let sheetColumnWidth: CGFloat = 260

    /// How deep the scroll fade over the chips is. Under half a chip, so the
    /// fade softens the row at the cut edge and never washes out a whole chip,
    /// which reads as a chip that cannot be picked.
    static let fadeDepth: CGFloat = 9

    /// The corners of a chip that has wrapped onto more than one line. No less
    /// than half the height of a chip of one line, which is what keeps that
    /// chip a capsule.
    static let cornerRadius: CGFloat = 10
}

/// A capsule while the chip is one line tall, and the same corners on a chip
/// that has wrapped onto more.
struct TagChipShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let drawn = rect.insetBy(dx: inset, dy: inset)
        let radius = TagChipMetrics.cornerRadius - inset
        if drawn.height <= radius * 2 { return Capsule().path(in: drawn) }
        return RoundedRectangle(cornerRadius: radius).path(in: drawn)
    }

    func inset(by amount: CGFloat) -> TagChipShape {
        TagChipShape(inset: inset + amount)
    }
}

extension View {
    /// A chip's words: on as many lines as the chip's width makes them take.
    func tagChipLabel() -> some View {
        multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A chip's padding and painted shape.
    func tagChipBody(fill: Color, border: Color? = nil) -> some View {
        let shape = TagChipShape()
        return padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(shape.fill(fill).overlay {
                if let border { shape.strokeBorder(border, lineWidth: 0.5) }
            })
    }
}

/// Minimal wrapping layout: places subviews left to right, wrapping to the
/// next line when the current one runs out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    private func frames(maxWidth: CGFloat, subviews: Subviews) -> [CGRect] {
        FlowRows.frames(count: subviews.count, maxWidth: maxWidth, spacing: spacing) { index, width in
            subviews[index].sizeThatFits(width.map { ProposedViewSize(width: $0, height: nil) }
                                         ?? .unspecified)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return FlowRows.size(of: frames(maxWidth: maxWidth, subviews: subviews), maxWidth: maxWidth)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(maxWidth: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

/// Wrapping row of tappable performer suggestion chips.
struct TagSuggestionFlow: View {
    let suggestions: [PhotoTagSuggestion]
    let onPick: (PhotoTagSuggestion) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(suggestions) { suggestion in
                Button {
                    onPick(suggestion)
                } label: {
                    Text(suggestion.display)
                        .font(.system(size: 10))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                        .tagChipLabel()
                        .tagChipBody(fill: PaintedSurfaces.suggestionChipFill,
                                     border: PaintedSurfaces.accentBorder.opacity(0.3))
                }
                .buttonStyle(.plain)
                .help(suggestion.display)
            }
        }
    }
}
