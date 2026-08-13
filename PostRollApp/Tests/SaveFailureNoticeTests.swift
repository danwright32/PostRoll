import XCTest

/// #446: a save that starts failing mid-session has to say so.
///
/// `EventStore.save` has always returned an outcome and every caller threw it
/// away, so a save that began failing during an evening of editing reached NSLog
/// and nothing else, and failed again silently on every subsequent edit.
/// events.json is, by the code's own comment, the single copy of every caption,
/// blog, OCR result and crop edit, so quitting after that evening lost all of it
/// with no signal. Load failures were surfaced; saves were not.
final class SaveFailureNoticeTests: XCTestCase {

    func testItNamesTheReasonTheSystemGave() {
        let message = SaveFailureNotice.message(reason: "The volume is out of space.")

        XCTAssertTrue(message.contains("out of space"), message)
    }

    func testItSaysTheWorkIsNotOnDisk() {
        // The whole point. "Could not save" alone reads as a hiccup; what Dan
        // needs to know is that what he is looking at exists nowhere else.
        let message = SaveFailureNotice.message(reason: "The volume is out of space.")

        XCTAssertTrue(message.contains("not been saved"), message)
    }

    func testItTellsHimWhatToDoAboutIt() {
        // A message that names a problem and offers nothing to do about it leaves
        // the reader exactly where they were (L80, L111).
        let message = SaveFailureNotice.message(reason: "disk not writable")

        XCTAssertTrue(message.contains(SaveFailureNotice.retryLabel)
                      || message.lowercased().contains("try"), message)
    }

    func testItReadsAsOneSentenceWhateverTheReasonBrings() {
        for reason in ["The volume is out of space.", "disk not writable",
                       "is the disk full?", "reading failed\u{2026}"] {
            let message = SaveFailureNotice.message(reason: reason)

            XCTAssertFalse(message.contains(".."), "double stop: \(message)")
            XCTAssertFalse(message.contains(" ."), "orphaned stop: \(message)")
            XCTAssertFalse(message.contains("\u{2026}."), "stop after an ellipsis: \(message)")
        }
    }

    func testTheRetryLabelSaysWhatItRetries() {
        // "Try again" alone would leave Dan guessing what it tries: this banner
        // sits in a window that also has a retry for a store it could not READ,
        // and those two do different things. Matched on the stem so "save" and
        // "saving" both pass, since the rule is that the control names its action.
        let label = SaveFailureNotice.retryLabel.lowercased()

        XCTAssertNotEqual(label, "try again", "the label does not say what it retries")
        XCTAssertTrue(label.contains("sav"), SaveFailureNotice.retryLabel)
    }
}
