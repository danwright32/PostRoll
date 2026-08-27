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
        XCTAssertEqual(PerformerRowNotes.lines(duplicate: nil, isGuessed: false), [])
    }

    func testAGuessedHandleKeepsItsExistingNote() {
        XCTAssertEqual(PerformerRowNotes.lines(duplicate: nil, isGuessed: true),
                       [.init(text: HandleBookMark.note, isProblem: false,
                              tooltip: HandleBookMark.explanation)])
    }

    func testADuplicateSaysWhichOtherRowItClashesWith() {
        XCTAssertEqual(PerformerRowNotes.lines(duplicate: duplicate, isGuessed: false),
                       [.init(text: "Same handle as NANM", isProblem: true,
                              tooltip: DuplicateHandleMark.explanation)])
    }

    func testTheClashIsReadBeforeTheProvenance() {
        // Both are true and both are shown. The duplicate goes first because it
        // is the one that has to be acted on: the guess note explains where a
        // value came from, and knowing that does not make it correct.
        XCTAssertEqual(PerformerRowNotes.lines(duplicate: duplicate, isGuessed: true).map(\.text),
                       ["Same handle as NANM", HandleBookMark.note])
    }

    func testOnlyTheClashIsDrawnAsAProblem() {
        // The guess note has been a quiet aside since #459 and stays one. If
        // both drew the same, the row would carry two warnings where only one
        // says anything is wrong.
        XCTAssertEqual(PerformerRowNotes.lines(duplicate: duplicate, isGuessed: true)
                        .map(\.isProblem),
                       [true, false])
    }
}
