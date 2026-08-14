import SwiftUI

/// A vertical scroll region that shows, at rest, that its content continues
/// past the clipped edge (#190, #468).
///
/// macOS hides scrollbars until a scroll gesture starts, so an overflowing
/// region looks exactly like a complete one and the person reads what fits and
/// never learns the rest existed (L76). The rule is both halves: show the fade
/// while content continues, and stop showing it once the end is reached, so the
/// hint means something.
///
/// One implementation rather than the measuring boilerplate copied per site.
/// The decision itself lives in `ScrollEdgeFade`, which is a pure function with
/// its own tests; this is the plumbing that feeds it real numbers.
struct FadingScrollView<Content: View>: View {

    /// The colour the fade resolves to. Whatever the region sits on.
    var background: Color = .cream

    /// How tall the fade is. Enough to read as a soft edge rather than a line.
    var fadeHeight: CGFloat = 22

    @ViewBuilder var content: () -> Content

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    /// Its own name per instance, so two of these on one screen cannot read
    /// each other's coordinate space.
    private let space = "fading-scroll-\(UUID().uuidString)"

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, h in contentHeight = h }
                        .onChange(of: proxy.frame(in: .named(space)).minY) { _, y in
                            scrollOffset = -y
                        }
                })
        }
        .coordinateSpace(name: space)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { viewportHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, h in viewportHeight = h }
        })
        .overlay(alignment: .top) {
            if ScrollEdgeFade.showsTop(scrollOffset: scrollOffset) {
                LinearGradient(colors: [background, background.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            if ScrollEdgeFade.showsBottom(contentHeight: contentHeight,
                                          viewportHeight: viewportHeight,
                                          scrollOffset: scrollOffset) {
                LinearGradient(colors: [background.opacity(0), background],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
