import XCTest
@testable import PostRoll

/// Covers Performer.designation, the label shown next to a performer's name in
/// the Assign Performers section (e.g. "Mike Bono, guitar"). The Assign
/// Performers UI lives behind the Python OCR flow, so the selection logic is
/// verified here rather than in the UI smoke test.
final class PerformerDesignationTests: XCTestCase {

    func testPrefersInstrumentOverRole() {
        let p = Performer(name: "Mike Bono", role: "ensemble", voiceOrInstrument: "guitar")
        XCTAssertEqual(p.designation, "guitar")
    }

    func testFallsBackToRoleWhenNoInstrument() {
        let p = Performer(name: "Jane Doe", role: "conductor")
        XCTAssertEqual(p.designation, "conductor")
    }

    func testEmptyWhenNeitherKnown() {
        let p = Performer(name: "Anon")
        XCTAssertEqual(p.designation, "")
    }

    func testTrimsWhitespace() {
        let p = Performer(name: "Spacey", voiceOrInstrument: "  cello  ")
        XCTAssertEqual(p.designation, "cello")
    }

    func testWhitespaceOnlyInstrumentFallsBackToRole() {
        let p = Performer(name: "Edge", role: "soprano", voiceOrInstrument: "   ")
        XCTAssertEqual(p.designation, "soprano")
    }
}
