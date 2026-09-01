import Foundation

/// What the app changed in one blog post, read from the repair journal (#1162).
///
/// Repairs are silent by design, so `blog-repairs.jsonl` is the only record
/// that the app rewrote anything in a post. Until this existed the only reader
/// was `tools/read_repair_log.py`, run from a terminal, and Dan does not work in
/// a terminal: a field with a writer and no reader is not evidence (L46), and a
/// reader he will not use comes to the same thing.
///
/// The wording follows `tools/read_repair_log.py:report`, which is the reader
/// this one replaces for him. Two readers of one file in two languages is a
/// drift hazard, so what they must agree on (the claim a refused rewrite makes)
/// is stated once here and pinned to the Python source by
/// `tests/test_repair_record_wording.py`.
enum RepairJournal {

    /// What the panel says when the app tried and its own damage gate refused
    /// the rewrite. `after` is null in that case, and rendering it as an empty
    /// value would read as the alt text having been blanked, which is the
    /// opposite of what happened.
    static let refusedWording = "(unchanged: the rewrite was refused)"

    /// One thing the app did to this post.
    struct Record: Identifiable {
        enum Kind: String {
            /// A rewrite of one marker's alt text.
            case attempt
            /// A photograph the placement repair moved, or declined to move.
            case moved
        }

        let id = UUID()
        let kind: Kind
        let at: Date?
        let marker: String
        /// `repaired`, `tried` or `blocked` for an attempt; for a move, whether
        /// it was placed or deliberately left alone.
        let outcome: String
        let before: String?
        /// nil means the rewrite was refused, NOT that it wrote nothing.
        let after: String?
        let reason: String?

        var afterDisplay: String { after ?? RepairJournal.refusedWording }
    }

    /// The three answers, kept apart because they are different facts (L10,
    /// L11). Collapsing the third into the second would tell Dan the app
    /// changed nothing in a post where it may have changed a great deal, and
    /// this is the only record that it changed anything at all.
    enum Reading {
        /// At least one record belongs to this post.
        case records([Record])
        /// The journal was read and holds nothing for this post. Not the same
        /// as nothing having been changed: a post generated before the journal
        /// existed leaves no trace in it.
        case nothingRecorded
        /// The journal is THERE and could not be read. Evidence missing, never
        /// evidence of absence.
        case unreadable(String)
    }

    /// Whether this process is a test run.
    ///
    /// `XCTestConfigurationFilePath` is set by the test runner for the whole
    /// process and by nothing else, so it is true in the suite and false in the
    /// app, which is the distinction that matters. The mirror of
    /// `running_under_test` in `postroll/data_root.py`.
    static func runningUnderTest(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// Where the Python side writes it. One name, declared once, in
    /// `DataInventory`.
    ///
    /// Under a test this answers somewhere harmless, for the reason #1179 gave
    /// on the writing side: the panel is rendered by tests that are about
    /// something else entirely, and a view that reads a real home folder path
    /// from the suite is reaching live data whether or not it writes to it
    /// (L2). Only when nobody has CHOSEN a data directory, because a test that
    /// sets `POSTROLL_DATA_DIR` has already said where to look and overriding
    /// that would break the seam this protects (L324).
    static var defaultPath: URL {
        let chosen = (ProcessInfo.processInfo.environment["POSTROLL_DATA_DIR"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        if runningUnderTest() && chosen.isEmpty {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("postroll-test-\(DataInventory.repairLogFileName)")
        }
        return AppPaths.root.appendingPathComponent(DataInventory.repairLogFileName)
    }

    static func reading(forEventID eventID: UUID,
                        at url: URL? = nil) -> Reading {
        let path = url ?? defaultPath

        // Absent is the honest empty answer: no pass has run against this data
        // directory yet.
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .nothingRecorded
        }

        let text: String
        do {
            text = try String(contentsOf: path, encoding: .utf8)
        } catch {
            return .unreadable(
                "The record of what the app changed is at \(path.path) and could "
                + "not be read (\(error.localizedDescription)). Treat this as "
                + "evidence missing rather than as no repairs.")
        }

        let wanted = eventID.uuidString.lowercased()
        let clock = InstantParser()
        var out: [Record] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // One line that will not parse is SKIPPED, never fatal: a single
            // corrupt record must not hide every good one. The Python reader
            // makes the same choice for the same reason.
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any] else { continue }

            // Selected on the event id and on nothing else. There is no
            // fallback to the name or the venue: those are what the id
            // replaced, and falling back would put another post's repairs on
            // this panel in exactly the cases the id was added for (L214).
            //
            // A record with no id belongs to no post. Matching one here would
            // hand every orphaned record to whichever post was opened.
            guard let id = record["event_id"] as? String,
                  !id.isEmpty,
                  id.lowercased() == wanted else { continue }

            guard let kind = (record["kind"] as? String).flatMap(Record.Kind.init),
                  let marker = record["marker"] as? String else { continue }

            out.append(Record(
                kind: kind,
                at: (record["at"] as? String).flatMap(clock.date(from:)),
                marker: marker,
                outcome: Self.outcome(of: record, kind: kind),
                before: record["before"] as? String,
                after: record["after"] as? String,
                reason: (record["reason"] as? String).flatMap {
                    $0.isEmpty ? nil : $0
                }))
        }

        // Order is the journal's own: what happened, in the order it happened.
        return out.isEmpty ? .nothingRecorded : .records(out)
    }

    private static func outcome(of record: [String: Any],
                                kind: Record.Kind) -> String {
        switch kind {
        case .attempt:
            return record["outcome"] as? String ?? "?"
        case .moved:
            // Two facts, never one with a flag in it (#1172): a photograph the
            // app MOVED and one it looked at and left alone are different, and
            // the second is the one with no other record.
            return (record["placed"] as? Bool ?? false)
                ? "moved" : "left where it was"
        }
    }

    /// Python writes `datetime.isoformat()`, which carries fractional seconds
    /// only when there are any, so both spellings are real and both appear in
    /// the same file.
    ///
    /// Built per read rather than held in a static: `ISO8601DateFormatter` is
    /// not `Sendable`, and a shared mutable one is a data race the compiler
    /// refuses. One read handles a handful of records, so the pair is made once
    /// per read and not once per record.
    struct InstantParser {
        private let withFraction: ISO8601DateFormatter
        private let withoutFraction: ISO8601DateFormatter

        init() {
            withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            withoutFraction = ISO8601DateFormatter()
            withoutFraction.formatOptions = [.withInternetDateTime]
        }

        func date(from text: String) -> Date? {
            withFraction.date(from: text) ?? withoutFraction.date(from: text)
        }
    }
}
