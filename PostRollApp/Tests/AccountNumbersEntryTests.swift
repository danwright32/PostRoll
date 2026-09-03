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

    // MARK: - The private mark is made on this form (#982)
    //
    // A SwiftUI sheet with this much environment cannot be built in a test, so
    // what is guarded is the wiring: the form carries the control, and both
    // screens that present the form carry its answer through to the book.
    // Without a control the mark can never be set by anybody, and a ranking key
    // nothing can ever set is a rule that never fires (L543).

    func testTheNumbersFormOffersTheMark() throws {
        let source = try Self.source("Views/CollaboratorPanel.swift")

        XCTAssertTrue(source.contains("Toggle("),
                      "the form has no control for the mark, so isPrivate can "
                      + "never be set on any account and the ranking key that "
                      + "reads it can never fire")
        // The RULE, not the exact spelling of the signature: pinning the tuple
        // made this fail the first time a second mark was legitimately added
        // (L103). What matters is that both marks leave the form.
        let saves = try XCTUnwrap(source.range(of: "let onSave:").map { start in
            String(source[start.upperBound...].prefix(120))
        })
        XCTAssertEqual(saves.prefix(while: { $0 != "\n" }).filter { $0 == "B" }.count, 2,
                       "the form reports fewer than the two marks it carries: \(saves)")
        XCTAssertTrue(source.contains("CollaboratorPick.privateFormNote"),
                      "the control says what the mark means in its own words, "
                      + "which is how the form and CAPTIONS.txt come to describe "
                      + "the same mark differently")
    }

    func testTheFormPrefillsBothMarksSoSavingCannotClearThem() throws {
        let source = try Self.source("Views/CollaboratorPanel.swift")

        XCTAssertTrue(source.contains("stats?.isPrivate ?? false"),
                      "the private control opens unticked whatever is stored, so "
                      + "saving an unrelated figure unmarks the account")
        XCTAssertTrue(source.contains("stats?.neverInvite ?? false"),
                      "the never invite control opens unticked whatever is "
                      + "stored, so saving an unrelated figure starts offering "
                      + "an account Dan has decided against")
    }

    func testBothScreensCarryTheMarkIntoTheBook() throws {
        // Scoped to each save handler rather than the whole file, because a
        // whole-file search for `isPrivate` passes on a file that merely
        // mentions it somewhere else.
        for (file, sheet) in [("Views/CaptionReviewView.swift", "$editingAccount"),
                              ("Views/ExportView.swift", "$editingRecurringAccount")] {
            let source = try Self.source(file)
            let handler = try XCTUnwrap(
                source.range(of: ".sheet(item: \(sheet))").map { start in
                    let rest = source[start.upperBound...]
                    return String(rest[..<(rest.range(of: "onCancel:")?.lowerBound
                                           ?? rest.endIndex)])
                }, file)

            XCTAssertTrue(handler.contains("isPrivate: isPrivate"),
                          "\(file) drops the private mark on the way to the "
                          + "book, so ticking the box does nothing")
            XCTAssertTrue(handler.contains("neverInvite: neverInvite"),
                          "\(file) drops the never invite mark on the way to "
                          + "the book, so ticking the box does nothing")
        }
    }

    private static func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/\(path)"),
            encoding: .utf8)
    }
}
