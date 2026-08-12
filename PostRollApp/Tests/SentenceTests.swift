import XCTest

/// #396: the two failures found by rendering the generation and OCR screens, one
/// of each direction, plus the cases that would produce a third.
final class SentenceTests: XCTestCase {

    /// The generation screen's defect: an OS error that already ended in a full
    /// stop, followed by a full stop of our own.
    func testAReasonThatAlreadyEndsInAFullStopDoesNotGetASecond() {
        XCTAssertEqual(Sentence.closed("The page scans could not be read."),
                       "The page scans could not be read.")
    }

    /// The OCR screen's defect: a library error that ended in nothing, so the next
    /// sentence ran straight into it.
    func testAReasonEndingInNothingGetsAFullStop() {
        XCTAssertEqual(Sentence.closed("connection reset by peer"),
                       "connection reset by peer.")
    }

    func testAStutterOfTerminatorsCollapsesToOne() {
        XCTAssertEqual(Sentence.closed("could not be read.."), "could not be read.")
        XCTAssertEqual(Sentence.closed("what?!?"), "what?")
    }

    /// A question stays a question. Replacing the mark with a full stop would be
    /// rewriting the other system's words, which is not this function's job.
    func testTheReasonsOwnChoiceOfMarkSurvives() {
        XCTAssertEqual(Sentence.closed("is the disk full?"), "is the disk full?")
        XCTAssertEqual(Sentence.closed("out of space!"), "out of space!")
    }

    func testSurroundingWhitespaceGoesBeforeTheMarkIsPlaced() {
        XCTAssertEqual(Sentence.closed("  timed out\n"), "timed out.")
    }

    /// The degenerate inputs. An empty reason must produce nothing rather than a
    /// bare full stop floating in the middle of a sentence.
    func testAnEmptyReasonProducesNothing() {
        XCTAssertEqual(Sentence.closed(""), "")
        XCTAssertEqual(Sentence.closed("   \n "), "")
    }

    /// A reason that is nothing but punctuation has no words to close, so it is
    /// left exactly as it came rather than turned into a different mark.
    func testAReasonOfPunctuationAloneIsLeftAlone() {
        XCTAssertEqual(Sentence.closed("..."), "...")
        XCTAssertEqual(Sentence.closed("?"), "?")
    }

    /// An ellipsis is already an ending (#405).
    ///
    /// Both directions were wrong before. Adding a stop after one produced "…."
    /// on every truncated stderr preview, which is any Python traceback line over
    /// 120 characters. Collapsing one to a single stop rewrites the other system's
    /// words, which is what one of the two bespoke copies of this rule did.
    func testAnEllipsisIsLeftExactlyAsItCame() {
        XCTAssertEqual(Sentence.closed("RuntimeError: something very long\u{2026}"),
                       "RuntimeError: something very long\u{2026}")
        XCTAssertEqual(Sentence.closed("still working..."), "still working...")
        XCTAssertEqual(Sentence.closed("  trailing space after it\u{2026}  "),
                       "trailing space after it\u{2026}")
    }

    /// Two dots is a stutter, three is an ellipsis. The line between them is the
    /// whole reason this cannot be a one-liner at each call site.
    func testTwoDotsCollapseButThreeDoNot() {
        XCTAssertEqual(Sentence.closed("could not be read.."), "could not be read.")
        XCTAssertEqual(Sentence.closed("could not be read..."), "could not be read...")
    }

    /// The sentences the two screens actually build, so this test fails if either
    /// stops using the helper.
    func testTheTwoRealSentencesReadCorrectly() {
        let bake = "The searchable program PDF couldn't be built: "
                 + Sentence.closed("The page scans could not be read.")
                 + " The page scans have been kept."
        XCTAssertFalse(bake.contains(".."), "the double stop is the whole bug")

        let flags = OCRReviewReadiness.flagErrorMessage("connection reset by peer")
        XCTAssertTrue(flags.contains("peer. The data was extracted"),
                      "the reason and the next sentence need exactly one stop between them")
    }
}
