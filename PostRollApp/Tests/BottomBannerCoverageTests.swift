import XCTest
import SwiftUI
import AppKit

/// The bottom banners do not sit on top of the window's content (#695).
///
/// With the checkout notice showing, the Continue button on Assign Photos could
/// not be clicked, and scrolling to the very bottom did not reveal it: the
/// banner was over it, and there was no scroll travel left to bring it out.
/// Collapsing every day section was the only way to reach it, because that
/// shrank the content until the screen no longer needed to scroll.
///
/// These measure the arrangement rather than reading the window's source. The
/// overlap is a number, and a source scan for the right modifier would be
/// satisfied by a modifier that does not do what it is being trusted to do
/// (L3).
///
/// What could NOT be built here, and is worth writing down: a test that scrolls
/// to the end and asserts the last item's frame. `scrollTo` does not take
/// effect in a hosted view with no window server, measured, so the item stays
/// exactly where it started and every such test would pass having scrolled
/// nothing (L159). The overlap below is the same defect measured one step
/// earlier: if the scrolling region does not reach under the banner, no content
/// in it can be covered.
@MainActor
final class BottomBannerCoverageTests: XCTestCase {

    private let bannerHeight: CGFloat = 60
    private let windowHeight: CGFloat = 500

    /// Where each half of the arrangement landed, in one shared coordinate
    /// space, filled by the views themselves as they lay out.
    private final class Measured {
        var content: CGRect = .zero
        var banner: CGRect = .zero
    }

    private func measuring(_ assign: @escaping (CGRect) -> Void) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { assign(geo.frame(in: .global)) }
                .onChange(of: geo.frame(in: .global)) { _, frame in assign(frame) }
        }
    }

    /// Content taller than the window, which is the only case that can be
    /// covered: a screen that fits has nothing at the bottom edge.
    private func tallContent(_ measured: Measured) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<40, id: \.self) { index in
                    Text("Row \(index)").frame(height: 40).frame(maxWidth: .infinity)
                }
                Text("Continue").frame(height: 44).frame(maxWidth: .infinity)
            }
        }
        .background(measuring { measured.content = $0 })
    }

    private func banner(_ measured: Measured) -> some View {
        Color.red
            .frame(height: bannerHeight)
            .frame(maxWidth: .infinity)
            .background(measuring { measured.banner = $0 })
    }

    /// Lay the arrangement out and hand back what overlaps, in points.
    private func overlap(of build: (Measured) -> AnyView) -> CGFloat {
        let measured = Measured()
        let host = NSHostingView(rootView: build(measured))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: windowHeight)
        host.layoutSubtreeIfNeeded()
        // NavigationSplitView fills its columns in asynchronously, so a single
        // layout pass measures an empty detail column.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(measured.banner.height, 0, "the banner never laid out")
        XCTAssertGreaterThan(measured.content.height, 0, "the content never laid out")
        return max(0, measured.content.maxY - measured.banner.minY)
    }

    // MARK: - The window's own arrangement

    func testTheScrollingRegionDoesNotReachUnderTheBanner() {
        // The measurement this issue turns on. On the old arrangement this is
        // exactly the banner's height: the scrolling region ran the full window
        // while the banner sat over its last 60 points.
        let overlapped = overlap { measured in
            AnyView(
                NavigationSplitView { Text("sidebar") } detail: { self.tallContent(measured) }
                    .bottomBanners { self.banner(measured) }
            )
        }

        XCTAssertEqual(overlapped, 0,
                       "the last \(Int(overlapped))pt of every scrolling screen "
                       + "is underneath the banner, with no scroll travel left "
                       + "to bring it out")
    }

    func testTheContentKeepsEverythingTheBannerDoesNotTake() {
        // The other direction. A fix that simply shrank the content to nothing,
        // or left a gap above the banner, would satisfy the test above while
        // wasting the window (L159).
        let measured = Measured()
        let host = NSHostingView(rootView: AnyView(
            NavigationSplitView { Text("sidebar") } detail: { self.tallContent(measured) }
                .bottomBanners { self.banner(measured) }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: windowHeight)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(measured.content.height, windowHeight - bannerHeight, accuracy: 1,
                       "the content area is not the window minus the banner")
        XCTAssertEqual(measured.banner.maxY, windowHeight, accuracy: 1,
                       "the banner is not against the bottom of the window")
    }

    func testWithNoBannerTheContentHasTheWholeWindow() {
        // Every ordinary day. The strip must cost nothing when it holds nothing,
        // or the window loses a band of height permanently.
        let measured = Measured()
        let host = NSHostingView(rootView: AnyView(
            NavigationSplitView { Text("sidebar") } detail: { self.tallContent(measured) }
                .bottomBanners { EmptyView() }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: windowHeight)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(measured.content.height, windowHeight, accuracy: 1,
                       "an empty banner strip is still taking space")
    }

    // MARK: - Wired into the window

    func testTheWindowPutsItsBannersInThatStrip() throws {
        // The measurements above are about the arrangement; this is the part
        // that says the window uses it. Both are needed: a perfect strip nothing
        // adopts is a strip that fixes nothing (L3).
        let code = try MainWindowSource.stripped()
        XCTAssertTrue(code.contains(".bottomBanners"),
                      "the window is not using the banner strip: \(code)")
        XCTAssertFalse(code.contains(".safeAreaInset(edge: .bottom)"),
                       "the window still insets its banners over the content, "
                       + "which is what put them on top of the Continue button")
    }
}
