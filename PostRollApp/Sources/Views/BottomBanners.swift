import SwiftUI

/// Where the window's persistent banners live (#695).
///
/// They used to be a `.safeAreaInset(edge: .bottom)` on the whole
/// `NavigationSplitView`, and that inset does not reach into the detail
/// column's scroll view. Measured, not assumed: hosted at 500pt with a 60pt
/// banner, the scrolling region ran the full 0 to 500 while the banner sat over
/// 440 to 500, so the last 60pt of scroll content was underneath it with no
/// scroll travel left to bring it out.
///
/// That is worse than it sounds, because on a stage screen the last item is the
/// stage's primary action. On Assign Photos it is the Continue button, so how
/// much content the day sections happen to hold decides whether the screen can
/// be finished at all. And the banner that covers it can be the save failure
/// one, which is deliberately not dismissable, so the screen telling Dan his
/// work exists nowhere else is also the screen he cannot act on.
///
/// Stacking instead of insetting fixes the class rather than one screen. The
/// banners take their own strip, the window's content area is what is left, and
/// nothing can be underneath them: no screen has to know the banners exist, and
/// a screen added next year inherits it (L30).
///
/// Its own type rather than a `VStack` written inline, so a test can host the
/// real arrangement with its own content and measure the overlap. The
/// assertion is then about what the window actually does, not about the shape
/// of its source (L3).
/// The narrowest the banner strip will agree to be. Its own type because a
/// generic one cannot hold a static, and it is a value a test asserts.
enum BottomBannerWidth {
    static let narrowest: CGFloat = 700
}

struct BottomBanners<Banners: View>: ViewModifier {
    @ViewBuilder var banners: () -> Banners

    /// The narrowest the banners will agree to be.
    ///
    /// This is what stops a banner from setting the window's minimum HEIGHT
    /// (#687), and the mechanism is worth writing down because it is not
    /// obvious. A banner's message carries `fixedSize(vertical:)` so it is
    /// never clipped, which is right: a notice that gets cut off is one that
    /// was never shipped (L76). But SwiftUI works out a window's minimum size
    /// by asking the content how TALL it must be at its narrowest, and left
    /// unconstrained that width was 353pt, where the message wraps into dozens
    /// of lines. Measured in the running app: 3854pt of demanded minimum height
    /// against a usable screen of 984, which is a window that cannot be made to
    /// fit and cannot be dragged back.
    ///
    /// Every other banner in the app sits inside a scroll view, which correctly
    /// reports a minimum of zero, so this strip is the only one that can do it.
    ///
    /// Just under the window's own floor, so the two never argue: the window
    /// will not be narrower than 760 anyway, and asking the message to wrap at
    /// 700 gives a height a window can hold.
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            banners().frame(minWidth: BottomBannerWidth.narrowest)
        }
    }
}

extension View {
    /// Put `banners` in a strip along the bottom of this view, taking their own
    /// space rather than sitting over the content.
    func bottomBanners<Banners: View>(
        @ViewBuilder _ banners: @escaping () -> Banners
    ) -> some View {
        modifier(BottomBanners(banners: banners))
    }
}
