import XCTest

/// The event the New Event sheet's Create button makes (#840).
///
/// Pulled out of the sheet so it can be driven at all: the sheet is a view, and
/// the one thing that matters about pressing Create is what lands in the store.
/// It is also the only place the single-line folding rule for these five fields
/// is spelled, so a second caller cannot spell it differently (#688).
final class NewEventFormTests: XCTestCase {

    private let booking = UUID(uuidString: "6E5F3B9A-1C2D-4E5F-8A9B-0C1D2E3F4A5B")!

    func testTheBookingIdFromALinkIsKept() {
        // Without it, the next click on the same link makes a second event.
        let made = NewEventForm.event(name: "Brahms Requiem", org: "", venue: "",
                                      venueContext: "", date: Date(timeIntervalSince1970: 0),
                                      shootType: .fullShow, bookingID: booking)

        XCTAssertEqual(made.downbeatBookingID, booking)
    }

    func testAnEventTypedByHandCarriesNoBookingId() {
        let made = NewEventForm.event(name: "Typed by hand", org: "", venue: "",
                                      venueContext: "", date: Date(timeIntervalSince1970: 0),
                                      shootType: .fullShow, bookingID: nil)

        XCTAssertNil(made.downbeatBookingID)
    }

    func testEveryTextFieldIsFoldedToOneLine() {
        // #688: these reach folder names, captions and the handle book's keys,
        // and a break in the middle of one renders as a space that nothing on
        // screen says is really a newline.
        let made = NewEventForm.event(name: "Symphony\nNo. 5", org: " Oratorio  Society ",
                                      venue: "Carnegie\nHall", venueContext: "Stern\nAuditorium",
                                      date: Date(timeIntervalSince1970: 0),
                                      shootType: .fullShow, bookingID: nil)

        XCTAssertEqual(made.name, "Symphony No. 5")
        XCTAssertEqual(made.org, "Oratorio Society")
        XCTAssertEqual(made.venue, "Carnegie Hall")
        XCTAssertEqual(made.venueContext, "Stern Auditorium")
    }

    func testTheDateAndShootTypeAreKeptAsGiven() {
        let when = Date(timeIntervalSince1970: 1_777_000_000)
        let made = NewEventForm.event(name: "Show", org: "", venue: "", venueContext: "",
                                      date: when, shootType: .photoCall, bookingID: nil)

        XCTAssertEqual(made.date, when)
        XCTAssertEqual(made.shootType, .photoCall)
    }
}
