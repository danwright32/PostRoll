import XCTest

/// The code folder notice is actually drawn on the window (#670).
///
/// `CheckoutNoticeTests` tests the wording and `BannerLegibilityTests` measures
/// how it looks, and neither of them touches MainWindowView: deleting the banner
/// from the window's bottom inset leaves every one of those green while the app
/// says nothing at all. A notice that exists and a notice that is wired are
/// different things, and only the second one warns anybody.
///
/// The sibling guard beside it, `SaveFailureBannerTests`, closes the same gap
/// for the save failure banner and this follows its shape.
final class CheckoutBannerTests: XCTestCase {

    private func insetBlock() throws -> String {
        let code = try MainWindowSource.stripped()
        // The banners moved out of a bottom safe area inset and into a strip of
        // their own below the window, because the inset did not reach into the
        // detail column's scroll view and sat on top of the last thing in it
        // (#695). What this guard is about is unchanged: that the window draws
        // the notice at all.
        let block = MainWindowSource.block(openedBy: ".bottomBanners", in: code)
        return try XCTUnwrap(
            block,
            "MainWindowView no longer has a bottom banner strip, which is where "
            + "both persistent banners live, so nothing here can be checked and "
            + "this guard would otherwise pass having read nothing")
    }

    func testTheWindowDrawsABannerFromTheCheckoutNotice() throws {
        let inset = try insetBlock()
        let bound = try XCTUnwrap(
            MainWindowSource.block(
                openedBy: "if let notice = appState.checkoutNotice", in: inset),
            "nothing in the window's bottom inset binds appState.checkoutNotice, "
            + "so the notice is a value the window never reads and no banner can "
            + "appear. Note the state is still WRITTEN in checkTheCodeFolder "
            + "below, which is why a search of the whole file would not notice")

        XCTAssertNotNil(
            MainWindowSource.flattened(bound).range(
                of: #"BrandBanner\([^)]*message: notice"#,
                options: .regularExpression),
            "the checkout notice is read but no banner is drawn from it. "
            + "Asserted as one match rather than as a banner somewhere and the "
            + "notice somewhere, because two separate matches in one block "
            + "prove neither half (L172): \(MainWindowSource.flattened(bound))")
    }

    func testACheckoutNoticeAloneIsEnoughToShowTheInset() throws {
        let inset = try insetBlock()
        let gate = try XCTUnwrap(
            inset.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .first(where: { $0.hasPrefix("if ") }),
            "the bottom inset draws unconditionally, so the window carries an "
            + "empty banner strip on every ordinary day")

        XCTAssertTrue(
            gate.contains("appState.checkoutNotice"),
            "the inset holding both banners is gated on something that does not "
            + "read the checkout notice, so a checkout off a clean main with no "
            + "save failure, which is the ordinary state during a working "
            + "session, shows nothing: \(gate)")
    }
}
