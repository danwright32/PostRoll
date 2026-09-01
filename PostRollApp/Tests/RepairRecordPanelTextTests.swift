import XCTest

/// #1162: what the panel SAYS about what the app changed.
///
/// The wording is tested here rather than through the SwiftUI tree, because
/// what matters is the claim each state makes. The three states exist to be
/// told apart (L10, L11), and the one that must never be mistaken for another
/// is "the record could not be read", which is about the FILE, against
/// "nothing was recorded", which is about the POST.
final class RepairRecordPanelTextTests: XCTestCase {

    private func record(marker: String, before: String?, after: String?,
                        outcome: String = "repaired",
                        kind: RepairJournal.Record.Kind = .attempt)
    -> RepairJournal.Record {
        RepairJournal.Record(kind: kind, at: nil, marker: marker,
                             outcome: outcome, before: before, after: after,
                             reason: nil)
    }

    // --- the three states say different things ------------------------------

    func testNothingRecordedDoesNotClaimNothingWasChanged() {
        let text = RepairRecordPanelText.summary(for: .nothingRecorded)

        XCTAssertFalse(
            text.lowercased().contains("no changes were made"),
            "the panel claimed the app changed nothing, which the journal "
            + "cannot support: a post generated before it existed leaves no "
            + "trace in it (L98)")
        XCTAssertTrue(text.lowercased().contains("recorded"),
                      "the empty state must say what is absent (a record), not "
                      + "assert what happened: \(text)")
    }

    func testAnUnreadableJournalSaysTheEvidenceIsMissing() {
        // The reason shares NO wording with what this state must say on its
        // own. The first version of this test passed the reason "the file is
        // there and could not be opened" and then asserted the message
        // contained "could not be", which the reason itself supplied: the
        // assertion was answered by the fixture rather than by the code, and
        // the guard prover proved it by SURVIVING a mutation that replaced the
        // whole sentence with the empty state's (L156, L178).
        let why = "permission denied on the folder"
        let text = RepairRecordPanelText.summary(for: .unreadable(why))

        XCTAssertNotEqual(
            text, RepairRecordPanelText.summary(for: .nothingRecorded),
            "an unreadable journal reads exactly like an empty one, so a "
            + "missing record is shown as proof that nothing happened")
        XCTAssertFalse(
            text.contains("Nothing recorded"),
            "the unreadable state borrows the empty state's wording, so a "
            + "record that is there and cannot be read tells Dan the app "
            + "changed nothing: \(text)")
        XCTAssertTrue(
            text.replacingOccurrences(of: why, with: "").contains("could not be read"),
            "with the reason removed the message no longer says the read "
            + "failed, so the only thing naming the fault is text the caller "
            + "happened to supply: \(text)")
    }

    func testTheSummaryCountsWhatIsActuallyThere() {
        let text = RepairRecordPanelText.summary(for: .records([
            record(marker: "a.jpg", before: "was a", after: "now a"),
            record(marker: "b.jpg", before: "was b", after: "now b"),
        ]))

        // "2 things", not "2". A bare digit is also carried by a marker name
        // like p2.jpg, so if the summary ever listed markers the assertion
        // would be answered by one of those rather than by the count. Same
        // weakness the guard prover found in the unreadable state's test
        // (L156), caught here by sweeping for it rather than waiting.
        XCTAssertTrue(text.contains("2 things"),
                      "the summary does not say how many records it is "
                      + "showing: \(text)")
        XCTAssertNotEqual(
            text,
            RepairRecordPanelText.summary(for: .records([
                record(marker: "a.jpg", before: "was a", after: "now a")])),
            "one record and two records read identically, so the count is "
            + "not being derived from what is actually there")
    }

    // --- one record, in Dan's language --------------------------------------

    func testARepairedMarkerShowsBothTheOldAndTheNewText() {
        let lines = RepairRecordPanelText.lines(
            for: record(marker: "p2.jpg", before: "A male performer sings",
                        after: "Kate DiGangi sings at the piano"))

        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("A male performer sings"),
                      "the old alt text is not shown, so there is no before to "
                      + "compare the after against: \(joined)")
        XCTAssertTrue(joined.contains("Kate DiGangi sings at the piano"),
                      "the new alt text is not shown: \(joined)")
        XCTAssertTrue(joined.contains("p2.jpg"),
                      "the record does not name which photograph it is about")
    }

    func testARefusedRewriteSaysTheTextIsUnchanged() {
        // The app tried and its own damage gate refused the result. Showing an
        // empty "now" would read as the alt text having been blanked.
        let lines = RepairRecordPanelText.lines(
            for: record(marker: "p2.jpg", before: "the original", after: nil,
                        outcome: "tried"))

        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains(RepairJournal.refusedWording),
                      "a refused rewrite is not named as one: \(joined)")
    }

    func testAPhotographLeftWhereItWasIsItsOwnStatement() {
        // #1172: a photograph the app MOVED and one it looked at and left alone
        // are different facts, and the second is the one with no other record.
        let moved = RepairRecordPanelText.lines(
            for: record(marker: "p1.jpg", before: nil, after: nil,
                        outcome: "moved", kind: .moved)).joined(separator: "\n")
        let left = RepairRecordPanelText.lines(
            for: record(marker: "p1.jpg", before: nil, after: nil,
                        outcome: "left where it was", kind: .moved))
            .joined(separator: "\n")

        XCTAssertNotEqual(moved, left,
                          "a photograph that was moved and one that was "
                          + "deliberately left alone read identically")
    }

    func testNoLineIsEmptyOrDanglingWhenAFieldIsAbsent() {
        // A record whose `before` never made it to disk must not render a
        // labelled line with nothing after it, which reads as an empty alt text
        // rather than as a missing record.
        let lines = RepairRecordPanelText.lines(
            for: record(marker: "p3.jpg", before: nil, after: "now"))

        for line in lines {
            XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).isEmpty,
                           "the panel renders a blank line for an absent field")
            XCTAssertFalse(line.hasSuffix(":"),
                           "a label with nothing after it reads as an empty "
                           + "value rather than an absent one: \(line)")
        }
    }
}
