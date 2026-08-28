import XCTest

/// The tagging sheet says when it is offering fewer people than the programme
/// has (#902).
///
/// Two performers carrying one handle collapse to a single suggestion chip,
/// because an account can only be tagged once and the dedupe that does it is
/// deliberate. Measured on Battery Dance Festival, 2026-08-27: six performers,
/// five chips, and nothing said.
///
/// #901 put a warning on the Review screen. The sheet is where the absence is
/// actually noticed, and it still said nothing, so somebody counting chips
/// against the programme had no way to tell a person who is missing from a
/// person who was never there.
final class PhotoTagSheetNoteTests: XCTestCase {

    private func performer(_ name: String, _ handle: String) -> Performer {
        Performer(id: UUID(), name: name, role: "", handle: handle)
    }

    private func sheet(_ performers: [Performer],
                       eventHandles: String = "") -> PhotoTagSuggestionList.Sheet {
        PhotoTagSuggestionList.sheet(eventHandles: eventHandles,
                                     performers: performers,
                                     appearingIn: [])
    }

    func testACleanProgrammeSaysNothing() {
        let out = sheet([performer("NANM", "@nanmdancecompany"),
                         performer("Ashley Liang Dance Company", "@lotus_dance_fairy")])

        XCTAssertEqual(out.suggestions.count, 2)
        XCTAssertNil(out.note, "a sheet offering everybody has nothing to report")
    }

    func testTwoPerformersOnOneAccountAreCountedAndNamed() throws {
        let out = sheet([performer("NANM", "@nanmdancecompany"),
                         performer("Ashley Liang Dance Company", "@nanmdancecompany")])

        XCTAssertEqual(out.suggestions.count, 1,
                       "the dedupe is deliberate and stays: an account can "
                       + "only be tagged once")
        let note = try XCTUnwrap(out.note,
                                 "the sheet offers one of two people and says "
                                 + "nothing, which is the whole of #902")
        XCTAssertTrue(note.contains("1 of 2"), note)
        XCTAssertTrue(note.contains("Ashley Liang Dance Company"), note)
    }

    /// Naming WHICH row is left out is the point. A count alone leaves the
    /// whole programme to be read by hand to find out who (L80).
    func testItNamesTheRowThatWasDroppedNotTheOneThatSurvived() throws {
        let note = try XCTUnwrap(
            sheet([performer("NANM", "@nanmdancecompany"),
                   performer("Ashley Liang Dance Company", "@nanmdancecompany")]).note)

        XCTAssertFalse(note.hasPrefix("NANM"),
                       "the surviving row is on the list already, so naming it "
                       + "sends somebody looking for a chip that is there")
    }

    func testSeveralDroppedRowsAreAllNamed() throws {
        let note = try XCTUnwrap(
            sheet([performer("NANM", "@shared"),
                   performer("Ashley Liang", "@shared"),
                   performer("Third Company", "@shared")]).note)

        XCTAssertTrue(note.contains("1 of 3"), note)
        XCTAssertTrue(note.contains("Ashley Liang"), note)
        XCTAssertTrue(note.contains("Third Company"), note)
    }

    /// A row with neither a name nor a handle was never offerable, so it is not
    /// somebody the sheet dropped. Counting it would report a hole in the list
    /// that nothing can fill.
    func testARowWithNothingToOfferIsNotCountedAsMissing() {
        XCTAssertNil(sheet([performer("NANM", "@nanmdancecompany"),
                            performer("", "")]).note)
    }

    /// The event's own accounts are prepended and deduped against the
    /// performers, so a venue that is also a performer's handle drops the
    /// performer's chip. Same loss, same sentence.
    func testAPerformerWhoseHandleIsAlsoTheVenueIsReported() throws {
        let note = try XCTUnwrap(
            sheet([performer("The Hall Itself", "@carnegiehall")],
                  eventHandles: "carnegiehall").note)

        XCTAssertTrue(note.contains("The Hall Itself"), note)
    }

    /// The list the sheet draws is the one this counted, not a second reading
    /// of the same performers (L107).
    func testTheCountMatchesTheListItIsAbout() {
        let out = sheet([performer("NANM", "@nanmdancecompany"),
                         performer("Ashley Liang Dance Company", "@nanmdancecompany")])

        XCTAssertEqual(out.suggestions,
                       PhotoTagSuggestionList.build(eventHandles: "",
                                                    performers: [
                                                        performer("NANM", "@nanmdancecompany"),
                                                        performer("Ashley Liang Dance Company",
                                                                  "@nanmdancecompany")],
                                                    appearingIn: []))
    }
}
