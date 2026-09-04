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

    /// How tall the numbers form's scrolling half may get (#1279).
    ///
    /// Derived from the window rather than typed, for the reason the heights
    /// above are here at all: two copies of one number is a number the two can
    /// disagree about, and the form would go on scrolling against a window size
    /// the app no longer opens at (L41).
    ///
    /// A sheet is inset from the window and the buttons sit outside the scroll
    /// region, so the content gets the window less a margin for both: the
    /// sheet's own padding twice over, the button row, and the inset macOS
    /// gives a sheet.
    ///
    /// 100pt, chosen against the measurement rather than by feel. The form
    /// rendered 668pt tall on 2026-09-03, of which about 620 is the fields, so
    /// a tighter margin would put TODAY's form into a scroll region it does not
    /// need. This leaves it unscrolled and caps what comes after it.
    ///
    /// It is a MAXIMUM, not a size: a short form stays a short sheet, because
    /// the scroll region only earns its keep once the content outgrows it.
    static let numbersFormMaxHeight: CGFloat = defaultHeight - 100
}
