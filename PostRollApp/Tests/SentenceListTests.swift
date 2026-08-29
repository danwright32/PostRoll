import XCTest

/// One convention for naming several things inside a sentence.
///
/// The codebase spelled this joiner ten times by hand and the copies disagreed:
/// some produced "a, b and c" and some "a, b, and c", so two sentences on one
/// screen punctuated the same list differently. Dan settled it on 2026-08-28:
/// the comma before "and" stays.
///
/// Note that the comma appears only from THREE items. Two items are joined by
/// "and" alone, which is the half a naive implementation gets wrong, and the
/// two-item case is the commonest one in this app.
final class SentenceListTests: XCTestCase {

    func testNothingNamesNothing() {
        XCTAssertEqual(SentenceList.of([]), "",
                       "a caller with nothing to name must produce nothing, not "
                       + "a sentence with a hole in it")
    }

    func testOneItemStandsAlone() {
        XCTAssertEqual(SentenceList.of(["DPR Dance"]), "DPR Dance")
    }

    func testTwoItemsTakeNoComma() {
        XCTAssertEqual(SentenceList.of(["DPR Dance", "NANM"]),
                       "DPR Dance and NANM",
                       "a comma before and reads wrong with only two")
    }

    func testThreeItemsTakeTheComma() {
        XCTAssertEqual(SentenceList.of(["DPR Dance", "NANM", "Ashley Liang"]),
                       "DPR Dance, NANM, and Ashley Liang")
    }

    func testFourItemsKeepTheCommaOnlyBeforeTheLast() {
        XCTAssertEqual(SentenceList.of(["a", "b", "c", "d"]), "a, b, c, and d")
    }

    func testTheVerbFollowsTheCount() {
        XCTAssertEqual(SentenceList.verb(["a"], singular: "is", plural: "are"), "is")
        XCTAssertEqual(SentenceList.verb(["a", "b"], singular: "is", plural: "are"), "are")
        XCTAssertEqual(SentenceList.verb([], singular: "is", plural: "are"), "are",
                       "an empty list is not singular, and a caller reaching "
                       + "here has nothing to name anyway")
    }
}
