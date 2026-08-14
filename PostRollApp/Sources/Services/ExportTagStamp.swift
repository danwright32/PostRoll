import Foundation

/// The account book write that belongs to a finished export (#483).
///
/// The book used to be stamped at the START of the export, before the text
/// export or any asset copy had run, and a failed export never rolled it back.
/// So it recorded a week of tags as sent when nothing had reached disk, and the
/// recurring-account freshness stats it feeds were reading from a non-event.
///
/// The two halves are a value and an action on purpose. Working out WHO was
/// tagged has to happen at the start, from the event as it stands when the run
/// begins; WRITING it may only happen once the export has committed. Holding
/// the first as a stamp that has not been applied yet is what makes the
/// distinction a thing in the code rather than a matter of where a line sits
/// (L33: record intent, confirm after the effect verifiably happened).
struct ExportTagStamp: Equatable {

    /// Every account this run's captions tag.
    let handles: [String]

    /// When the run started. The record is about the export, not about the
    /// moment the bookkeeping happened, which can be minutes later.
    let at: Date

    /// Nothing to record. A single-day re-export, or a week tagging nobody.
    var isEmpty: Bool { handles.isEmpty }

    /// Writes the stamp. Called only from the path that runs after the export
    /// has committed; a run that dies before then leaves the book alone, which
    /// is the whole point.
    @MainActor
    func apply(to book: AccountBook) {
        guard !isEmpty else { return }
        book.noteTagged(handles: handles, on: at)
    }
}
