import XCTest

/// What a click on a `postroll://` link actually lands on (#840).
///
/// Parsing is one question and this is another: given a link that reads fine,
/// does it open a fresh sheet or point at the event it already made? A three
/// night run emits three links carrying three ids, so the answer has to be per
/// link rather than per show, and a second click on the SAME link must never be
/// a second event.
final class DeepLinkLandingTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private let nightOne = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let nightTwo = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func link(booking: UUID, name: String = "Brahms%20Requiem", date: String = "20260822") -> URL {
        URL(string: "postroll://new?name=\(name)&date=\(date)&booking=\(booking.uuidString)")!
    }

    private func event(_ name: String, booking: UUID?) -> Event {
        var made = Event(name: name, org: "Oratorio Society", venue: "Carnegie Hall",
                         date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        made.downbeatBookingID = booking
        return made
    }

    private func landing(_ url: URL, existing: [Event]) -> DeepLink.Landing {
        DeepLink.landing(for: url, existing: existing, calendar: calendar)
    }

    // MARK: - The first click

    func testALinkNothingHasBeenMadeFromOpensASheet() {
        switch landing(link(booking: nightOne), existing: []) {
        case .newEvent(let draft):
            XCTAssertEqual(draft.bookingID, nightOne)
            XCTAssertEqual(draft.name, "Brahms Requiem")
        default:
            XCTFail("a link nothing has been made from did not offer to make one")
        }
    }

    // MARK: - The second click on the same link

    func testASecondClickSelectsTheEventItAlreadyMade() {
        let already = event("Brahms Requiem", booking: nightOne)

        switch landing(link(booking: nightOne), existing: [already]) {
        case .alreadyCreated(let id, _):
            XCTAssertEqual(id, already.id)
        default:
            XCTFail("clicking the same link twice offered to make the event a second time")
        }
    }

    func testTheSecondClickSaysWhyThereIsNoSheet() {
        // A click that silently selects something is a click that looks like it
        // did nothing when the event was already the one on screen. The window
        // has to say what happened, and name the event it is talking about
        // (L80, L152).
        let already = event("Brahms Requiem", booking: nightOne)

        switch landing(link(booking: nightOne), existing: [already]) {
        case .alreadyCreated(_, let message):
            XCTAssertTrue(message.contains("Brahms Requiem"),
                          "the notice does not name the event it selected: \(message)")
            XCTAssertFalse(message.isEmpty)
        default:
            XCTFail("clicking the same link twice offered to make the event a second time")
        }
    }

    // MARK: - The other nights of the same run

    func testAnotherNightsLinkIsItsOwnEvent() {
        // The booking id is per SHOW, not per booking, so a three night run
        // produces three links and has to produce three events. Matching on
        // anything coarser (the org, the venue, the run) would swallow nights
        // two and three into night one.
        let already = event("Brahms Requiem", booking: nightOne)

        switch landing(link(booking: nightTwo), existing: [already]) {
        case .newEvent(let draft):
            XCTAssertEqual(draft.bookingID, nightTwo)
        default:
            XCTFail("the second night of a run was folded into the first")
        }
    }

    // MARK: - Everything created before this shipped

    func testAnEventWithNoBookingIdIsNeverTheMatch() {
        // Every event in the store today has no booking id. If a missing id
        // matched a missing id, the first click of the first link would select
        // whatever happened to be first in the list instead of opening a sheet,
        // and it would look exactly like the feature working (L214).
        let old = event("Brahms Requiem", booking: nil)
        let older = event("Something else", booking: nil)

        switch landing(link(booking: nightOne), existing: [old, older]) {
        case .newEvent(let draft):
            XCTAssertEqual(draft.bookingID, nightOne)
        default:
            XCTFail("an event carrying no booking id was matched against one that does")
        }
    }

    // MARK: - A link that reads as nothing

    func testARefusedLinkLandsOnItsOwnRefusal() {
        // Not silence. A link that opened nothing and said nothing is
        // indistinguishable from a link that opened something off screen
        // (L10, L11).
        let url = URL(string: "postroll://new?name=Show&date=nonsense&booking=\(nightOne.uuidString)")!

        switch landing(url, existing: []) {
        case .refused(let message):
            XCTAssertEqual(message, DeepLink.Refusal.unreadableDate("nonsense").message)
        default:
            XCTFail("an unreadable date was let through")
        }
    }
}
