import XCTest

/// The tagging sheet's suggestion list (#292).
///
/// The event's own accounts were read with `EventHandleSuggestions.tokens(fromAll:)`,
/// which finds only `@` handles inside prose. Every event on disk writes that
/// field as a comma separated list of bare names, so the list was empty on all
/// 19 of them, and an empty list reads as "there is nothing to suggest" rather
/// than as a parse that found nothing.
final class PhotoTagSuggestionListTests: XCTestCase {

    private func performer(_ name: String, handle: String = "",
                           instrument: String = "") -> Performer {
        Performer(name: name, voiceOrInstrument: instrument, handle: handle)
    }

    // MARK: - The field as every real event writes it

    func testTheCommaSeparatedBareNamesEveryRealEventUsesAreOffered() {
        // Verbatim from the events on disk.
        let list = PhotoTagSuggestionList.build(eventHandles: "dciny, carnegiehall",
                                                performers: [], appearingIn: [])

        XCTAssertEqual(list.map(\.token), ["@dciny", "@carnegiehall"])
    }

    func testASentenceOfHandlesIsStillRead() {
        let list = PhotoTagSuggestionList.build(
            eventHandles: "@bludlineodyssey presented by @matchbookfestival",
            performers: [], appearingIn: [])

        XCTAssertEqual(list.map(\.token), ["@bludlineodyssey", "@matchbookfestival"])
    }

    func testProseThatNamesNoAccountOffersNothing() {
        // The failure this must not trade for: a description of the event
        // becoming an account nobody can tag.
        XCTAssertEqual(
            PhotoTagSuggestionList.build(eventHandles: "Carnegie Hall, New York",
                                         performers: [], appearingIn: []).count,
            0)
    }

    func testAnEmptyFieldOffersNothing() {
        XCTAssertEqual(
            PhotoTagSuggestionList.build(eventHandles: "", performers: [],
                                         appearingIn: []).count,
            0)
    }

    // MARK: - One vocabulary across both halves

    func testAnAccountWrittenBareAndAPerformerHandleAreOneSuggestion() {
        // The two halves write the same account in two spellings, so a list
        // that deduplicates on the raw text offers it twice and the person
        // cannot tell the two entries apart.
        let list = PhotoTagSuggestionList.build(
            eventHandles: "carnegiehall",
            performers: [performer("Carnegie Hall", handle: "@CarnegieHall")],
            appearingIn: [])

        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.map { $0.token.lowercased() }, ["@carnegiehall"])
    }

    func testPerformersComeBeforeTheEventsOwnAccounts() {
        let list = PhotoTagSuggestionList.build(
            eventHandles: "carnegiehall",
            performers: [performer("Ana Vidović", handle: "anavidovic")],
            appearingIn: [])

        XCTAssertEqual(list.map(\.token), ["@anavidovic", "@carnegiehall"])
    }

    // MARK: - The performer half, unchanged

    func testAPerformerWithNoRealHandleIsOfferedByName() {
        let list = PhotoTagSuggestionList.build(eventHandles: "", performers: [
            performer("Ana Vidović", handle: "none", instrument: "guitar")
        ], appearingIn: [])

        XCTAssertEqual(list.map(\.token), ["Ana Vidović"])
        XCTAssertEqual(list.map(\.display), ["Ana Vidović guitar"])
    }

    func testPerformersMarkedAsAppearingComeFirstInTheirOriginalOrder() {
        let a = performer("A", handle: "a")
        let b = performer("B", handle: "b")
        let c = performer("C", handle: "c")
        let list = PhotoTagSuggestionList.build(eventHandles: "",
                                                performers: [a, b, c],
                                                appearingIn: [c.id])

        XCTAssertEqual(list.map(\.token), ["@c", "@a", "@b"])
    }

    func testAPerformerWithNeitherNameNorHandleIsNotOffered() {
        let list = PhotoTagSuggestionList.build(eventHandles: "",
                                                performers: [performer("", handle: "")],
                                                appearingIn: [])

        XCTAssertEqual(list.count, 0)
    }
}
