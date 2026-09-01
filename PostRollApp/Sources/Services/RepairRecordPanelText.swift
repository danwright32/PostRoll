import Foundation

/// What the blog panel says about what the app changed in this post (#1162).
///
/// The sentences live here rather than in the view so they can be read cold and
/// held to what they actually claim. The wording follows
/// `tools/read_repair_log.py:report`, which is the reader this replaces for
/// Dan, and the one claim both must make identically (a refused rewrite) is
/// stated once in `RepairJournal.refusedWording` and pinned across the two
/// languages by `tests/test_repair_record_wording.py`.
enum RepairRecordPanelText {

    /// The one line above the list, per state.
    static func summary(for reading: RepairJournal.Reading) -> String {
        switch reading {
        case .records(let records):
            let n = records.count
            return n == 1
                ? "The app changed 1 thing in this post."
                : "The app changed \(n) things in this post."

        case .nothingRecorded:
            // Never "the app changed nothing". The journal cannot support that:
            // a post generated before it existed leaves no trace in it, and an
            // empty answer is not a measurement of what happened (L98).
            return "Nothing recorded for this post. That is not the same as "
                + "nothing having been changed: a post written before this "
                + "record existed leaves no trace here."

        case .unreadable(let why):
            // About the FILE, not about the post. Shown as an empty state this
            // would tell Dan the app changed nothing in a post where it may
            // have changed a great deal (L10, L11).
            return "The record could not be read, so this says nothing about "
                + "whether the app changed anything. \(why)"
        }
    }

    /// One record, as the lines the panel draws for it.
    ///
    /// A field that is absent produces NO line, rather than a label with
    /// nothing after it: a dangling "was:" reads as an alt text that was empty,
    /// which is a different fact from one that was never recorded.
    static func lines(for record: RepairJournal.Record) -> [String] {
        switch record.kind {
        case .attempt:
            var out = ["\(record.marker): \(record.outcome)"]
            if let before = record.before, !before.isEmpty {
                out.append("was: \(before)")
            }
            // Always drawn, because a refused rewrite has its own wording and
            // saying nothing would lose the fact that the app tried.
            out.append("now: \(record.afterDisplay)")
            if let reason = record.reason, !reason.isEmpty {
                out.append("why: \(reason)")
            }
            return out

        case .moved:
            // Two sentences, never one with a flag in it (#1172). A photograph
            // the app MOVED and one it looked at and left alone are different
            // facts, and the second is the one with no other record.
            var out = ["\(record.marker): \(record.outcome)"]
            if let reason = record.reason, !reason.isEmpty {
                out.append("why: \(reason)")
            }
            return out
        }
    }
}
