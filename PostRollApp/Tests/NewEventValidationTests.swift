import XCTest

/// #402: the new event sheet's refusal, which did not exist before.
///
/// The button was greyed at 40% opacity with no message and not even a tooltip,
/// on a form with two required fields, so nothing said which one was missing.
///
/// One of those two fields is no longer required (#689). A director hiring Dan
/// to shoot a play is not an organisation, and there is nothing to type, so an
/// event like that could not be created at all without inventing one. An
/// invented organisation is worse than a missing one: it reaches a caption, a
/// folder name and the handle book as though it were a fact.
final class NewEventValidationTests: XCTestCase {

    func testACompleteFormHasNothingToRefuse() {
        XCTAssertNil(NewEventValidation.refusal(name: "Spring Gala"))
        XCTAssertTrue(NewEventValidation.canCreate(name: "Spring Gala"))
    }

    /// The change Dan asked for: a name and nothing else.
    func testANameOnItsOwnIsEnough() {
        XCTAssertNil(NewEventValidation.refusal(name: "Hamlet"),
                     "an event with no organisation is still refused, which is "
                     + "the shoot with a director and no company behind it")
        XCTAssertTrue(NewEventValidation.canCreate(name: "Hamlet"))
    }

    /// What is missing is still named. "Fill in the form" is what the greyed
    /// button already said.
    func testTheMissingNameIsNamed() throws {
        let refusal = try XCTUnwrap(NewEventValidation.refusal(name: ""))
        XCTAssertTrue(refusal.contains("a name"), refusal)
        XCTAssertFalse(refusal.lowercased().contains("organi"),
                       "the organisation is asked for in a sentence that no "
                       + "longer requires it: \(refusal)")
    }

    /// Whitespace is not a name. A form holding a space looks filled in, so the
    /// refusal has to survive it.
    func testWhitespaceIsNotAValue() {
        XCTAssertNotNil(NewEventValidation.refusal(name: "   "))
        XCTAssertNotNil(NewEventValidation.refusal(name: "\n"))
    }

    /// The property that makes the defect unrepresentable: the button's enabled
    /// state IS the absence of a refusal, so it cannot be disabled with nothing
    /// to say.
    func testTheButtonCannotBeBlockedWithoutAReason() {
        for name in ["", " ", "\n", "\t "] {
            XCTAssertFalse(NewEventValidation.canCreate(name: name))
            XCTAssertNotNil(NewEventValidation.refusal(name: name),
                            "blocked with no reason for name=\"\(name)\"")
        }
    }
}
