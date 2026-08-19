import XCTest

/// What an event with no organisation does to everything downstream (#689).
///
/// The organisation stopped being required, which is one line. The work is
/// every reader that assumed it was filled in. An empty string was always
/// representable in the model, so these paths simply never saw one, and each of
/// them starts seeing one the moment the gate comes off.
///
/// Each test below is one of those readers, in the state it never used to reach.
final class OptionalOrganisationTests: XCTestCase {

    // MARK: - What the row says

    func testAnEventWithAnOrganisationIsStillBilledToIt() {
        // The control. The whole change is invisible for events that have one,
        // and a test that only checked the new case could not tell a working
        // fallback from one that had replaced everything (L159).
        XCTAssertEqual(EventCredit.leading(org: "Decoda", venue: "Merkin Hall"),
                       "Decoda")
    }

    func testAnEventWithNoOrganisationIsBilledToItsVenue() {
        XCTAssertEqual(EventCredit.leading(org: "", venue: "Merkin Hall"),
                       "Merkin Hall")
    }

    func testAnEventWithNeitherSaysNothingRatherThanShowingAGap() {
        // A blank where a fact used to be is not an absence on screen, it is
        // something that reads as broken. The row shows the date alone.
        XCTAssertNil(EventCredit.leading(org: "", venue: ""))
        XCTAssertNil(EventCredit.leading(org: "  ", venue: "\n"))
    }

    func testTheSpokenRowHasNoEmptySegment() throws {
        // VoiceOver announced "name, , date" with a silent gap in the middle,
        // which is indistinguishable from a fault in VoiceOver itself.
        let spoken = EventCredit.spokenRow(
            name: "Hamlet", org: "", venue: "", date: "20 Aug",
            shootType: "Full Show", stage: "Created")

        XCTAssertFalse(spoken.contains(", ,"), spoken)
        XCTAssertFalse(spoken.hasPrefix(","), spoken)
        XCTAssertTrue(spoken.hasPrefix("Hamlet, 20 Aug"), spoken)
    }

    func testTheSpokenRowStillNamesTheOrganisationWhenThereIsOne() {
        let spoken = EventCredit.spokenRow(
            name: "Hamlet", org: "Decoda", venue: "Merkin Hall", date: "20 Aug",
            shootType: "Full Show", stage: "Created")
        XCTAssertTrue(spoken.contains("Hamlet, Decoda, 20 Aug"), spoken)
    }

    // MARK: - Files named after the event

    func testTheProgramPdfIsNotNamedWithALeadingUnderscore() {
        // A file Dan saves and then has to find again. With no organisation the
        // name opened with a bare underscore, which reads as a mistake rather
        // than as an absence.
        XCTAssertEqual(EventFolder.stem(org: "", venue: "Kaufman Center",
                                        name: "Hamlet"),
                       "kaufman_center_hamlet")
        XCTAssertEqual(EventFolder.stem(org: "", venue: "", name: "Hamlet"),
                       "hamlet")
    }

    func testTheFolderAndTheFileAgreeOnWhoTheEventIsBilledTo() {
        // One rule, so a file saved beside an event and the folder holding it
        // cannot name two different things (L41).
        let stem = EventFolder.stem(org: "", venue: "Kaufman Center", name: "Hamlet")
        XCTAssertEqual(EventFolder.name(org: "", venue: "Kaufman Center",
                                        name: "Hamlet", isoDate: "2026-08-20"),
                       "\(stem)_2026-08-20")
    }

    // MARK: - The handle book

    /// Its own defaults, so the suite can never read or write the handles Dan
    /// has actually saved (L2).
    private var suiteNames: [String] = []

    override func tearDownWithError() throws {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
    }

    private func book() throws -> HandleBook {
        try bookAndStore().0
    }

    private func bookAndStore() throws -> (HandleBook, UserDefaults) {
        let name = "OptionalOrganisationTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (HandleBook(defaults: defaults), defaults)
    }

    func testNothingIsWrittenAgainstABlankOrganisation() throws {
        // The book is keyed by the normalised name. A blank key is one bucket
        // every event with no organisation shares, so handles saved while
        // working on one play would be prepended to the captions of every other
        // one. That is not a memory, it is a collision (L15).
        let (book, defaults) = try bookAndStore()

        book.record(org: "", handles: "@merkinhall")

        // Read from the STORE, not back through the book: the read side refuses
        // a blank key as well, so asking the book would report an empty answer
        // whether or not anything was written, and the two guards would mask
        // each other (L70).
        let stored = defaults.dictionary(forKey: HandleBook.orgKey) as? [String: String]
        XCTAssertNil(stored?[""],
                     "handles were saved against a blank organisation, so the "
                     + "next event without one inherits them")
    }

    func testABlankKeyAlreadyInTheBookIsNeverRead() throws {
        // The other half, and the only way to exercise it: nothing this type
        // does can produce a book holding a blank key, so the read guard could
        // never be seen to fail without one being planted (L1). It is also the
        // honest scenario, because a book written by an older build is not
        // something this one can assume the shape of.
        let (book, defaults) = try bookAndStore()
        defaults.set(["": "@stale"], forKey: HandleBook.orgKey)

        XCTAssertEqual(book.handles(forOrg: ""), "",
                       "a blank key left in the book is handed to every event "
                       + "that has no organisation")
    }

    func testABlankVenueIsRefusedTheSameWay() throws {
        let book = try book()
        book.record(venue: "   ", handles: "@somewhere")
        XCTAssertEqual(book.handles(forVenue: ""), "")
    }

    func testARealOrganisationIsStillRemembered() throws {
        // The control for the two above: a guard that refused everything would
        // satisfy them both while breaking the feature (L159).
        let book = try book()
        book.record(org: "Decoda", handles: "@decodamusic")
        XCTAssertEqual(book.handles(forOrg: "Decoda"), "@decodamusic")
        XCTAssertEqual(book.handles(forOrg: "  decoda "), "@decodamusic",
                       "the normalising lookup stopped working")
    }
}
