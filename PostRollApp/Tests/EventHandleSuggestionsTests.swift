import XCTest

/// The organization and venue handle fields are free text, not a bare handle:
/// Dan writes things like "@bludlineodyssey presented by @matchbookfestival".
/// Those accounts need offering as one-tap suggestions when tagging a photo,
/// so the handles have to be pulled out of the sentence rather than the whole
/// string being treated as one tag.
final class EventHandleSuggestionsTests: XCTestCase {

    func testPullsEveryHandleOutOfASentence() {
        XCTAssertEqual(
            EventHandleSuggestions.tokens(from: "@bludlineodyssey presented by @matchbookfestival"),
            ["@bludlineodyssey", "@matchbookfestival"],
            "both accounts must be offered, not the sentence as a single tag")
    }

    func testHandlesABareHandleAndACommaSeparatedList() {
        XCTAssertEqual(EventHandleSuggestions.tokens(from: "@greenwich_house"), ["@greenwich_house"])
        XCTAssertEqual(EventHandleSuggestions.tokens(from: "@one, @two"), ["@one", "@two"])
    }

    func testKeepsDotsAndUnderscoresWhichRealHandlesUse() {
        XCTAssertEqual(EventHandleSuggestions.tokens(from: "@safa.wav and @greenwich_house"),
                       ["@safa.wav", "@greenwich_house"])
    }

    func testStripsTrailingPunctuationThatIsNotPartOfTheHandle() {
        XCTAssertEqual(EventHandleSuggestions.tokens(from: "@dciny, @lincolncenter."),
                       ["@dciny", "@lincolncenter"])
    }

    func testTheSameHandleTwiceIsOfferedOnce() {
        XCTAssertEqual(EventHandleSuggestions.tokens(from: "@same and @Same again"), ["@same"])
    }

    // MARK: - Degenerate input

    func testTextWithNoHandlesGivesNothing() {
        XCTAssertTrue(EventHandleSuggestions.tokens(from: "presented by the festival").isEmpty,
                      "plain prose must not become a tag")
        XCTAssertTrue(EventHandleSuggestions.tokens(from: "").isEmpty)
        XCTAssertTrue(EventHandleSuggestions.tokens(from: "@").isEmpty,
                      "a bare @ is not a handle")
    }

    func testPlaceholderHandlesAreNotOffered() {
        XCTAssertTrue(EventHandleSuggestions.tokens(from: "@unknown").isEmpty,
                      "the sentinel written when no handle was found must never be tagged")
        XCTAssertEqual(EventHandleSuggestions.tokens(from: "@none and @realaccount"), ["@realaccount"])
    }
}
