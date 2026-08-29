import XCTest

/// The tag fields say when a value will be credited by name rather than tagged
/// (#919).
///
/// #912 made a value that is not a usable handle become a NAME credit instead
/// of a broken mention, and #917 stopped it reaching the exported tag list at
/// all. Both are the right outcome and both happen silently, so somebody
/// typing a company name into a tag field is never told the account was not
/// usable.
///
/// The performer rows already say this: #899 put "Not an Instagram handle"
/// under that field. These fields carry the same value through the same rule
/// and said nothing, so one surface taught what the other hid (L11).
///
/// A pure type so the sentence can be asserted, the way `PhotoTagSheetNote` is.
/// The routing and the sentence both read `TypedCredit`, so they cannot
/// disagree about what will happen to a value.
final class TagFieldNoteTests: XCTestCase {

    func testAFieldOfRealHandlesSaysNothing() {
        XCTAssertNil(TagFieldNote.line(for: "dciny, @asinger"),
                     "every value is taggable, so there is nothing to report")
    }

    func testAnEmptyFieldSaysNothing() {
        XCTAssertNil(TagFieldNote.line(for: ""))
        XCTAssertNil(TagFieldNote.line(for: "   ,  , "),
                     "separators around nothing are not values")
    }

    func testANameIsNamedAndItsOutcomeStated() throws {
        let line = try XCTUnwrap(TagFieldNote.line(for: "dciny, DPR Dance"))

        XCTAssertTrue(line.contains("DPR Dance"),
                      "naming the value is the whole point: a count leaves the "
                      + "field to be read by hand to find out which one (L80)")
        XCTAssertTrue(line.contains("credited by name"),
                      "the sentence has to say what WILL happen, not only that "
                      + "something is wrong")
        XCTAssertFalse(line.contains("dciny"),
                       "naming a value that is fine sends somebody to correct "
                       + "something that needs no correcting")
    }

    func testTwoNamesReadAsASentence() throws {
        let line = try XCTUnwrap(
            TagFieldNote.line(for: "DPR Dance, Battery Dance Company"))

        XCTAssertTrue(line.contains("DPR Dance and Battery Dance Company"),
                      "got: \(line)")
    }

    /// A sentinel and a name are DIFFERENT outcomes and must not share one
    /// sentence: one is credited, the other is discarded (L11).
    func testAPlaceholderIsReportedAsDiscardedNotAsCredited() throws {
        let line = try XCTUnwrap(TagFieldNote.line(for: "unknown"))

        XCTAssertTrue(line.contains("unknown"), "got: \(line)")
        XCTAssertTrue(line.contains("ignored"), "got: \(line)")
        XCTAssertFalse(line.contains("credited by name"),
                       "a placeholder is credited nowhere, so saying it will be "
                       + "credited by name is a false promise")
    }

    func testANameAndAPlaceholderTogetherKeepTheirOwnOutcomes() throws {
        let line = try XCTUnwrap(TagFieldNote.line(for: "DPR Dance, unknown"))

        XCTAssertTrue(line.contains("DPR Dance"), "got: \(line)")
        XCTAssertTrue(line.contains("unknown"), "got: \(line)")
        XCTAssertTrue(line.contains("credited by name"), "got: \(line)")
        XCTAssertTrue(line.contains("ignored"), "got: \(line)")
    }

    /// The sentence must be derived from the same routing the value takes, or
    /// the two drift and the field promises an outcome that does not happen.
    func testTheSentenceAgreesWithWhereTheValueActuallyGoes() {
        for raw in ["dciny", "@asinger", "DPR Dance", "unknown", "n/a",
                    "instagram.com/someone", "a b c"] {
            let mentioned: Bool
            if case .mention = TypedCredit.read(raw) { mentioned = true } else { mentioned = false }
            let quiet = TagFieldNote.line(for: raw) == nil

            XCTAssertEqual(mentioned, quiet,
                           "\(raw) is \(mentioned ? "" : "not ")tagged but the "
                           + "field \(quiet ? "says nothing" : "reports it")")
        }
    }
}
