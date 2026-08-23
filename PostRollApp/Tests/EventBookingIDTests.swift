import XCTest

/// The Downbeat booking id lives on the event, and every event already in the
/// store carries none (#840).
///
/// `Event` decodes by hand, field by field, so a new field is only
/// backward-compatible if somebody wrote `decodeIfPresent` for it. Getting that
/// wrong does not fail a build: it throws at load time on Dan's real store, and
/// the app comes up with no events at all.
final class EventBookingIDTests: XCTestCase {

    private let booking = UUID(uuidString: "6E5F3B9A-1C2D-4E5F-8A9B-0C1D2E3F4A5B")!

    private func roundTrip(_ event: Event) throws -> Event {
        let data = try JSONEncoder().encode(event)
        return try JSONDecoder().decode(Event.self, from: data)
    }

    func testAnEventStoredBeforeThisShippedStillLoads() throws {
        // The whole store as it is today: no such key anywhere in it.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Brahms Requiem",
          "org": "Oratorio Society",
          "venue": "Carnegie Hall",
          "date": 774_000_000,
          "shootType": "Performance"
        }
        """.replacingOccurrences(of: "_", with: "")

        let decoded = try JSONDecoder().decode(Event.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.name, "Brahms Requiem")
        XCTAssertNil(decoded.downbeatBookingID,
                     "an event made before links existed reports a booking id it never had")
    }

    func testABookingIdSurvivesBeingSavedAndLoaded() throws {
        // It is the key a second click matches on, so an id that is written and
        // not read back makes every click after the first a duplicate event
        // (L186).
        var event = Event(name: "Brahms Requiem", org: "Oratorio Society",
                          venue: "Carnegie Hall", date: Date(timeIntervalSince1970: 0),
                          shootType: .fullShow)
        event.downbeatBookingID = booking

        XCTAssertEqual(try roundTrip(event).downbeatBookingID, booking)
    }

    func testAnEventWithNoBookingIdRoundTripsAsHavingNone() throws {
        let event = Event(name: "Typed by hand", org: "", venue: "",
                          date: Date(timeIntervalSince1970: 0), shootType: .fullShow)

        XCTAssertNil(try roundTrip(event).downbeatBookingID)
    }
}
