import CoreGraphics

/// The size the one window opens at (#986).
///
/// Here rather than only inside `defaultSize` on the scene, because the app's
/// `@main` struct is not compiled into the test bundle, so a check that a sheet
/// FITS in the window had nothing to measure against and would have had to
/// carry a copy of the number. A second copy is one the two can disagree about,
/// and the check would go on passing while measuring against a window size the
/// app no longer opens at (L41, L63).
enum WindowMetrics {
    static let defaultWidth: CGFloat = 1200
    static let defaultHeight: CGFloat = 760
}
