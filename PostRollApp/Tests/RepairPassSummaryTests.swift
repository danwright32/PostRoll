import XCTest

/// #1138: an empty findings panel gets its own signal that the pass RAN.
///
/// With repairs silent, empty is the normal state, and it would otherwise be
/// produced identically by a genuinely clean post, a pass that threw before its
/// loop, a pass whose tail never ran, `check_blog` itself breaking, and the
/// process being killed at its deadline mid-pass. Five things, one appearance,
/// on the surface Dan actually reads.
final class RepairPassSummaryTests: XCTestCase {

    func testAPostNothingHasCheckedDoesNotClaimToBeClean() {
        let note = RepairPassSummary(ran: false).note
        XCTAssertNotNil(note)
        XCTAssertFalse(note!.lowercased().contains("nothing outstanding"),
                       "a post nothing checked reads as a clean one: \(note!)")
    }

    func testACheckedAndCleanPostSaysSo() {
        let note = RepairPassSummary(ran: true, selected: 0, attempted: 0).note
        XCTAssertEqual(note, "Checked, nothing outstanding.")
    }

    func testAPassThatRanOutOfTimeIsItsOwnAnswer() {
        // Distinct from both "did not run" and "ran and finished": the post was
        // partly looked at, and running again would finish it.
        let early = RepairPassSummary(ran: true, selected: 7, attempted: 3,
                                      endedEarly: true).note
        XCTAssertNotEqual(early, RepairPassSummary(ran: false).note)
        XCTAssertNotEqual(early, RepairPassSummary(ran: true).note)
        XCTAssertTrue(early!.lowercased().contains("again"), early!)
    }

    func testThePassSaysWhenItActuallyRewroteSomething() {
        let note = RepairPassSummary(ran: true, selected: 3, attempted: 3).note
        XCTAssertNotEqual(note, "Checked, nothing outstanding.")
    }

    func testEveryOutcomeReadsDifferently() {
        let notes = [
            RepairPassSummary(ran: false).note,
            RepairPassSummary(ran: true).note,
            RepairPassSummary(ran: true, selected: 2, attempted: 2).note,
            RepairPassSummary(ran: true, endedEarly: true).note,
        ]
        XCTAssertEqual(Set(notes.compactMap { $0 }).count, notes.count,
                       "two outcomes read identically: \(notes)")
    }

    func testAPayloadWithNoRepairPassKeyDecodesToNotRun() throws {
        // Every post written before the pass existed. It must never claim a
        // pass happened.
        let json = Data("""
        {"title": "t", "body": "b"}
        """.utf8)

        let blog = try JSONDecoder().decode(BlogOutput.self, from: json)

        XCTAssertFalse(blog.repairPass.ran)
        XCTAssertEqual(blog.repairPass.note,
                       RepairPassSummary(ran: false).note)
    }

    func testTheSummaryRoundTrips() throws {
        var blog = BlogOutput(title: "t", body: "b")
        blog.repairPass = RepairPassSummary(ran: true, selected: 4,
                                            attempted: 2, endedEarly: true)

        let again = try JSONDecoder().decode(
            BlogOutput.self, from: JSONEncoder().encode(blog))

        XCTAssertEqual(again.repairPass, blog.repairPass)
    }
}
