import XCTest

/// The book refuses to learn a handle the programme itself contradicts.
///
/// `recordAll` runs on advancing past Review and overwrites unconditionally.
/// On Battery Dance Festival, 2026-08-27, a paste had put `@nanmdancecompany`
/// on both "Ashley Liang Dance Company" and "NANM", and the book already held
/// the correct `@lotus_dance_fairy` for Ashley Liang, learned from an earlier
/// event. One press of Continue would have replaced a good value with a wrong
/// one, permanently, and auto-filled it into every future event carrying that
/// name.
///
/// So a row `DuplicateHandleMark` flags is not written. Refusing to learn
/// costs nothing that cannot be recovered by correcting the row and advancing
/// again, while learning the wrong value destroys the good one (L5).
@MainActor
final class HandleBookDuplicateGuardTests: XCTestCase {

    private func performer(_ name: String, handle: String = "") -> Performer {
        Performer(name: name, handle: handle)
    }

    /// A scratch book, never the shared one (L2).
    private func book() -> HandleBook {
        HandleBook(defaults: UserDefaults(suiteName: "handle-book-\(UUID().uuidString)")!)
    }

    func testTheGoodHandleTheBookAlreadyHeldSurvivesTheBadPaste() {
        // Verbatim from the event and the book on disk.
        let book = book()
        book.record(performer: "Ashley Liang Dance Company", handle: "@lotus_dance_fairy")

        book.recordAll(performers: [
            performer("Ashley Liang Dance Company", handle: "@nanmdancecompany"),
            performer("NANM", handle: "@nanmdancecompany"),
        ])

        XCTAssertEqual(book.handle(forPerformer: "Ashley Liang Dance Company"),
                       "@lotus_dance_fairy")
    }

    func testNeitherHalfOfADuplicateIsLearned() {
        // Not even the one that is probably right. Which row holds the bad
        // value is exactly what the app cannot know, so recording the "other"
        // one is a guess wearing the clothes of a fact.
        let book = book()

        book.recordAll(performers: [
            performer("Ashley Liang Dance Company", handle: "@nanmdancecompany"),
            performer("NANM", handle: "@nanmdancecompany"),
        ])

        XCTAssertEqual(book.handle(forPerformer: "NANM"), "")
    }

    func testTwoRowsSharingOnlyANameAreStillLearned() {
        // A repeated NAME is warned about on the row but does not stop the
        // write. Dan's call, 2026-08-27: two performers genuinely sharing a
        // name is a thing that happens, and refusing to learn either would
        // mean retyping both handles at every future event, forever, for a
        // programme that is not wrong.
        //
        // The book holds one entry per name, so the later row wins, and the
        // value it auto-fills is already marked as a guess by HandleBookMark
        // (#459) rather than presented as read off the programme.
        let book = book()

        book.recordAll(performers: [
            performer("Ana Vidović", handle: "@ana"),
            performer("Ana Vidović", handle: "@vidovic"),
        ])

        XCTAssertEqual(book.handle(forPerformer: "Ana Vidović"), "@vidovic")
    }

    func testARepeatedNameIsStillReportedOnTheRow() {
        // The write is allowed, the warning is not withdrawn. Those are two
        // different decisions and only the first one changed.
        let a = performer("Ana Vidović", handle: "@ana")
        let b = performer("Ana Vidović", handle: "@vidovic")

        XCTAssertEqual(DuplicateHandleMark.marks(in: [a, b])[a.id]?.sameNameAs,
                       ["Ana Vidović"])
    }

    func testEveryOtherPerformerOnTheSameProgrammeIsStillLearned() {
        // The refusal is scoped to the rows that collide. One bad paste must
        // not cost the whole programme its handles.
        let book = book()

        book.recordAll(performers: [
            performer("Ina Medhanet", handle: "@inamedhanet"),
            performer("Ashley Liang Dance Company", handle: "@nanmdancecompany"),
            performer("NANM", handle: "@nanmdancecompany"),
            performer("Mailantia Dance Company", handle: "@mailantia.danceco"),
        ])

        XCTAssertEqual(book.handle(forPerformer: "Ina Medhanet"), "@inamedhanet")
        XCTAssertEqual(book.handle(forPerformer: "Mailantia Dance Company"),
                       "@mailantia.danceco")
    }

    func testCorrectingTheDuplicateLetsBothBeLearned() {
        // The refusal has to clear, or the guard quietly becomes a permanent
        // block on two performers nobody can ever record again.
        let book = book()

        book.recordAll(performers: [
            performer("Ashley Liang Dance Company", handle: "@lotus_dance_fairy"),
            performer("NANM", handle: "@nanmdancecompany"),
        ])

        XCTAssertEqual(book.handle(forPerformer: "Ashley Liang Dance Company"),
                       "@lotus_dance_fairy")
        XCTAssertEqual(book.handle(forPerformer: "NANM"), "@nanmdancecompany")
    }
}
