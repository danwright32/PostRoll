import Foundation

/// What the screen says when a note could not be written to the brand voice
/// file (#462).
///
/// Four places wrote to that file through `try?` and then said the write had
/// happened: the Insights Apply button flipped to Applied and disabled itself,
/// the save-feedback checkbox in both caption and blog revision dismissed
/// silently, and the learning sheet discarded a suggestion Dan had just edited
/// by hand and advanced the week. A failed write is unrecoverable from every one
/// of those surfaces, because the only copy of what he typed was in the sheet
/// that just closed (L12: show success only after the write commits).
///
/// Kept out of the views so the wording can be pinned by a test, and so all four
/// say the same thing about the same file.
enum BrandVoiceSaveText {

    /// The note itself failed and nothing else was happening.
    static func failed(_ reason: String) -> String {
        "That note could not be saved to your brand voice file: "
        + Sentence.closed(reason)
        + " It is still here, so nothing is lost, and you can try again."
    }

    /// The work the note was attached to DID land. Said separately from the
    /// note's own failure, because reporting this as one failure would tell Dan
    /// his revision had not happened when it had (L53).
    static func revisionLandedButNoteDidNot(_ reason: String) -> String {
        "The revision was applied. What could not be saved is the note for your "
        + "brand voice file: " + Sentence.closed(reason)
    }
}
