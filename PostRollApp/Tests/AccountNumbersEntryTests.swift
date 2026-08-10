import XCTest

/// #279, #280: what typing into the numbers form actually stores.
///
/// The parse is its own tested thing because a failed parse must never reach a
/// comparison as a value. A blank or unreadable field has to come out as "not
/// counted", not as zero: zero is a real measurement, and an account scored as
/// having zero engagement sorts to the bottom of a ranking as though it had
/// been counted and found wanting.
final class AccountNumbersEntryTests: XCTestCase {

    func testABlankFieldIsNotCountedRatherThanZero() {
        XCTAssertNil(AccountNumbersEntry.parse(""))
        XCTAssertNil(AccountNumbersEntry.parse("   "))
    }

    func testATypedZeroIsARealMeasurement() {
        // An account that genuinely gets no comments is a fact worth storing.
        XCTAssertEqual(AccountNumbersEntry.parse("0"), 0)
    }

    func testAnOrdinaryNumberParses() {
        XCTAssertEqual(AccountNumbersEntry.parse("2000"), 2_000)
    }

    func testACountPastedWithSeparatorsStillParses() {
        // Instagram shows "2,000" and "1.2K"; the first is what gets pasted.
        XCTAssertEqual(AccountNumbersEntry.parse("2,000"), 2_000)
        XCTAssertEqual(AccountNumbersEntry.parse(" 10,500 "), 10_500)
    }

    func testTextThatIsNotANumberIsNotCountedRatherThanZero() {
        // The whole L50 hazard: a failed parse that becomes 0 compares as a
        // real measurement against every threshold and nothing raises.
        XCTAssertNil(AccountNumbersEntry.parse("about a thousand"))
        XCTAssertNil(AccountNumbersEntry.parse("1.2K"))
        XCTAssertNil(AccountNumbersEntry.parse("-"))
    }

    func testANegativeNumberIsRefused() {
        XCTAssertNil(AccountNumbersEntry.parse("-5"))
    }

    func testAFieldRendersBackAsTheTextThatWouldReproduceIt() {
        // Opening the form on a stored account has to show what is stored, or
        // saving without touching a field would silently clear it.
        XCTAssertEqual(AccountNumbersEntry.text(2_000), "2000")
        XCTAssertEqual(AccountNumbersEntry.text(0), "0")
        XCTAssertEqual(AccountNumbersEntry.text(nil), "")
    }

    func testARoundTripThroughTheFormChangesNothing() {
        for value in [nil, 0, 1, 2_000, 1_000_000] as [Int?] {
            XCTAssertEqual(AccountNumbersEntry.parse(AccountNumbersEntry.text(value)), value)
        }
    }
}
