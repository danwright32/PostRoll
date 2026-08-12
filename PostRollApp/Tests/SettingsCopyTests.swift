import XCTest

/// The console address in Settings is a link, and stays one.
///
/// SwiftUI renders a markdown link inside `Text` automatically, which is what
/// makes this a one line change. It is also what makes it fragile: a typo in
/// the brackets does not fail to build and does not throw. It renders the raw
/// markdown as literal text, so the person sees `[console.anthropic.com](...)`
/// on screen, or worse a plain address that simply does not respond to a click
/// while looking exactly like the one that does (L49).
///
/// So the copy is a named constant and the link inside it is asserted, rather
/// than being a string literal buried in a view body where nothing can reach
/// it.
final class SettingsCopyTests: XCTestCase {

    func testTheApiKeyFooterCarriesAMarkdownLink() {
        let copy = SettingsCopy.apiKeyFooter

        XCTAssertTrue(copy.contains("[console.anthropic.com]"),
                      "the address is not marked up as a link: \(copy)")
        XCTAssertTrue(copy.contains("(\(SettingsCopy.consoleURL))"),
                      "the link has no destination: \(copy)")
    }

    func testTheDestinationIsAUsableHttpsAddress() {
        let url = URL(string: SettingsCopy.consoleURL)

        XCTAssertNotNil(url, "\(SettingsCopy.consoleURL) does not parse as a URL")
        XCTAssertEqual(url?.scheme, "https",
                       "a key console reached over plain http is not one to send people to")
        XCTAssertEqual(url?.host, "console.anthropic.com")
    }

    func testTheVisibleTextMatchesWhereItActuallyGoes() {
        // A link labelled with one address and pointing at another is the shape
        // a person cannot check before clicking.
        let url = URL(string: SettingsCopy.consoleURL)

        XCTAssertTrue(SettingsCopy.apiKeyFooter.contains("[\(url?.host ?? "")]"),
                      "the link text and its destination name different hosts")
    }
}
