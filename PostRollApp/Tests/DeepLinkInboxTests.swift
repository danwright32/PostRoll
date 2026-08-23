import XCTest

/// A link clicked while PostRoll is NOT running must survive until there is a
/// window to put it in (#840).
///
/// macOS delivers the URL to the application, and the application is alive
/// before its first scene is. Whichever order those two happen in on a given
/// launch is not something this side chooses, so the link is buffered rather
/// than handled where it lands. Without the buffer, a cold launch is the case
/// that silently drops the click, and it is also the commonest case: Dan clicks
/// the task note, PostRoll is not open.
@MainActor
final class DeepLinkInboxTests: XCTestCase {

    private let first = URL(string: "postroll://new?name=One&date=20260822"
                            + "&booking=11111111-1111-4111-8111-111111111111")!
    private let second = URL(string: "postroll://new?name=Two&date=20260823"
                             + "&booking=22222222-2222-4222-8222-222222222222")!

    func testALinkThatArrivedBeforeAnybodyLookedIsStillThere() {
        let inbox = DeepLinkInbox()
        inbox.receive(first)

        XCTAssertEqual(inbox.drain(), [first],
                       "the link delivered before the window existed was dropped")
    }

    func testDrainingTwiceDoesNotHandTheSameLinkOverTwice() {
        // A second window, or a second appearance of the same one, would
        // otherwise re-open a sheet Dan already cancelled.
        let inbox = DeepLinkInbox()
        inbox.receive(first)

        _ = inbox.drain()

        XCTAssertEqual(inbox.drain(), [], "the same link was handed over twice")
    }

    func testLinksAreHandedOverInTheOrderTheyArrived() {
        let inbox = DeepLinkInbox()
        inbox.receive(first)
        inbox.receive(second)

        XCTAssertEqual(inbox.drain(), [first, second])
    }

    func testALinkArrivingAfterADrainIsStillDelivered() {
        // The warm case: the app is already open and Dan clicks the note.
        let inbox = DeepLinkInbox()
        inbox.receive(first)
        _ = inbox.drain()

        inbox.receive(second)

        XCTAssertEqual(inbox.drain(), [second])
    }
}
