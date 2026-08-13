import XCTest

/// #526: a failed learn-from-edits pass must not read as "nothing to suggest".
///
/// The caption screen ran that pass behind `try?`, so a Claude call that failed
/// produced the same nil the pass produces when it genuinely has no suggestion
/// to make. Both went down the same branch, the week advanced, and Dan was
/// never told his edits had not been reviewed. Two causes, one screen, and no
/// way to tell them apart (L11).
final class LearnFromEditsOutcomeTests: XCTestCase {

    func testASuggestionIsOffered() {
        XCTAssertEqual(
            LearnFromEditsOutcome.decide(suggestion: "Write shorter openers.", failure: nil),
            .offerSuggestion("Write shorter openers.")
        )
    }

    func testNoSuggestionAdvancesTheWeek() {
        XCTAssertEqual(
            LearnFromEditsOutcome.decide(suggestion: nil, failure: nil),
            .advance
        )
    }

    /// The pass answering with empty text is the same answer as nil, not a
    /// sheet with nothing in it.
    func testAnEmptySuggestionAdvancesTheWeek() {
        XCTAssertEqual(
            LearnFromEditsOutcome.decide(suggestion: "   \n ", failure: nil),
            .advance
        )
    }

    func testAFailedPassIsReportedRatherThanTreatedAsNothingToSay() {
        guard case .reportFailure(let message) = LearnFromEditsOutcome.decide(
            suggestion: nil, failure: "the model timed out") else {
            return XCTFail("a failed pass took the same branch as an empty one")
        }
        XCTAssertTrue(message.contains("the model timed out"),
                      "the reason Dan needs is not in the message: \(message)")

        guard case .reportFailure(let other) = LearnFromEditsOutcome.decide(
            suggestion: nil, failure: "the disk is full") else {
            return XCTFail("a second failure did not report either")
        }
        XCTAssertNotEqual(message, other,
                          "every failure says the same thing, so the reason is decoration")
    }

    /// A failure beats a partial answer. If the pass threw, whatever came back
    /// before it threw is not something to put in front of Dan as a suggestion.
    func testAFailureWinsOverAnyPartialSuggestion() {
        guard case .reportFailure = LearnFromEditsOutcome.decide(
            suggestion: "half a thought", failure: "the model timed out") else {
            return XCTFail("a partial answer masked the failure that produced it")
        }
    }

    /// The failure is reported without also blocking the week: the export is
    /// the work, and the learning pass is an extra on the end of it. So the
    /// notice has to name what Dan can still do.
    func testTheFailureNoticeSaysTheWeekCanStillGoOn() {
        guard case .reportFailure(let message) = LearnFromEditsOutcome.decide(
            suggestion: nil, failure: "the model timed out") else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(message.lowercased().contains("captions are saved"),
                      "the notice does not tell Dan his edits survived: \(message)")
    }
}
