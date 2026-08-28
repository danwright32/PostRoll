import XCTest

/// A suggested handle another row on this programme already holds is refused at
/// the moment it would be accepted (#904).
///
/// The web lookup proposes a handle per performer and each was accepted
/// individually, with nothing checking the proposal against the handles already
/// on the other rows. Accepting one that is taken creates the exact collision
/// #901 exists to report, one step before the warning appears, and the person
/// pressing the button is the one who could have stopped it.
///
/// Catching it at the point of the decision is better than warning about the
/// result: the decision has a person in front of it, and the result does not.
final class SuggestionCollisionTests: XCTestCase {

    private func performer(_ name: String, _ handle: String) -> Performer {
        Performer(id: UUID(), name: name, role: "", handle: handle)
    }

    private func suggestion(_ name: String, _ handle: String?)
    -> PythonBridge.HandleSuggestion {
        PythonBridge.HandleSuggestion(name: name, handle: handle)
    }

    func testAFreeHandleIsNotHeldByAnybody() {
        XCTAssertNil(SuggestionCollision.heldBy(
            suggestion("Ashley Liang Dance Company", "@lotus_dance_fairy"),
            among: [performer("NANM", "@nanmdancecompany"),
                    performer("Ashley Liang Dance Company", "")]))
    }

    func testAHandleAnotherRowHoldsIsNamedWithThatRow() {
        XCTAssertEqual(
            SuggestionCollision.heldBy(
                suggestion("Ashley Liang Dance Company", "@nanmdancecompany"),
                among: [performer("NANM", "@nanmdancecompany"),
                        performer("Ashley Liang Dance Company", "")]),
            "NANM",
            "the row that already holds it has to be NAMED, or the refusal "
            + "leaves the whole programme to be read by hand (L80)")
    }

    /// Instagram is case insensitive and the field is written both ways, so a
    /// collision spelled differently is the same account.
    func testTheComparisonIgnoresCaseAndTheSigil() {
        XCTAssertEqual(
            SuggestionCollision.heldBy(
                suggestion("Ashley Liang Dance Company", "NANMDanceCompany"),
                among: [performer("NANM", "@nanmdancecompany")]),
            "NANM")
    }

    /// The row the suggestion is FOR is not a collision with itself, however
    /// the lookup came to propose what it already has.
    func testARowDoesNotCollideWithItself() {
        XCTAssertNil(SuggestionCollision.heldBy(
            suggestion("NANM", "@nanmdancecompany"),
            among: [performer("NANM", "@nanmdancecompany")]))
    }

    func testASuggestionWithNoHandleCollidesWithNothing() {
        XCTAssertNil(SuggestionCollision.heldBy(
            suggestion("Ashley Liang Dance Company", nil),
            among: [performer("NANM", "@nanmdancecompany")]))
    }

    /// A sentinel is not an account. Two rows recorded as having no Instagram
    /// do not share one (L118).
    func testTwoRowsWithNoInstagramDoNotShareAnAccount() {
        XCTAssertNil(SuggestionCollision.heldBy(
            suggestion("Ashley Liang Dance Company", "unknown"),
            among: [performer("NANM", "unknown")]))
    }

    /// The refusal reads as an instruction, not a state. It has to say what to
    /// do, because both rows cannot be right and the app cannot know which.
    func testTheRefusalSaysWhatToDoAboutIt() {
        let line = SuggestionCollision.refusal(heldBy: "NANM")

        XCTAssertTrue(line.contains("NANM"), line)
        XCTAssertFalse(line.isEmpty)
    }
}
