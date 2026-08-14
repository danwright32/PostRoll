import SwiftUI

/// A scroll region that shows, at rest, that its content continues past the
/// clipped edge (#190, #468, #539).
///
/// macOS hides scrollbars until a scroll gesture starts, so an overflowing
/// region looks exactly like a complete one and the person reads what fits and
/// never learns the rest existed (L76). The rule is both halves: show the fade
/// while content continues, and stop showing it once the end is reached, so the
/// hint means something.
///
/// One implementation rather than the measuring boilerplate copied per site,
/// and since #539 one implementation across both axes rather than a second copy
/// for strips. A row of thumbnails reads differently from a column of controls,
/// which is why the horizontal case was deferred rather than missed, but it
/// fails in exactly the same way and the arithmetic behind it is the same
/// arithmetic. The decision itself lives in `ScrollEdgeFade`, which is a pure
/// function with its own tests; this is the plumbing that feeds it real
/// numbers.
struct FadingScrollView<Content: View>: View {

    /// Which way the region runs. Vertical by default, so every call site that
    /// predates the horizontal case reads and behaves exactly as it did.
    var axis: Axis = .vertical

    /// The colour the fade resolves to. Whatever the region sits on.
    var background: Color = .cream

    /// How deep the fade is. Enough to read as a soft edge rather than a line.
    var fadeDepth: CGFloat = 22

    @ViewBuilder var content: () -> Content

    @State private var contentLength: CGFloat = 0
    @State private var viewportLength: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    /// Its own name per instance, so two of these on one screen cannot read
    /// each other's coordinate space.
    private let space = "fading-scroll-\(UUID().uuidString)"

    private var isVertical: Bool { axis == .vertical }

    private func length(_ size: CGSize) -> CGFloat {
        isVertical ? size.height : size.width
    }

    /// How far the content has been scrolled, as a positive number, measured on
    /// whichever axis this region runs.
    private func offset(_ frame: CGRect) -> CGFloat {
        isVertical ? -frame.minY : -frame.minX
    }

    var body: some View {
        ScrollView(isVertical ? .vertical : .horizontal, showsIndicators: false) {
            content()
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentLength = length(proxy.size) }
                        .onChange(of: length(proxy.size)) { _, l in contentLength = l }
                        .onChange(of: offset(proxy.frame(in: .named(space)))) { _, o in
                            scrollOffset = o
                        }
                })
        }
        .coordinateSpace(name: space)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { viewportLength = length(proxy.size) }
                .onChange(of: length(proxy.size)) { _, l in viewportLength = l }
        })
        .overlay(alignment: isVertical ? .top : .leading) {
            if ScrollEdgeFade.showsLeadingEdge(scrollOffset: scrollOffset) {
                fade(fromOpaque: true)
            }
        }
        .overlay(alignment: isVertical ? .bottom : .trailing) {
            if ScrollEdgeFade.showsTrailingEdge(contentLength: contentLength,
                                                viewportLength: viewportLength,
                                                scrollOffset: scrollOffset) {
                fade(fromOpaque: false)
            }
        }
    }

    /// The gradient itself, running along this region's axis. `fromOpaque` is
    /// the near edge, where the solid end sits against the clipped side.
    private func fade(fromOpaque: Bool) -> some View {
        let colors = fromOpaque
            ? [background, background.opacity(0)]
            : [background.opacity(0), background]
        return LinearGradient(colors: colors,
                              startPoint: isVertical ? .top : .leading,
                              endPoint: isVertical ? .bottom : .trailing)
            .frame(width: isVertical ? nil : fadeDepth,
                   height: isVertical ? fadeDepth : nil)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
