import XCTest

/// What the window does with a link (#840).
///
/// The parser and the matcher are pure and covered elsewhere. This is the half
/// that can be perfect while nothing happens on screen: a draft that reaches no
/// sheet, a match that selects nothing, a refusal nobody is told about.
///
/// Driven against a temp data root so nothing here can reach Dan's real store
/// (L2).
@MainActor
final class DeepLinkRoutingTests: XCTestCase {

    private var root: URL!
    private var store: URL!

    private let nightOne = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepLinkRouting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = root.appendingPathComponent("events.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func state(_ events: [Event] = []) -> AppState {
        AppState(events: events, storeURL: store, dataRoot: root)
    }

    private func link(booking: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                      date: String = "20260822") -> URL {
        URL(string: "postroll://new?name=Brahms%20Requiem&org=Oratorio%20Society"
            + "&venue=Carnegie%20Hall&room=Stern%20Auditorium"
            + "&date=\(date)&booking=\(booking.uuidString)")!
    }

    private func event(_ name: String, booking: UUID?) -> Event {
        var made = Event(name: name, org: "", venue: "",
                         date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        made.downbeatBookingID = booking
        return made
    }

    // MARK: - The first click

    func testAGoodLinkOpensTheSheetAlreadyFilled() {
        let app = state()

        app.handle(link(), calendar: calendar)

        XCTAssertTrue(app.showingNewEvent, "the link filled a form nothing put on screen")
        let prefill = app.newEventPrefill
        XCTAssertEqual(prefill?.name, "Brahms Requiem")
        XCTAssertEqual(prefill?.org, "Oratorio Society")
        XCTAssertEqual(prefill?.venue, "Carnegie Hall")
        XCTAssertEqual(prefill?.venueContext, "Stern Auditorium")
        XCTAssertEqual(prefill?.bookingID, nightOne)
    }

    func testAClickWritesNothing() {
        // The sheet IS the review step. A link that created an event outright
        // would put a stale or wrong one into the store before anybody read it.
        let app = state()

        app.handle(link(), calendar: calendar)

        XCTAssertTrue(app.events.isEmpty, "the link created an event without being reviewed")
        XCTAssertNil(app.selectedEventID)
    }

    // MARK: - The second click

    func testASecondClickSelectsTheEventAndSaysSo() {
        let already = event("Brahms Requiem", booking: nightOne)
        let app = state([already])

        app.handle(link(), calendar: calendar)

        XCTAssertEqual(app.selectedEventID, already.id)
        XCTAssertFalse(app.showingNewEvent, "a second click offered a second sheet")
        XCTAssertEqual(app.deepLinkNotice?.kind, .handled)
        XCTAssertEqual(app.deepLinkNotice?.message, DeepLink.alreadyCreatedMessage(for: already))
    }

    func testASecondClickLeavesNoPrefillBehind() {
        // A prefill left set is a Cmd+N later that opens somebody else's event.
        let already = event("Brahms Requiem", booking: nightOne)
        let app = state([already])

        app.handle(link(), calendar: calendar)

        XCTAssertNil(app.newEventPrefill)
    }

    // MARK: - A link that says nothing usable

    func testARefusedLinkIsReportedRatherThanSwallowed() {
        let app = state()

        app.handle(URL(string: "postroll://new?name=Show&date=nonsense"
                       + "&booking=\(nightOne.uuidString)")!, calendar: calendar)

        XCTAssertEqual(app.deepLinkNotice?.kind, .refused)
        XCTAssertEqual(app.deepLinkNotice?.message,
                       DeepLink.Refusal.unreadableDate("nonsense").message)
        XCTAssertFalse(app.showingNewEvent, "a link that reads as nothing still opened a form")
        XCTAssertNil(app.newEventPrefill)
    }

    func testANoticeCanBeWavedAway() {
        let app = state()
        app.handle(URL(string: "postroll://new?name=Show&date=nonsense"
                       + "&booking=\(nightOne.uuidString)")!, calendar: calendar)

        app.dismissDeepLinkNotice()

        XCTAssertNil(app.deepLinkNotice)
    }

    func testAGoodClickClearsAnEarlierRefusal() {
        // Otherwise the sentence about the broken link stays under a sheet that
        // opened perfectly, and reads as being about that one.
        let app = state()
        app.handle(URL(string: "postroll://new?name=Show&date=nonsense"
                       + "&booking=\(nightOne.uuidString)")!, calendar: calendar)

        app.handle(link(), calendar: calendar)

        XCTAssertNil(app.deepLinkNotice)
    }

    // MARK: - Which copy answered

    func testALinkAnsweredByABuildProductSaysSo() {
        // Four PostRoll.app bundles exist on this Mac and macOS picks which one
        // answers. A Debug build reads its own events store, so an event
        // created here is simply not in the app Dan normally opens, and without
        // this nothing anywhere says why.
        let app = state()
        let debug = URL(fileURLWithPath:
            "/Users/dan/Library/Developer/PostRoll/Build/Products/Debug/PostRoll.app")

        app.handle(link(), calendar: calendar, answeredBy: debug)

        XCTAssertEqual(app.answeringCopyNotice,
                       AnsweringCopy.notice(answeredBy: debug))
    }

    func testTheInstalledCopyAnsweringSaysNothingAboutItself() {
        let app = state()

        app.handle(link(), calendar: calendar,
                   answeredBy: URL(fileURLWithPath: AnsweringCopy.installedPath))

        XCTAssertNil(app.answeringCopyNotice)
    }

    func testTheWrongCopyIsReportedEvenWhenTheLinkWorkedPerfectly() {
        // The sheet opening is not evidence the right app opened it. Tying this
        // to a refusal would leave the everyday case, a link that works, the
        // one case that never warns (L142).
        let app = state()
        let debug = URL(fileURLWithPath:
            "/Users/dan/Library/Developer/PostRoll/Build/Products/Debug/PostRoll.app")

        app.handle(link(), calendar: calendar, answeredBy: debug)

        XCTAssertTrue(app.showingNewEvent)
        XCTAssertNotNil(app.answeringCopyNotice)
    }

    func testTheCopyNoticeCanBeWavedAway() {
        let app = state()
        app.handle(link(), calendar: calendar, answeredBy: URL(fileURLWithPath: "/tmp/PostRoll.app"))

        app.dismissAnsweringCopyNotice()

        XCTAssertNil(app.answeringCopyNotice)
    }

    // MARK: - The prefill must not outlive the click

    func testANewEventTypedByHandAfterAClickIsBlank() {
        // Cmd+N and the two buttons all go through one call that clears the
        // prefill, rather than depending on a dismissal handler having fired.
        let app = state()
        app.handle(link(), calendar: calendar)

        app.presentNewEvent()

        XCTAssertTrue(app.showingNewEvent)
        XCTAssertNil(app.newEventPrefill,
                     "typing a new event by hand reopened the last link's values")
    }
}
