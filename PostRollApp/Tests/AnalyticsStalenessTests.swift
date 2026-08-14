import XCTest

/// The Insights screen has to say when the numbers it is showing were imported
/// before the Meta export timezone correction (#549, from #487).
///
/// Every check here compares a pinned fixture date against the pinned constant
/// the code itself uses. Nothing reads the current clock: a fixture whose
/// meaning is its RELATIONSHIP to a moment must pin both ends, or real time
/// walks the pair into a different case and the test passes while asserting
/// about a situation nobody chose (L130).
final class AnalyticsStalenessTests: XCTestCase {

    /// Comfortably before the correction, and fixed.
    private let beforeFix = Date(timeIntervalSince1970: 1_785_456_000) // 2026-07-31T00:00:00Z
    /// Comfortably after it, and fixed.
    private let afterFix = Date(timeIntervalSince1970: 1_787_529_600)  // 2026-08-24T00:00:00Z

    // MARK: - The constant itself

    /// The fixture dates above are only meaningful if they really do straddle
    /// the constant, so that is asserted rather than assumed.
    func testFixtureDatesStraddleTheCorrection() {
        XCTAssertLessThan(beforeFix, AnalyticsStaleness.timezoneCorrection)
        XCTAssertGreaterThan(afterFix, AnalyticsStaleness.timezoneCorrection)
    }

    /// The correction landed on main on 2026-08-14T02:43:25Z. The constant sits
    /// at or after that instant, so no import made under the old reading can
    /// slip past it. Erring later means at worst a warning about a good import,
    /// which is the safe direction; erring earlier would let a wrong one
    /// through silently.
    func testConstantIsNotEarlierThanTheMergeThatFixedIt() {
        let merged = Date(timeIntervalSince1970: 1_786_675_405) // 2026-08-14T02:43:25Z
        XCTAssertGreaterThanOrEqual(AnalyticsStaleness.timezoneCorrection, merged)
    }

    // MARK: - When the notice fires

    func testPostsImportedBeforeTheCorrectionAreStale() {
        XCTAssertTrue(AnalyticsStaleness.isStale(postCount: 34, lastImport: beforeFix))
    }

    /// No `lastImport` at all means the import predates the field, which puts it
    /// earlier still than the correction.
    func testPostsWithNoRecordedImportDateAreStale() {
        XCTAssertTrue(AnalyticsStaleness.isStale(postCount: 34, lastImport: nil))
    }

    func testPostsImportedAfterTheCorrectionAreNotStale() {
        XCTAssertFalse(AnalyticsStaleness.isStale(postCount: 34, lastImport: afterFix))
    }

    /// An import landing exactly on the constant is the corrected code running,
    /// so it is not stale. Pinned because an off by one here decides whether the
    /// notice is permanent furniture.
    func testAnImportExactlyOnTheCorrectionIsNotStale() {
        XCTAssertFalse(AnalyticsStaleness.isStale(
            postCount: 34, lastImport: AnalyticsStaleness.timezoneCorrection))
    }

    // MARK: - When it must stay quiet

    /// A store with nothing in it has nothing wrong with it. Without this, the
    /// nil case would fire on a first launch and tell Dan his numbers are wrong
    /// before he has any.
    func testAnEmptyStoreIsNeverStale() {
        XCTAssertFalse(AnalyticsStaleness.isStale(postCount: 0, lastImport: nil))
        XCTAssertFalse(AnalyticsStaleness.isStale(postCount: 0, lastImport: beforeFix))
    }

    // MARK: - What it says

    /// The notice has to name the action that actually changes the state, not
    /// merely describe the problem (L111). The control beside it is "Import
    /// CSV", so those are the words it uses.
    func testTheNoticeNamesTheControlThatFixesIt() {
        XCTAssertTrue(AnalyticsStaleness.notice.contains("Import CSV"),
                      "The notice must name the control that clears it: \(AnalyticsStaleness.notice)")
    }

    /// It has to say what is actually wrong with the numbers, in hours, because
    /// "these may be out of date" gives Dan no way to judge whether it matters.
    func testTheNoticeSaysWhatIsWrongWithTheNumbers() {
        XCTAssertTrue(AnalyticsStaleness.notice.contains("three hours"),
                      "The notice must say how far out the times read: \(AnalyticsStaleness.notice)")
    }

    // MARK: - That the screen actually uses it

    /// Built is not wired (L3). A staleness rule nothing on the Insights screen
    /// calls is a claim, and every check above it would stay green for as long
    /// as it went unwired.
    ///
    /// Comments are stripped before matching, because the source carries an
    /// explanatory comment naming this very type, and a guard satisfied by prose
    /// about the thing is indistinguishable from one satisfied by the thing
    /// (L103).
    func testTheInsightsScreenCallsTheStalenessRule() throws {
        let overview = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .appendingPathComponent("Sources/Views/Insights/InsightsOverviewView.swift")
        let code = SwiftSourceText.withoutComments(
            try String(contentsOf: overview, encoding: .utf8))

        XCTAssertTrue(code.contains("AnalyticsStaleness.isStale"),
                      "The Insights screen must decide with the shared rule.")
        XCTAssertTrue(code.contains("AnalyticsStaleness.notice"),
                      "The Insights screen must render the shared wording, not its own copy.")
    }

    /// House style: no dashes as punctuation, and no emoji.
    func testTheNoticeUsesNoDashPunctuation() {
        for scalar in AnalyticsStaleness.notice.unicodeScalars {
            XCTAssertNotEqual(scalar, "\u{2014}", "em dash in the notice")
            XCTAssertNotEqual(scalar, "\u{2013}", "en dash in the notice")
        }
    }
}
