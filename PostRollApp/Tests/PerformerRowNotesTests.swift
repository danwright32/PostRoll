import XCTest

/// What one performer row says under its handle field.
///
/// Two marks can apply at once and they say different things: the book mark
/// (#459) is provenance, "this value was guessed for you", while the duplicate
/// mark is a contradiction, "this value cannot be right for both rows". They
/// are not alternatives and neither replaces the other, so the row decides
/// here rather than in the view, where the precedence would be a line of
/// layout nothing asserts.
final class PerformerRowNotesTests: XCTestCase {

    private let duplicate = DuplicateHandleMark.Mark(sameHandleAs: ["NANM"])

    func testACleanRowSaysNothing() {
        XCTAssertEqual(PerformerRowNotes.lines(duplicate: nil, isGuessed: false, handle: "@nanmdancecompany"), [])
    }

    func testAGuessedHandleKeepsItsExistingNote() {
        XCTAssertEqual(PerformerRowNotes.lines(duplicate: nil, isGuessed: true, handle: "@nanmdancecompany"),
                       [.init(text: HandleBookMark.note, isProblem: false,
                              tooltip: HandleBookMark.explanation)])
    }

    func testADuplicateSaysWhichOtherRowItClashesWith() {
        XCTAssertEqual(PerformerRowNotes.lines(duplicate: duplicate, isGuessed: false, handle: "@nanmdancecompany"),
                       [.init(text: "Same handle as NANM", isProblem: true,
                              tooltip: DuplicateHandleMark.explanation)])
    }

    func testTheClashIsReadBeforeTheProvenance() {
        // Both are true and both are shown. The duplicate goes first because it
        // is the one that has to be acted on: the guess note explains where a
        // value came from, and knowing that does not make it correct.
        XCTAssertEqual(PerformerRowNotes.lines(duplicate: duplicate, isGuessed: true, handle: "@nanmdancecompany").map(\.text),
                       ["Same handle as NANM", HandleBookMark.note])
    }

    func testOnlyTheClashIsDrawnAsAProblem() {
        // The guess note has been a quiet aside since #459 and stays one. If
        // both drew the same, the row would carry two warnings where only one
        // says anything is wrong.
        XCTAssertEqual(PerformerRowNotes.lines(duplicate: duplicate, isGuessed: true, handle: "@nanmdancecompany")
                        .map(\.isProblem),
                       [true, false])
    }

    // MARK: - What the shared check refuses (#1371, #1373)

    func testASentinelSaysThatASearchFoundNobody() {
        // Shaped like a handle, and refused by the shared check, so no caption,
        // tag or invite will ever use it. It read as an ordinary handle, and
        // the performer was silently untaggable (L11).
        let notes = PerformerRowNotes.lines(duplicate: nil, isGuessed: false,
                                            handle: "unknown")

        XCTAssertEqual(notes.map(\.text), [PerformerRowNotes.searchedAndNotFound])
        XCTAssertEqual(notes.map(\.isProblem), [false],
                       "a recorded answer is not a mistake to fix")
    }

    func testAValueThatIsNotEvenHandleShapedKeepsItsOwnMark() {
        // The two are different answers: one was searched for, the other was
        // never a handle at all, and only the second is a problem.
        let notes = PerformerRowNotes.lines(duplicate: nil, isGuessed: false,
                                            handle: "DPR Dance")

        XCTAssertEqual(notes.map(\.text), [PerformerRowNotes.notAHandle])
        XCTAssertEqual(notes.map(\.isProblem), [true])
    }

    func testARealHandleWithNoMarksSaysNothing() {
        XCTAssertTrue(PerformerRowNotes.lines(duplicate: nil, isGuessed: false,
                                              handle: "@jenna").isEmpty)
    }

    func testACheckedAddressIsMarkedQuietly() {
        let notes = PerformerRowNotes.lines(
            duplicate: nil, isGuessed: false, handle: "@jenna",
            checkedProfile: "https://www.instagram.com/jenna/")

        XCTAssertEqual(notes.map(\.text),
                       [PerformerRowNotes.checkedAgainstTheProfile])
        XCTAssertEqual(notes.map(\.isProblem), [false])
    }

    func testAHandleWithNoCheckedAddressIsNotAccused() {
        // Most handles are Dan's own answers, typed or filled from the book.
        // Marking those unverified would accuse the accounts most likely to be
        // right, so the mark goes on the ones that HAVE been checked.
        XCTAssertTrue(PerformerRowNotes.lines(duplicate: nil, isGuessed: false,
                                              handle: "@jenna",
                                              checkedProfile: nil).isEmpty)
    }

    func testASentinelCarryingAnAddressIsNotCalledChecked() {
        // Two marks contradicting each other, and the shared check decides
        // which is true: a value no surface treats as an account cannot be a
        // checked one.
        let notes = PerformerRowNotes.lines(
            duplicate: nil, isGuessed: false, handle: "unknown",
            checkedProfile: "https://www.instagram.com/unknown/")

        XCTAssertEqual(notes.map(\.text), [PerformerRowNotes.searchedAndNotFound])
    }

    func testABlankAddressIsNotACheck() {
        XCTAssertTrue(PerformerRowNotes.lines(duplicate: nil, isGuessed: false,
                                              handle: "@jenna",
                                              checkedProfile: "  ").isEmpty)
    }
}
