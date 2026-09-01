import XCTest

/// #1132: five outcomes, five renderings, no two alike.
///
/// Dan's rule 1 makes repairs SILENT, so nothing on the panel says a repair
/// happened. Rule 2 says a repair that was TRIED and failed still shows, marked
/// as tried. Collapsing any of the five back into "never attempted" is rule 2
/// defeated, because never-attempted renders exactly like today's findings,
/// which is the one thing rule 2 forbids.
final class RepairStateDisplayTests: XCTestCase {

    private func finding(_ code: String, _ detail: String,
                         repair: String = "") -> QualityFinding {
        QualityFinding(code: code, message: "Alt text must be 15 to 25 words.",
                       detail: detail, repair: repair)
    }

    // MARK: - The grouping

    func testATriedFindingAndAnUntriedOneOfTheSameCodeAreTwoRows() {
        // The whole point. Merged under one heading, Dan is told nothing about
        // which the app already failed on and which it never touched.
        let groups = FindingsDisplay.grouped(findings: [
            finding("alt_text_length", "a.jpg: 9 words"),
            finding("alt_text_length", "b.jpg: 30 words", repair: "tried"),
        ])

        XCTAssertEqual(groups.count, 2, "the two states merged into one heading")
        XCTAssertEqual(Set(groups.map(\.repair)), ["", "tried"])
    }

    func testTwoRowsOfOneCodeDoNotShareAnIdentity() {
        // SwiftUI silently renders ONE of any pair sharing an id, so a grouping
        // fixed without this is rule 2 defeated at the render step, one line
        // past where the fix was made.
        let groups = FindingsDisplay.grouped(findings: [
            finding("alt_text_length", "a.jpg: 9 words"),
            finding("alt_text_length", "b.jpg: 30 words", repair: "tried"),
        ])

        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count,
                       "two groups share an id, so the panel draws one of them")
    }

    func testFindingsOfOneCodeInOneStateStillCollapseIntoOneRow() {
        // The control. Seven over-long alt texts are one problem to work
        // through, not seven alarms, and that must survive the re-keying.
        let groups = FindingsDisplay.grouped(findings: [
            finding("alt_text_length", "a.jpg: 9 words"),
            finding("alt_text_length", "b.jpg: 30 words"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].details.count, 2)
    }

    func testTheFiveStatesRenderAsFiveDistinctRows() {
        let groups = FindingsDisplay.grouped(findings: RepairState.allCases.map {
            finding("alt_text_length", "a.jpg", repair: $0.rawValue)
        })

        XCTAssertEqual(groups.count, 5)
        XCTAssertEqual(Set(groups.map(\.id)).count, 5)
    }

    // MARK: - The wording

    func testEveryStateThatHappenedSaysSomethingDistinct() {
        let happened = RepairState.allCases.filter { $0 != .never }
        XCTAssertEqual(Set(happened.map(\.note)).count, happened.count)
        XCTAssertEqual(Set(happened.map(\.headingSuffix)).count, happened.count)
        XCTAssertEqual(Set(happened.map(\.icon)).count, happened.count,
                       "two states share an icon, so they read as one at a glance")
    }

    func testBlockedInvitesTryingAgainAndTriedDoesNot() {
        // The test for whether two states are one is whether they invite
        // different actions (L11, L260). For a network blip, `tried`'s claim
        // that re-running will not help is simply false.
        XCTAssertTrue(RepairState.blocked.note.lowercased().contains("again"))
        XCTAssertFalse(RepairState.tried.note.lowercased().contains("again"))
    }

    func testNeverAttemptedSaysNothingAtAll() {
        // So a post written before the pass existed renders exactly as today.
        XCTAssertEqual(RepairState.never.note, "")
        XCTAssertEqual(RepairState.never.headingSuffix, "")
    }

    // MARK: - Decoding

    func testAPayloadWithNoRepairKeyDecodesToNeverAttempted() throws {
        // Everything already saved. Nothing on screen changes appearance.
        let json = Data("""
        {"code": "alt_text_length", "message": "m", "detail": "d"}
        """.utf8)

        let decoded = try JSONDecoder().decode(QualityFinding.self, from: json)

        XCTAssertEqual(decoded.repair, "")
        XCTAssertEqual(FindingsDisplay.grouped(findings: [decoded]).first?.state,
                       .never)
    }

    func testAStateThisAppDoesNotKnowRendersAsNeverRatherThanFailing() {
        // A state added on the Python side arrives as an unknown string. Wrong
        // but not broken beats refusing to decode the whole post.
        XCTAssertEqual(RepairState(raw: "something_new"), .never)
    }

    func testTheRepairStateIsPartOfAFindingsIdentity() {
        // `id` feeds ForEach directly.
        let untried = finding("alt_text_length", "a.jpg")
        let tried = finding("alt_text_length", "a.jpg", repair: "tried")

        XCTAssertNotEqual(untried.id, tried.id)
    }
}

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
