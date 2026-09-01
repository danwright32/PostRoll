import XCTest

/// The retry has to SAY what it did (#1160).
///
/// Repairs are silent, so a retry that repaired nothing and a retry that
/// repaired everything both just update the panel. That is the same complaint
/// this issue was raised about, one step further on: a control that acts and
/// reports nothing leaves Dan pressing it again to find out (L98, L11).
final class BlogRepairRetryReportTests: XCTestCase {

    private func result(ran: Bool, selected: Int,
                        repaired: Int) -> BlogRepairRetryResult {
        var out = BlogRepairRetryResult()
        out.retry = .init(ran: ran, selected: selected, repaired: repaired)
        return out
    }

    func testARetryThatRewroteSomeSaysHowMany() {
        XCTAssertEqual(result(ran: true, selected: 3, repaired: 2).note,
                       "Rewrote 2 of 3.")
    }

    func testARetryThatRewroteNothingIsNotReportedAsAFailure() {
        // The app tried and its own checks refused the result, which is
        // `tried`. Calling that a failure invites pressing the button forever.
        let note = result(ran: true, selected: 3, repaired: 0).note
        XCTAssertTrue(note.contains("will not help"), note)
        XCTAssertFalse(note.lowercased().contains("failed"), note)
    }

    func testARetryThatFoundNothingLeftSaysSo() {
        XCTAssertEqual(result(ran: true, selected: 0, repaired: 0).note,
                       "Nothing left to retry.")
    }

    func testARetryThatDidNotFinishIsDistinctFromOneThatFixedNothing() {
        // Three outcomes, three sentences. Collapsing any pair loses the one
        // thing the sentence exists to carry.
        let notes = Set([
            result(ran: false, selected: 3, repaired: 0).note,
            result(ran: true, selected: 3, repaired: 0).note,
            result(ran: true, selected: 3, repaired: 3).note,
        ])
        XCTAssertEqual(notes.count, 3, "two outcomes read the same: \(notes)")
    }

    func testTheOutcomeCarriesTheNoteBackToTheScreen() {
        // The gap this test exists for: the sentence was computed and never
        // put anywhere a person could see it.
        var outcome = CaptionWorkManager.Outcome()
        outcome.retryNote = result(ran: true, selected: 3, repaired: 2).note
        XCTAssertEqual(outcome.retryNote, "Rewrote 2 of 3.")
    }
}
