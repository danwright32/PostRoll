import XCTest

/// Which of the two ways out of a halt looks like the obvious one.
///
/// Found by rendering the screen (#393) rather than by reading the code, which
/// said the opposite of what it drew: a comment explained that spending money
/// should look like the deliberate choice, while the paid option was the only
/// thing on screen with a button's appearance at all and the free one rendered
/// as plain text above its own explanation.
///
/// A control has to look like a control at rest, and the option that costs
/// money must not be the one the eye lands on after a shoot.
final class HaltChoiceEmphasisTests: XCTestCase {

    func testTheFreeOptionCarriesTheWeight() {
        XCTAssertEqual(HaltChoiceEmphasis.of(.waitForReset), .primary,
                       "waiting costs nothing, so it is the one to land on")
    }

    func testSpendingMoneyIsAControlButNotTheProminentOne() {
        XCTAssertEqual(HaltChoiceEmphasis.of(.finishOnPaidPath), .secondary,
                       "it has to look clickable, and it must not outrank the free way out")
    }

    /// The rule, not the two cases: whatever choices the halt screen grows,
    /// none may render as bare text, and the money one may never be the most
    /// prominent thing on the screen.
    func testEveryChoiceIsAControlAndOnlyOneIsPrimary() {
        let emphases = HaltedWeek.Choice.allCases.map(HaltChoiceEmphasis.of)

        XCTAssertEqual(emphases.filter { $0 == .primary }.count, 1,
                       "exactly one obvious action, or the screen offers no lead at all")
        for choice in HaltedWeek.Choice.allCases where choice.spendsMoney {
            XCTAssertNotEqual(HaltChoiceEmphasis.of(choice), .primary,
                              "\(choice.label) spends money and must not be the lead action")
        }
    }
}
