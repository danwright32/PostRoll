import XCTest

/// Reading a `postroll://` link into the five fields the New Event sheet asks
/// for (#840).
///
/// The link is written by Downbeat into an OmniFocus task note, so everything
/// on this side arrives as text somebody could have hand edited between the two
/// (L23). Every refusal below is a separate case with its own sentence, because
/// a link that opened nothing and said one generic thing is a link Dan cannot
/// fix (L11).
///
/// The calendar is pinned rather than inherited. `YYYYMMDD` means a day, and
/// which instant that day starts at is decided entirely by the ambient time
/// zone: a test that takes `.current` is a test whose verdict is a property of
/// the Mac running it (L504).
final class DeepLinkTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private let booking = UUID(uuidString: "6E5F3B9A-1C2D-4E5F-8A9B-0C1D2E3F4A5B")!

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("the fixture itself is not a URL: \(string)")
            return URL(string: "postroll://new")!
        }
        return url
    }

    private func draft(_ string: String) throws -> DeepLink.EventDraft {
        switch DeepLink.draft(from: url(string), calendar: calendar) {
        case .success(let draft):
            return draft
        case .failure(let refusal):
            XCTFail("expected a draft, was refused: \(refusal.message)")
            throw XCTSkip("no draft")
        }
    }

    private func refusal(_ string: String) throws -> DeepLink.Refusal {
        switch DeepLink.draft(from: url(string), calendar: calendar) {
        case .success(let draft):
            XCTFail("expected a refusal, got a draft for \(draft)")
            throw XCTSkip("no refusal")
        case .failure(let refusal):
            return refusal
        }
    }

    // MARK: - The link Downbeat actually writes

    func testTheFiveFieldsArriveInTheDraft() throws {
        let made = try draft(
            "postroll://new?name=Brahms%20Requiem&org=Oratorio%20Society"
            + "&venue=Carnegie%20Hall&room=Stern%20Auditorium"
            + "&date=20260822&booking=\(booking.uuidString)")

        XCTAssertEqual(made.name, "Brahms Requiem")
        XCTAssertEqual(made.org, "Oratorio Society")
        XCTAssertEqual(made.venue, "Carnegie Hall")
        XCTAssertEqual(made.venueContext, "Stern Auditorium")
        XCTAssertEqual(made.bookingID, booking)
    }

    func testTheDateIsTheDayItNames() throws {
        let made = try draft(
            "postroll://new?name=Show&date=20260822&booking=\(booking.uuidString)")

        let parts = calendar.dateComponents([.year, .month, .day], from: made.date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 8)
        XCTAssertEqual(parts.day, 22)
    }

    func testTheDateIsTheStartOfThatDayWhereDanIs() throws {
        // The sheet shows a day, and the store keeps an instant. Landing
        // anywhere but the start of the day in the local calendar means a link
        // for the 22nd can render as the 21st or the 23rd depending on nothing
        // the link says.
        let made = try draft(
            "postroll://new?name=Show&date=20260822&booking=\(booking.uuidString)")

        XCTAssertEqual(made.date, calendar.startOfDay(for: made.date))
    }

    func testTheOptionalFieldsMayBeAbsent() throws {
        let made = try draft(
            "postroll://new?name=Show&date=20260822&booking=\(booking.uuidString)")

        XCTAssertEqual(made.org, "")
        XCTAssertEqual(made.venue, "")
        XCTAssertEqual(made.venueContext, "")
    }

    func testAnEmptyNameIsCarriedRatherThanRefused() throws {
        // Deliberately NOT a refusal here: the sheet already has one predicate
        // for a missing name and already says it out loud
        // (`NewEventValidation.refusal`). A second refusal in the parser would
        // be a second answer to the same question, and this one would be given
        // with no form on screen to fix it on.
        let made = try draft(
            "postroll://new?name=&date=20260822&booking=\(booking.uuidString)")

        XCTAssertEqual(made.name, "")
        XCTAssertNotNil(NewEventValidation.refusal(name: made.name),
                        "the parser lets a blank name through on the understanding that "
                        + "the sheet refuses it, and the sheet no longer does")
    }

    func testAFieldWrappedAcrossTwoLinesIsFolded() throws {
        // Same rule as a paste into the form itself (#688): these values reach
        // folder names, captions and the handle book's keys, and a break in the
        // middle renders as a space that nothing says is really a newline.
        let made = try draft(
            "postroll://new?name=Symphony%0ANo.%205&date=20260822"
            + "&booking=\(booking.uuidString)")

        XCTAssertEqual(made.name, "Symphony No. 5")
    }

    func testUnknownParametersAreIgnoredRatherThanRefused() throws {
        // Downbeat may add to the link before this side learns about it. A new
        // parameter must not make an otherwise good link unopenable.
        let made = try draft(
            "postroll://new?name=Show&date=20260822&booking=\(booking.uuidString)"
            + "&genre=Choral")

        XCTAssertEqual(made.name, "Show")
    }

    // MARK: - Refusals, each with its own sentence

    func testALinkForSomethingElseIsRefusedByName() throws {
        let refused = try refusal("postroll://edit?name=Show")

        XCTAssertEqual(refused, .unknownAction("edit"))
        XCTAssertTrue(refused.message.contains("edit"),
                      "the refusal does not say what was asked for: \(refused.message)")
    }

    func testSomethingThatIsNotAPostRollLinkIsRefusedRatherThanRead() throws {
        // LaunchServices only ever hands over the scheme the bundle declares,
        // so this cannot arrive that way. It is here because every other caller
        // of this parser can pass anything, and reading an arbitrary URL as a
        // new event is how a link nobody wrote turns into an event.
        let refused = try refusal("https://example.com/new?name=Show")

        XCTAssertEqual(refused, .notOurScheme("https"))
    }

    func testALinkWithNoActionAtAllIsRefused() throws {
        let refused = try refusal("postroll://")

        XCTAssertEqual(refused, .noAction)
    }

    func testAnUnsubstitutedPlaceholderIsRefusedRatherThanStored() throws {
        // The note is a template. A misspelled placeholder in Downbeat comes
        // through as its own source text, and "<<photoshootName>>" is a value
        // that would otherwise reach a folder name and a caption looking like a
        // title somebody chose (L192).
        let refused = try refusal(
            "postroll://new?name=%3C%3CphotoshootName%3E%3E&date=20260822"
            + "&booking=\(booking.uuidString)")

        XCTAssertEqual(refused, .unsubstitutedToken(field: "name", value: "<<photoshootName>>"))
        XCTAssertTrue(refused.message.contains("<<photoshootName>>"),
                      "the refusal does not quote what it found: \(refused.message)")
    }

    func testAPlaceholderInAnOptionalFieldIsRefusedToo() throws {
        // An optional field is allowed to be EMPTY. It is not allowed to be a
        // placeholder: empty says Downbeat had nothing, a placeholder says
        // Downbeat had something and the template failed to put it there. The
        // second must not be stored as though it were the first (L214).
        let refused = try refusal(
            "postroll://new?name=Show&venue=%3C%3CvenueName%3E%3E&date=20260822"
            + "&booking=\(booking.uuidString)")

        XCTAssertEqual(refused, .unsubstitutedToken(field: "venue", value: "<<venueName>>"))
    }

    func testADateThatIsNotEightDigitsIsRefused() throws {
        let refused = try refusal(
            "postroll://new?name=Show&date=22%20August%202026&booking=\(booking.uuidString)")

        XCTAssertEqual(refused, .unreadableDate("22 August 2026"))
    }

    func testADayThatDoesNotExistIsRefusedRatherThanRolledForward() throws {
        // `Calendar.date(from:)` happily turns the 31st of February into the
        // 3rd of March. A link for a day that is not a day is a link that is
        // wrong, and silently moving it produces a shoot date nobody typed.
        let refused = try refusal(
            "postroll://new?name=Show&date=20260231&booking=\(booking.uuidString)")

        XCTAssertEqual(refused, .unreadableDate("20260231"))
    }

    func testALinkWithNoDateIsRefusedRatherThanDatedToday() throws {
        // Defaulting to today would invent the one fact the whole posting week
        // is built from, and it would look exactly like a date somebody chose
        // (L67).
        let refused = try refusal(
            "postroll://new?name=Show&booking=\(booking.uuidString)")

        XCTAssertEqual(refused, .missing(field: "date"))
    }

    func testALinkWithNoBookingIdIsRefused() throws {
        // Without it there is nothing to match a second click against, so the
        // three clicks a three night run produces would make three events on
        // the first night and three more on the second.
        let refused = try refusal("postroll://new?name=Show&date=20260822")

        XCTAssertEqual(refused, .missing(field: "booking"))
    }

    func testABookingIdThatIsNotAnIdIsRefused() throws {
        let refused = try refusal(
            "postroll://new?name=Show&date=20260822&booking=not-a-uuid")

        XCTAssertEqual(refused, .unreadableBooking("not-a-uuid"))
    }

    func testEveryRefusalSaysSomethingDifferent() {
        // A distinct cause with a shared sentence is a cause nobody can act on
        // (L11). Written as a set so a copy-pasted message is caught rather
        // than reviewed for.
        let refusals: [DeepLink.Refusal] = [
            .noAction,
            .unknownAction("edit"),
            .unsubstitutedToken(field: "name", value: "<<x>>"),
            .missing(field: "date"),
            .unreadableDate("nonsense"),
            .unreadableBooking("nonsense"),
        ]
        let messages = Set(refusals.map(\.message))

        XCTAssertEqual(messages.count, refusals.count,
                       "two refusals share a sentence: \(refusals.map(\.message))")
        for message in messages {
            XCTAssertFalse(message.isEmpty, "a refusal with nothing to say")
        }
    }
}
