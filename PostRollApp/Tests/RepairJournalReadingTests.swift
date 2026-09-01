import XCTest

/// #1162: the app can show what it changed in a post, not only a terminal.
///
/// Repairs are silent by design, so `blog-repairs.jsonl` is the only record
/// that the app rewrote anything. Reading it meant running
/// `tools/read_repair_log.py`, and Dan does not work in a terminal, so in
/// practice that evidence did not exist for him: a field with a writer and no
/// reader is not evidence (L46), and a reader he will not use is the same thing.
///
/// The three answers are kept apart on purpose (L10, L11). "Nothing was
/// recorded" and "the record is there and could not be read" are different
/// facts, and the second must never be shown as the first: it would tell him
/// the app changed nothing in a post where it may have changed a great deal.
final class RepairJournalReadingTests: XCTestCase {

    private var dir: URL!
    private var journal: URL!
    private let mine = UUID()
    private let other = UUID()

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repair-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        journal = dir.appendingPathComponent("blog-repairs.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ records: [[String: Any]]) throws {
        let lines = try records.map {
            String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: journal, atomically: true, encoding: .utf8)
    }

    private func attempt(event: UUID, marker: String, before: String,
                         after: String?, outcome: String = "repaired",
                         venue: String = "The Green Room 42") -> [String: Any] {
        var record: [String: Any] = [
            "at": "2026-09-01T12:00:00+00:00",
            "script": "generate_blog",
            "event": venue,
            "event_id": event.uuidString,
            "kind": "attempt",
            "target": marker,
            "marker": marker,
            "codes": ["alt_text_names_a_performer"],
            "before": before,
            "outcome": outcome,
            "reason": "",
        ]
        record["after"] = after as Any? ?? NSNull()
        return record
    }

    // --- the defect that made the keying change necessary -------------------

    func testOnlyThisPostsRepairsAreShown() throws {
        try write([
            attempt(event: mine, marker: "a.jpg", before: "was a", after: "now a"),
            attempt(event: other, marker: "b.jpg", before: "was b", after: "now b"),
        ])

        guard case .records(let records) =
                RepairJournal.reading(forEventID: mine, at: journal) else {
            return XCTFail("expected records for this post")
        }

        XCTAssertEqual(records.map(\.marker), ["a.jpg"],
                       "another post's repair was shown on this post's panel")
    }

    func testTwoPostsAtTheSameVenueAreKeptApart() throws {
        // Dan shoots the same rooms over and over, so the venue cannot tell two
        // of his posts apart. This is the case the event id was added for.
        try write([
            attempt(event: mine, marker: "a.jpg", before: "was a", after: "now a",
                    venue: "The Green Room 42"),
            attempt(event: other, marker: "b.jpg", before: "was b", after: "now b",
                    venue: "The Green Room 42"),
        ])

        guard case .records(let records) =
                RepairJournal.reading(forEventID: mine, at: journal) else {
            return XCTFail("expected records for this post")
        }

        XCTAssertEqual(records.map(\.marker), ["a.jpg"])
    }

    func testARecordWithNoEventIdIsShownOnNoPost() throws {
        var orphan = attempt(event: mine, marker: "a.jpg", before: "x", after: "y")
        orphan.removeValue(forKey: "event_id")
        try write([orphan])

        guard case .nothingRecorded =
                RepairJournal.reading(forEventID: mine, at: journal) else {
            return XCTFail("a record that does not say which post it belongs to "
                           + "was attributed to the post that happened to be open")
        }
    }

    // --- the three answers are distinct -------------------------------------

    func testAnAbsentJournalSaysNothingWasRecorded() {
        let missing = dir.appendingPathComponent("not-there.jsonl")

        guard case .nothingRecorded =
                RepairJournal.reading(forEventID: mine, at: missing) else {
            return XCTFail("an absent journal was not reported as nothing recorded")
        }
    }

    func testAJournalThatCannotBeReadIsNotReportedAsNothingRecorded() throws {
        // Present, and unreadable: a directory where the file should be. An
        // empty answer here would claim the app changed nothing in this post.
        let blocked = dir.appendingPathComponent("blocked.jsonl")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)

        guard case .unreadable = RepairJournal.reading(forEventID: mine, at: blocked) else {
            return XCTFail("a journal that is there and could not be read was "
                           + "reported as no repairs, which is a claim about the "
                           + "post rather than about the file")
        }
    }

    func testNoRecordsForThisPostIsNothingRecordedRatherThanAnError() throws {
        try write([attempt(event: other, marker: "b.jpg", before: "x", after: "y")])

        guard case .nothingRecorded =
                RepairJournal.reading(forEventID: mine, at: journal) else {
            return XCTFail("a journal holding other posts' records should read as "
                           + "nothing recorded for this one")
        }
    }

    // --- what each record says ----------------------------------------------

    func testARefusedRewriteIsSaidToBeUnchanged() throws {
        // `after` is null when the app tried and its own damage gate refused the
        // result. Rendering that as an empty "now" would read as the alt text
        // having been blanked, which is the opposite of what happened.
        try write([attempt(event: mine, marker: "a.jpg", before: "the original",
                           after: nil, outcome: "tried")])

        guard case .records(let records) =
                RepairJournal.reading(forEventID: mine, at: journal),
              let only = records.first else {
            return XCTFail("expected one record")
        }

        XCTAssertEqual(only.before, "the original")
        XCTAssertNil(only.after,
                     "a refused rewrite must stay distinguishable from one that "
                     + "wrote an empty string")
        XCTAssertEqual(only.afterDisplay, RepairJournal.refusedWording,
                       "the panel must make the same claim the terminal reporter "
                       + "makes about a refused rewrite")
    }

    func testOneUnreadableLineDoesNotHideTheGoodOnes() throws {
        let good = try String(data: try JSONSerialization.data(
            withJSONObject: attempt(event: mine, marker: "a.jpg",
                                    before: "x", after: "y")), encoding: .utf8)!
        try "{ not json\n\(good)\n".write(to: journal, atomically: true, encoding: .utf8)

        guard case .records(let records) =
                RepairJournal.reading(forEventID: mine, at: journal) else {
            return XCTFail("one bad line took the whole read down, so a single "
                           + "corrupt record hid every good one")
        }
        XCTAssertEqual(records.map(\.marker), ["a.jpg"])
    }

    func testTheRecordsComeBackOldestFirst() throws {
        var first = attempt(event: mine, marker: "first.jpg", before: "a", after: "b")
        first["at"] = "2026-09-01T09:00:00+00:00"
        var second = attempt(event: mine, marker: "second.jpg", before: "c", after: "d")
        second["at"] = "2026-09-01T18:00:00+00:00"
        try write([first, second])

        guard case .records(let records) =
                RepairJournal.reading(forEventID: mine, at: journal) else {
            return XCTFail("expected records")
        }
        XCTAssertEqual(records.map(\.marker), ["first.jpg", "second.jpg"],
                       "a list read from a store carries no order unless one is "
                       + "declared, and the journal's order is what happened")
    }
}
