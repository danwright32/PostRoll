import XCTest
import SwiftUI
import AppKit

/// A banner cannot set the window's minimum height (#687).
///
/// The window was given a minimum height of 2834pt against a usable screen of
/// 984, which left it below the bottom of the display with no drag able to
/// recover it, because AppKit will not size a window under its minimum.
///
/// The cause, found by measuring the running app rather than by reading it: a
/// banner's message carries `fixedSize(horizontal: false, vertical: true)` so
/// it is never clipped, which is right. But SwiftUI works out a window's
/// minimum size by asking the content how TALL it must be at its NARROWEST, and
/// with nothing holding that width the answer was computed at 353pt, where the
/// message wraps into dozens of lines. Measured live at 3854pt of demanded
/// minimum height, and it went away entirely the moment the strip refused to be
/// narrower than 700.
///
/// Every other banner in the app sits inside a scroll view, which correctly
/// reports a minimum of zero, so the window's own strip is the only one that
/// can do this.
@MainActor
final class BannerWindowMinimumTests: XCTestCase {

    /// A real message, the length of the one that did it: the code folder
    /// notice is three sentences and names a branch.
    private let longMessage =
        "PostRoll generates using the code in your PostRoll folder. That folder "
        + "is on a branch called wip/collage rather than main, and has changes "
        + "that have not been saved to a branch. Captions, blog posts and reels "
        + "will use that code; what PostRoll draws itself, like the finished "
        + "Wednesday collage, still comes from this build until you rebuild it."

    private var banner: some View {
        BrandBanner(icon: "arrow.triangle.branch", message: longMessage,
                    style: .warning)
    }

    /// The minimum height SwiftUI would hand the window for this content.
    ///
    /// `.minSize` is the sizing option that propagates a layout's minimum out
    /// to the window, and the constraint it installs is the number AppKit then
    /// refuses to go under. This is the same quantity the running app printed.
    private func minimumHeight(of view: some View) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view))
        host.sizingOptions = [.minSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        holder.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            host.topAnchor.constraint(equalTo: holder.topAnchor),
        ])
        holder.layoutSubtreeIfNeeded()

        for constraint in host.constraints
        where constraint.relation == .greaterThanOrEqual
            && constraint.firstAttribute == .height {
            return constraint.constant
        }
        return 0
    }

    /// The usable height of the screen #687 was measured on. Nothing may demand
    /// more than a display can hold.
    private let usableScreenHeight: CGFloat = 984

    func testTheBannerStripDoesNotDemandMoreHeightThanAScreenHolds() {
        let demanded = minimumHeight(of: Color.clear.bottomBanners { self.banner })

        XCTAssertLessThan(demanded, usableScreenHeight,
                          "the banner strip demands \(Int(demanded))pt of minimum "
                          + "height, which is more than the screen has, so the "
                          + "window cannot be made to fit and cannot be dragged back")
    }

    func testAndItIsNotMerelySmallBecauseTheBannerVanished() {
        // The control for the assertion above. A strip that had stopped drawing
        // its banner would demand nothing at all and pass, while saying nothing
        // to Dan (L159, L98).
        let demanded = minimumHeight(of: Color.clear.bottomBanners { self.banner })

        XCTAssertGreaterThan(demanded, 30,
                             "the strip demands almost no height, which is what "
                             + "an empty strip demands: the banner is not there")
    }

    func testWithoutTheWidthTheSameBannerDemandsAnImpossibleHeight() {
        // The fixture proving the defect is real and that this test could fail.
        // The same banner, asked how tall it must be with nothing holding its
        // width, is the 3854pt the running app printed.
        let demanded = minimumHeight(of: banner)

        XCTAssertGreaterThan(demanded, usableScreenHeight,
                             "a banner with nothing holding its width no longer "
                             + "demands an impossible height, so the guard above "
                             + "is passing for a reason that has moved")
    }

    func testTheMessageIsStillWhole() {
        // The width is a floor, not a cap. The reason the message carries
        // fixedSize in the first place is that a notice which gets cut off is
        // one that was never shipped (L76), so the fix must not have bought its
        // height back by clipping.
        let width: CGFloat = 900
        let host = NSHostingView(rootView: AnyView(
            Color.clear.bottomBanners { self.banner }.frame(width: width)))
        host.layoutSubtreeIfNeeded()
        let laidOut = host.fittingSize.height

        // Three or four lines of 12pt text plus padding. Enough to prove it
        // wrapped rather than being truncated to one line.
        XCTAssertGreaterThan(laidOut, 50,
                             "the banner is one line tall at \(Int(width))pt, so "
                             + "the message is being cut off rather than wrapped")
    }
}
