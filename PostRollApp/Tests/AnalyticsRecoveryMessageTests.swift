import XCTest

/// #88: a failed analytics.json decode reached an NSLog and nothing else, so
/// the entire imported Instagram history could be set aside and all Dan would
/// see is an empty Insights screen. An empty state reads as "nothing imported
/// yet"; it is not the same screen as "your data could not be read".
final class AnalyticsRecoveryMessageTests: XCTestCase {

    func testItSaysTheHistoryCouldNotBeRead() {
        let text = AnalyticsStore.recoveryText(setAsideAs: "analytics.json.broken", restorable: false)
        XCTAssertTrue(text.contains("could not be read"), text)
    }

    func testItNamesWhereTheUnreadableFileWent() {
        let text = AnalyticsStore.recoveryText(setAsideAs: "analytics.json.broken", restorable: false)
        XCTAssertTrue(text.contains("Nothing was deleted"), text)
        XCTAssertTrue(text.contains("analytics.json.broken"), text)
    }

    func testItAdmitsWhenTheFileCouldNotEvenBeSetAside() {
        // Claiming "nothing was deleted, it was set aside as ..." when the
        // set-aside failed would be a promise the code did not keep.
        let text = AnalyticsStore.recoveryText(setAsideAs: nil, restorable: false)
        XCTAssertTrue(text.contains("could not be set aside"), text)
        XCTAssertFalse(text.contains("Nothing was deleted"), text)
    }

    func testItSaysWhetherThereIsAnythingToRestore() {
        let with = AnalyticsStore.recoveryText(setAsideAs: "x", restorable: true)
        let without = AnalyticsStore.recoveryText(setAsideAs: "x", restorable: false)
        XCTAssertTrue(with.contains("can be restored"), with)
        XCTAssertTrue(without.contains("no earlier backup"), without)
    }
}
