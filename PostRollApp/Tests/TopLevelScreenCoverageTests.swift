import XCTest

/// Every screen the app can show is on the review sheet (#937).
///
/// The sheet is the only place a visual change reports itself. #919 found a
/// field drawing its own dark bezel with unreadable text the moment its panel
/// was rendered, and every colour check had passed for as long as it was not;
/// #918 found the whole render harness drawing platform chrome in the wrong
/// appearance, the same way.
///
/// Nothing said a screen had to join them. Settings was missing for exactly
/// that reason: no rule, so no omission to notice. A screen absent from the
/// sheet is not merely unreviewed, it is indistinguishable from one that was
/// reviewed and found fine (L98, L129).
///
/// ## Read from the app rather than listed here
///
/// The screens are the cases of `EventDetailView`'s switch, which is the one
/// place that decides what an event shows. A list kept here would drift from
/// it, and would drift in the direction of saying everything is covered (L41,
/// L96): a screen added to the app and not to the list is exactly the omission
/// this exists to catch.
///
/// The surfaces are matched by an exact name, `screen: <TypeName>`, so there is
/// no mapping table to disagree with either side.
@MainActor
final class TopLevelScreenCoverageTests: XCTestCase {

    /// The prefix every whole-screen surface on the sheet carries.
    static let surfacePrefix = "screen: "

    private func source(_ relativePath: String) throws -> String {
        // Built by appending rather than by trimming a root off an absolute
        // path: `#filePath` is recorded by the compiler and a FileManager path
        // is resolved, so on a checkout under a symlink the two disagree and a
        // prefix removal takes a bite out of the middle (#941, L266).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every view `EventDetailView` can put on screen, by type name.
    func screensTheAppCanShow() throws -> [String] {
        let code = try source("Views/EventDetailView.swift")
        let body = try XCTUnwrap(code.range(of: "switch event.stage {"),
                                 "EventDetailView no longer switches on the "
                                 + "stage, so this is reading nothing")
        let tail = code[body.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n        }"))

        let pattern = try NSRegularExpression(
            pattern: #"case \.\w+:\s*\n\s*(\w+)\("#)
        let region = String(tail[..<end.lowerBound])
        let matches = pattern.matches(
            in: region, range: NSRange(region.startIndex..., in: region))
        return matches.compactMap {
            Range($0.range(at: 1), in: region).map { String(region[$0]) }
        }
    }

    /// The precondition. A scan that has stopped matching reports an app with
    /// no screens, and every screen in an empty list is covered (L98, L100).
    func testTheScanFindsTheScreensTheAppReallyHas() throws {
        let screens = try screensTheAppCanShow()

        XCTAssertGreaterThanOrEqual(screens.count, 7, """
            the scan found \(screens) in EventDetailView, which is fewer than \
            the stages an event goes through. It has stopped reading the switch, \
            and a check over nothing passes.
            """)
        XCTAssertTrue(screens.allSatisfy { $0.hasSuffix("View") },
                      "the scan matched something that is not a view: \(screens)")
    }

    /// The screen a whole-screen surface is a picture of, or nil.
    ///
    /// Everything after the type name is the STATE being drawn, and a screen is
    /// allowed several: `OCRProgressView` is a different picture with an
    /// estimate and without one, and the empty one is what a first run shows.
    /// A rule that read the whole name would take each state for a screen of
    /// its own and report every variant as an orphan.
    static func screenType(of surfaceName: String) -> String? {
        guard surfaceName.hasPrefix(surfacePrefix) else { return nil }
        let rest = surfaceName.dropFirst(surfacePrefix.count)
        return String(rest.prefix { $0 != "," })
    }

    private func screenTypesOnTheSheet() -> [String] {
        HostedControlLegibilityTests().reviewSurfaceNames
            .compactMap(Self.screenType(of:))
    }

    func testTheVariantReadingTakesTheTypeAndNotTheState() {
        // The reading above decides both checks below, so it is asserted
        // directly rather than only through them (L178).
        XCTAssertEqual(Self.screenType(of: "screen: OCRProgressView"),
                       "OCRProgressView")
        XCTAssertEqual(Self.screenType(of: "screen: OCRProgressView, no estimate yet"),
                       "OCRProgressView")
        XCTAssertNil(Self.screenType(of: "caption card"),
                     "a surface that is not a whole screen is being read as one")
    }

    func testEveryScreenTheAppCanShowIsOnTheReviewSheet() throws {
        let onTheSheet = Set(screenTypesOnTheSheet())
        let missing = try screensTheAppCanShow().filter { !onTheSheet.contains($0) }

        XCTAssertEqual(missing, [], """
            these screens can be shown by the app and nothing renders them: \
            \(missing). A visual change to one can only be reviewed by launching \
            the app and navigating to it, which is what the sheet exists to \
            replace, and an absent screen looks exactly like one that was \
            reviewed and found fine. Add a surface named \
            "\(Self.surfacePrefix)<TypeName>" to reviewSurfaces.
            """)
    }

    /// The other direction. A surface claiming to be a whole screen, for a type
    /// the app can no longer show, is a picture nobody will ever compare against
    /// anything: it costs a render on every sheet and reviews nothing.
    func testEveryWholeScreenSurfaceIsAScreenTheAppCanShow() throws {
        let screens = Set(try screensTheAppCanShow())
        let orphaned = screenTypesOnTheSheet().filter { !screens.contains($0) }

        XCTAssertEqual(orphaned, [], """
            the sheet renders these as whole screens and EventDetailView can no \
            longer show them: \(orphaned). Either the screen was removed and its \
            surface should go with it, or it moved and the scan can no longer \
            see it.
            """)
    }
}
