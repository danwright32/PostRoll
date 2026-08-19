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
struct BottomBanners<Banners: View>: ViewModifier {
    @ViewBuilder var banners: () -> Banners

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            banners()
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
