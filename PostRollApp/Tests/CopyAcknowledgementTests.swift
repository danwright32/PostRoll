import XCTest

/// #466: a copy button that looks the same after being pressed reads as broken.
///
/// #205 fixed exactly this for the blog copy button and wrote the reasoning
/// down; the three per-day caption copy buttons were the siblings it skipped
/// (L30). What is asserted here is the whole of the rule, including the half
/// that matters more: the acknowledgment has to stop being true the moment the
/// text it is about is edited, because a checkmark beside text the clipboard
/// does not hold is worse than no acknowledgment at all (L12).
final class CopyAcknowledgementTests: XCTestCase {

    func testNothingCopiedYetIsNotAnAcknowledgment() {
        XCTAssertFalse(CopyAcknowledgement.stillDescribesTheClipboard(
            copied: nil, current: "From the wings."))
    }

    func testCopyingTheTextOnScreenIsAcknowledged() {
        XCTAssertTrue(CopyAcknowledgement.stillDescribesTheClipboard(
            copied: "From the wings.", current: "From the wings."))
    }

    /// The point of deriving it rather than holding a flag: an edit after the
    /// copy leaves the clipboard holding the old words, so the acknowledgment
    /// has nothing left to be about.
    func testEditingTheTextAfterCopyingDropsTheAcknowledgment() {
        XCTAssertFalse(CopyAcknowledgement.stillDescribesTheClipboard(
            copied: "From the wings.", current: "From the wings, before the call."))
    }

    /// And typing it back is genuinely the same text on the clipboard again.
    func testTypingTheTextBackIsAcknowledgedAgain() {
        XCTAssertTrue(CopyAcknowledgement.stillDescribesTheClipboard(
            copied: "From the wings.", current: "From the wings."))
    }

    func testAnEmptyCaptionCopiedIsStillACopy() {
        XCTAssertTrue(CopyAcknowledgement.stillDescribesTheClipboard(copied: "", current: ""))
    }

    /// Two glyphs, not one glyph in two colours: colour alone is not a
    /// difference everyone can see (L20).
    func testTheTwoStatesDrawDifferentIcons() {
        XCTAssertNotEqual(CopyAcknowledgement.symbol(copied: true),
                          CopyAcknowledgement.symbol(copied: false))
    }

    func testTheLabelSaysWhatIsBeingCopied() {
        XCTAssertEqual(CopyAcknowledgement.label(copied: false, what: "Sunday caption"),
                       "Copy Sunday caption")
    }

    func testTheLabelSaysSoOnceItHasBeenCopied() {
        let label = CopyAcknowledgement.label(copied: true, what: "Sunday caption")

        XCTAssertTrue(label.lowercased().contains("copied"), label)
        XCTAssertTrue(label.contains("Sunday caption"),
                      "the acknowledgment does not say which caption: \(label)")
    }
}
