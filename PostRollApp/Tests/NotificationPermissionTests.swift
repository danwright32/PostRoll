import XCTest

/// The answer to "may I notify" is kept, and says what it costs (#879).
///
/// It used to be discarded at the callback, so a refusal and a working app
/// produced the same evidence: none. What that looks like from outside is a
/// person watching for a banner that can never arrive, which is exactly what
/// step 3 of the hand check asks somebody to do.
final class NotificationPermissionTests: XCTestCase {

    func testGrantedHasNothingToComplainAbout() {
        let outcome = NotificationPermission.outcome(granted: true, error: nil)

        XCTAssertEqual(outcome, .granted)
        XCTAssertNil(outcome.complaint, "a working app is complaining about itself")
        XCTAssertTrue(outcome.canNotify)
    }

    func testBeingToldNoSaysWhatIsNowSilent() throws {
        let outcome = NotificationPermission.outcome(granted: false, error: nil)

        XCTAssertEqual(outcome, .refused)
        let complaint = try XCTUnwrap(outcome.complaint)
        XCTAssertTrue(complaint.contains("every failed run"),
                      "the refusal does not say what stops arriving: \(complaint)")
        XCTAssertTrue(complaint.contains("System Settings"),
                      "the refusal does not say where it is fixed: \(complaint)")
        XCTAssertFalse(outcome.canNotify)
    }

    func testAFailedRequestIsNotARefusal() throws {
        // They are different situations with different remedies, and the
        // failing one can still report granted == false. Reading that as a
        // refusal sends somebody to a System Settings switch that is not the
        // problem (L11).
        let error = NSError(domain: "test", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "no bundle proxy"])
        let outcome = NotificationPermission.outcome(granted: false, error: error)

        XCTAssertEqual(outcome, .failed("no bundle proxy"))
        let complaint = try XCTUnwrap(outcome.complaint)
        XCTAssertTrue(complaint.contains("no bundle proxy"),
                      "the reason the request failed is not in what is said: \(complaint)")
        XCTAssertTrue(complaint.contains("System Settings"),
                      "nothing says this is not a switch somebody can find: \(complaint)")
        XCTAssertFalse(outcome.canNotify)
    }

    func testNotAskedIsItsOwnState() {
        // The state at launch. Never a verdict, and it must not read as one:
        // an app that has not asked yet and an app that was told no are
        // different, and only one of them is the person's to fix.
        let outcome = NotificationPermission.notAsked

        XCTAssertNotEqual(outcome, .refused)
        XCTAssertFalse(outcome.canNotify)
        XCTAssertNotNil(outcome.complaint)
    }
}
