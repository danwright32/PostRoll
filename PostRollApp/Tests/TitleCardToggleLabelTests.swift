import XCTest

/// TitleCardToggleLabel.text drives the review screen's "Title card:
/// On"/"Off" button (plan #148, Phase 3). Extracted so the label logic is
/// covered directly rather than only embedded in the view.
final class TitleCardToggleLabelTests: XCTestCase {

    func testLabelWhenNotMuted() {
        XCTAssertEqual(TitleCardToggleLabel.text(muted: false), "Title card: On")
    }

    func testLabelWhenMuted() {
        XCTAssertEqual(TitleCardToggleLabel.text(muted: true), "Title card: Off")
    }
}
