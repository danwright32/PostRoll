import XCTest

/// #491: the new event form trimmed stored values with `.whitespaces`, which
/// does not include newlines, while its own validator used
/// `.whitespacesAndNewlines`.
///
/// So a value pasted with a trailing newline passed validation and was stored
/// WITH the newline, and because org and venue are the handle book's lookup
/// keys, that org became a permanently separate key whose saved handles never
/// auto-filled again.
final class FieldTextTests: XCTestCase {

    func testATrailingNewlineIsTrimmedFromAStoredValue() {
        // The exact shape of the bug: pasting from a web page brings the
        // newline along, and nothing on screen shows it.
        XCTAssertEqual(FieldText.normalized("Decoda\n"), "Decoda")
        XCTAssertEqual(FieldText.normalized("\nDecoda\r\n"), "Decoda")
        XCTAssertEqual(FieldText.normalized("  Decoda \t\n "), "Decoda")
    }

    func testTheValidatorAndTheStoreAgreeOnWhatIsBlank() {
        // These disagreeing is what let the newline through in the first place.
        for raw in ["\n", "   ", " \n ", "\t", ""] {
            XCTAssertTrue(FieldText.isBlank(raw), "\(raw.debugDescription) should be blank")
            XCTAssertTrue(FieldText.normalized(raw).isEmpty)
        }
    }

    func testAValueWithInnerSpacingIsLeftAlone() {
        XCTAssertEqual(FieldText.normalized("Music From Inside"), "Music From Inside")
    }

    // MARK: - The consequence the bug actually had

    func testAPastedOrgKeysTheSameHandleBookEntryAsATypedOne() {
        // The handle book keys on the normalised name, so a newline-suffixed org
        // used to be a different account entirely.
        XCTAssertEqual(FieldText.normalized("Decoda\n").lowercased(),
                       FieldText.normalized("Decoda").lowercased())
    }

    func testTheFormRefusesAValueThatIsOnlyANewline() {
        // The name only. The organisation stopped being required (#689), so an
        // organisation of just a newline is now the same as not typing one,
        // which is a legitimate event rather than a refusal.
        XCTAssertNotNil(NewEventValidation.refusal(name: "\n"),
                        "a name of just a newline was accepted")
        XCTAssertFalse(NewEventValidation.canCreate(name: " \n "))
        XCTAssertTrue(NewEventValidation.canCreate(name: "Show"))
    }
}
