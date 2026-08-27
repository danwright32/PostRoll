import XCTest

/// Two companies on one handle must not become one credit.
///
/// The credit list deduplicates handles, which is right: a caption may tag an
/// account once. But a performer carrying a real handle is credited ONLY by
/// that handle, so when two of them carry the same one, the dedupe leaves a
/// single mention and the second company is never named anywhere in the
/// caption. Measured on Battery Dance Festival, 2026-08-27, where a paste put
/// `@nanmdancecompany` on both "Ashley Liang Dance Company" and "NANM".
///
/// Nothing downstream can catch it. `missing_credits` in caption_credits.py
/// walks the handles it was given, finds `@nanmdancecompany` present in the
/// caption, and reports every credit satisfied. The check that exists to catch
/// a missing credit is blind to exactly this case, because both performers
/// resolve to the one handle it is looking for (L144: the monitor and the
/// action agree precisely when they are both wrong).
///
/// So a performer whose handle is shared is credited by NAME as well. The
/// account is still tagged once, and both companies are named.
final class CaptionCreditDuplicateHandleTests: XCTestCase {

    private func event(_ performers: [Performer], selecting: [UUID]) -> (PostingDay, Event) {
        var event = Event(name: "Battery Dance Festival", org: "Battery Dance",
                          venue: "Rockefeller Park",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        var ocr = OCRResult()
        ocr.performers = performers
        event.ocrResult = ocr
        event.eventHandles = "@batterydance"

        var day = PostingDay(day: .wednesday)
        day.photoPaths = [URL(fileURLWithPath: "/photos/w1.jpg")]
        day.selectedPerformerIDs = selecting
        event.days[DayName.wednesday.rawValue] = day
        return (day, event)
    }

    /// Verbatim from the event on disk.
    private func theTwoCompanies() -> [Performer] {
        [Performer(name: "Ashley Liang Dance Company", handle: "@nanmdancecompany"),
         Performer(name: "NANM", handle: "@nanmdancecompany")]
    }

    func testBothCompaniesAreNamedWhenTheyShareOneHandle() {
        let performers = theTwoCompanies()
        let (day, event) = event(performers, selecting: performers.map(\.id))

        let credits = CaptionCreditInputs.forDay(day, event: event)

        XCTAssertEqual(credits.names, ["Ashley Liang Dance Company", "NANM"])
    }

    func testTheSharedAccountIsStillOfferedExactlyOnce() {
        // The dedupe is right and stays. An account cannot be tagged twice.
        let performers = theTwoCompanies()
        let (day, event) = event(performers, selecting: performers.map(\.id))

        let credits = CaptionCreditInputs.forDay(day, event: event)

        XCTAssertEqual(credits.handles, ["@batterydance", "@nanmdancecompany"])
    }

    func testAPerformerWithAHandleOfTheirOwnIsNotAlsoNamed() {
        // The existing rule, unchanged: a handle is the credit, and adding the
        // name to every one of them would put the whole cast into the prose.
        let performers = [Performer(name: "Ina Medhanet", handle: "@inamedhanet"),
                          Performer(name: "NANM", handle: "@nanmdancecompany")]
        let (day, event) = event(performers, selecting: performers.map(\.id))

        let credits = CaptionCreditInputs.forDay(day, event: event)

        XCTAssertEqual(credits.names, [])
    }

    func testOnlyOneHalfSelectedIsNotADuplicate() {
        // Whether the caption collapses two credits depends on who is posted
        // THIS day, not on who is in the programme. With one of them left out
        // there is nothing to collapse, and naming the other company would
        // credit a performance that is not in these photos (L166).
        let performers = theTwoCompanies()
        let (day, event) = event(performers, selecting: [performers[0].id])

        let credits = CaptionCreditInputs.forDay(day, event: event)

        XCTAssertEqual(credits.names, [])
        XCTAssertEqual(credits.handles, ["@batterydance", "@nanmdancecompany"])
    }

    func testAPerformerWithNoHandleIsStillNamedAsBefore() {
        let performers = [Performer(name: "DPR Dance", handle: "none")]
        let (day, event) = event(performers, selecting: performers.map(\.id))

        let credits = CaptionCreditInputs.forDay(day, event: event)

        XCTAssertEqual(credits.names, ["DPR Dance"])
    }
}
