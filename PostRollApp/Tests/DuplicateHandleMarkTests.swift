import XCTest

/// Two performers carrying one handle, and two carrying one name.
///
/// Measured on Battery Dance Festival, 2026-08-27: a paste put
/// `@nanmdancecompany` on both "Ashley Liang Dance Company" and "NANM". Every
/// list built from the performers is keyed on the handle, so the second of the
/// two was dropped everywhere at once and nothing said so. The tagging sheet
/// offered five performers out of six, the caption credited one account where
/// two companies danced, and the handle book was one screen away from
/// replacing the good `@lotus_dance_fairy` it already held for Ashley Liang.
///
/// The collision is invisible at every one of those sites because each is
/// correct in isolation: a tag list may hold an account once, a caption may
/// mention it once, a book holds one handle per name. Only the Review screen,
/// where both rows are on screen together, can say the two are not the same
/// account. So the mark is derived here, once, and read by all three.
final class DuplicateHandleMarkTests: XCTestCase {

    private func performer(_ name: String, handle: String = "") -> Performer {
        Performer(name: name, handle: handle)
    }

    // MARK: - The handle collision, as it actually happened

    func testTwoPerformersPastedWithOneHandleAreBothMarked() {
        // Verbatim from the event on disk.
        let ashley = performer("Ashley Liang Dance Company", handle: "@nanmdancecompany")
        let nanm = performer("NANM", handle: "@nanmdancecompany")

        let marks = DuplicateHandleMark.marks(in: [ashley, nanm])

        // BOTH, not just the second. Which one holds the wrong paste is not
        // something the app can know, and marking only the later row would
        // point at the wrong company half the time.
        XCTAssertEqual(marks[ashley.id]?.sameHandleAs, ["NANM"])
        XCTAssertEqual(marks[nanm.id]?.sameHandleAs, ["Ashley Liang Dance Company"])
    }

    func testTheMarkIgnoresCaseSpacingAndTheLeadingAt() {
        // The three ways the same account is written into that field. None of
        // them is a different account, so none may read as one.
        let a = performer("A", handle: "@nanmdancecompany")
        let b = performer("B", handle: " NANMDanceCompany ")

        let marks = DuplicateHandleMark.marks(in: [a, b])

        XCTAssertEqual(marks[a.id]?.sameHandleAs, ["B"])
        XCTAssertEqual(marks[b.id]?.sameHandleAs, ["A"])
    }

    func testAThirdPerformerOnTheSameHandleMarksAllThree() {
        let a = performer("A", handle: "@shared")
        let b = performer("B", handle: "@shared")
        let c = performer("C", handle: "@shared")

        let marks = DuplicateHandleMark.marks(in: [a, b, c])

        XCTAssertEqual(marks[a.id]?.sameHandleAs, ["B", "C"])
        XCTAssertEqual(marks[b.id]?.sameHandleAs, ["A", "C"])
        XCTAssertEqual(marks[c.id]?.sameHandleAs, ["A", "B"])
    }

    func testDistinctHandlesAreNotMarked() {
        let list = [performer("A", handle: "@a"), performer("B", handle: "@b")]

        XCTAssertTrue(DuplicateHandleMark.marks(in: list).isEmpty)
    }

    // MARK: - What is not a duplicate

    func testPlaceholderHandlesAreNotADuplicate() {
        // "none" and a blank field are the same statement: this performer has
        // no handle. Two people who both have no handle share nothing, and a
        // warning on every handleless row would be noise on the commonest
        // programme there is.
        let list = [performer("A", handle: "none"),
                    performer("B", handle: ""),
                    performer("C", handle: "unknown")]

        XCTAssertTrue(DuplicateHandleMark.marks(in: list).isEmpty)
    }

    func testAPerformerIsNotADuplicateOfItself() {
        XCTAssertTrue(DuplicateHandleMark.marks(in: [performer("A", handle: "@a")]).isEmpty)
    }

    func testAnEmptyRowIsNotMarked() {
        // The blank row "Add Performer" leaves behind, twice over.
        let list = [performer("", handle: ""), performer("", handle: "")]

        XCTAssertTrue(DuplicateHandleMark.marks(in: list).isEmpty)
    }

    // MARK: - The name collision, which poisons the book instead

    func testTwoPerformersWithOneNameAreMarkedEvenWhenTheirHandlesDiffer() {
        // The handle book is keyed on the normalised NAME, so two rows sharing
        // a name write to one entry and the later one silently wins. That is a
        // different collision from the handle one, with a different remedy, so
        // it is reported separately rather than folded into the same sentence.
        let a = performer("Ana Vidović", handle: "@ana")
        let b = performer("ana vidović ", handle: "@vidovic")

        let marks = DuplicateHandleMark.marks(in: [a, b])

        XCTAssertEqual(marks[a.id]?.sameNameAs, ["ana vidović"])
        XCTAssertEqual(marks[b.id]?.sameNameAs, ["Ana Vidović"])
        XCTAssertEqual(marks[a.id]?.sameHandleAs, [String]())
    }

    func testARowIsMarkedForBothWhenTheNameAndTheHandleBothRepeat() {
        // The same performer entered twice. Both sentences are true and both
        // are shown, because clearing one does not clear the other.
        let a = performer("NANM", handle: "@nanmdancecompany")
        let b = performer("NANM", handle: "@nanmdancecompany")

        let marks = DuplicateHandleMark.marks(in: [a, b])

        XCTAssertEqual(marks[a.id]?.sameHandleAs, ["NANM"])
        XCTAssertEqual(marks[a.id]?.sameNameAs, ["NANM"])
    }

    // MARK: - What the row says

    func testTheRowNamesTheOtherPerformerRatherThanSayingSomethingRepeats() {
        // A warning that a value repeats, without saying where, leaves the
        // whole list to be read by hand. Naming the other row is the whole
        // difference between a notice and an instruction (L80).
        let a = performer("Ashley Liang Dance Company", handle: "@nanmdancecompany")
        let b = performer("NANM", handle: "@nanmdancecompany")
        let mark = DuplicateHandleMark.marks(in: [a, b])[a.id]

        XCTAssertEqual(mark?.note, "Same handle as NANM")
    }

    func testARowSharingAHandleWithTwoOthersNamesBoth() {
        let a = performer("A", handle: "@shared")
        let b = performer("B", handle: "@shared")
        let c = performer("C", handle: "@shared")

        XCTAssertEqual(DuplicateHandleMark.marks(in: [a, b, c])[a.id]?.note,
                       "Same handle as B and C")
    }

    func testARowThatOnlyRepeatsANameSaysSo() {
        let a = performer("Ana Vidović", handle: "@ana")
        let b = performer("Ana Vidović", handle: "@vidovic")

        XCTAssertEqual(DuplicateHandleMark.marks(in: [a, b])[a.id]?.note,
                       "Same name as Ana Vidović")
    }

    func testARowThatRepeatsBothSaysBoth() {
        let a = performer("NANM", handle: "@nanmdancecompany")
        let b = performer("NANM", handle: "@nanmdancecompany")

        XCTAssertEqual(DuplicateHandleMark.marks(in: [a, b])[a.id]?.note,
                       "Same name and handle as NANM")
    }
}
