import XCTest

/// #402: the new event sheet's refusal, which did not exist before.
///
/// The button was greyed at 40% opacity with no message and not even a tooltip,
/// on a form with two required fields, so nothing said which one was missing.
final class NewEventValidationTests: XCTestCase {

    func testACompleteFormHasNothingToRefuse() {
        XCTAssertNil(NewEventValidation.refusal(name: "Spring Gala", org: "Ballet Hispánico"))
        XCTAssertTrue(NewEventValidation.canCreate(name: "Spring Gala", org: "Ballet Hispánico"))
    }

    /// Which field is missing is the whole point: "fill in the form" is what the
    /// greyed button already said.
    func testEachMissingFieldIsNamed() throws {
        let noName = try XCTUnwrap(NewEventValidation.refusal(name: "", org: "Ballet Hispánico"))
        XCTAssertTrue(noName.contains("a name"), noName)
        XCTAssertFalse(noName.contains("organisation"), "the organisation is there, so it is not asked for")

        let noOrg = try XCTUnwrap(NewEventValidation.refusal(name: "Spring Gala", org: ""))
        XCTAssertTrue(noOrg.contains("an organisation"), noOrg)
        XCTAssertFalse(noOrg.contains("a name"), noOrg)
    }

    func testBothMissingFieldsAreNamedInOneSentence() throws {
        let both = try XCTUnwrap(NewEventValidation.refusal(name: "", org: ""))
        XCTAssertTrue(both.contains("a name") && both.contains("an organisation"), both)
    }

    /// Whitespace is not a name. A form holding a space in every field looks
    /// filled in, so the refusal has to survive it.
    func testWhitespaceIsNotAValue() {
        XCTAssertNotNil(NewEventValidation.refusal(name: "   ", org: "Ballet Hispánico"))
        XCTAssertNotNil(NewEventValidation.refusal(name: "\n", org: "  \t "))
    }

    /// The property that makes the defect unrepresentable: the button's enabled
    /// state IS the absence of a refusal, so it cannot be disabled with nothing
    /// to say.
    func testTheButtonCannotBeBlockedWithoutAReason() {
        for (name, org) in [("", ""), ("", "org"), ("name", ""), (" ", "org"), ("name", " ")] {
            XCTAssertFalse(NewEventValidation.canCreate(name: name, org: org))
            XCTAssertNotNil(NewEventValidation.refusal(name: name, org: org),
                            "blocked with no reason for name=\"\(name)\" org=\"\(org)\"")
        }
    }
}
