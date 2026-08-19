import XCTest

/// Line breaks do not survive in a field that is one line (#688).
///
/// `FieldText.normalized` trims the ENDS. A line break in the middle went
/// straight through, and a single line `TextField` renders it as a gap that
/// looks like a space, so nothing on screen said the value was broken.
///
/// Two routes let one in, and the second is the everyday one. The event form
/// takes a paste from a web page. The program review screen decodes what the
/// Python side read off the printed pages, where a long piece title or a
/// performer credited across two printed lines arrives as a two line value with
/// nobody involved.
///
/// It matters because these are keys and copy: the handle book keys on the
/// organisation, so a value with a newline in it is a permanently separate
/// entry whose saved handles never auto fill; the event name reaches folder
/// names and file names; and piece titles and composers reach captions and blog
/// posts that a stranger reads.
final class SingleLineFieldTests: XCTestCase {

    // MARK: - The rule itself

    func testEveryShapeOfLineBreakIsFolded() {
        for (what, raw) in [
            ("a unix newline", "Decoda\nEnsemble"),
            ("a windows newline", "Decoda\r\nEnsemble"),
            ("a bare carriage return", "Decoda\rEnsemble"),
            ("a unicode line separator", "Decoda\u{2028}Ensemble"),
            ("a unicode paragraph separator", "Decoda\u{2029}Ensemble"),
        ] {
            XCTAssertEqual(FieldText.singleLine(raw), "Decoda Ensemble", what)
        }
    }

    func testAWrappedTitleReadsAsOneLineRatherThanTwoWordsJammedTogether() {
        // The printed page case: a title that wrapped mid phrase. Deleting the
        // break rather than replacing it would give "SymphonyNo. 5".
        XCTAssertEqual(FieldText.singleLine("Symphony\nNo. 5"), "Symphony No. 5")
    }

    func testTheEndsAreStillTrimmed() {
        XCTAssertEqual(FieldText.singleLine("  Decoda\n"), "Decoda")
    }

    func testOrdinarySpacingIsUntouched() {
        // The control. A rule that collapsed everything would satisfy every
        // test above while quietly rewriting values that were always fine
        // (L159).
        XCTAssertEqual(FieldText.singleLine("Music From Inside"), "Music From Inside")
        XCTAssertEqual(FieldText.singleLine("Reverence & Resistance"),
                       "Reverence & Resistance")
    }

    func testRunsOfWhitespaceCollapseToOne() {
        XCTAssertEqual(FieldText.singleLine("Decoda \t Ensemble"), "Decoda Ensemble")
    }

    // MARK: - The consequence it was filed for

    func testAPastedTwoLineOrgKeysTheSameHandleBookEntryAsATypedOne() {
        // #491 fixed the trailing newline case this way and did not sweep the
        // interior one. The book keys on the normalised name, so an org holding
        // a line break is a different account entirely and its saved handles
        // never come back.
        XCTAssertEqual(FieldText.singleLine("Decoda\nEnsemble").lowercased(),
                       FieldText.singleLine("Decoda Ensemble").lowercased())
    }

    // MARK: - The program review payload

    /// Every string in this payload carries an interior line break, which is
    /// what a two line entry on a printed page produces.
    private let payload = """
    {
      "performers": [{"name": "Jenna\\nRobison", "role": "conductor\\nand pianist",
                      "voice_or_instrument": "mezzo\\nsoprano", "handle": "@jenna\\nrobison"}],
      "pieces": [{"composer": "Ludwig van\\nBeethoven", "title": "Symphony\\nNo. 5",
                  "movements": ["Allegro\\ncon brio"],
                  "notes": "First\\nperformed in 1808."}],
      "scenes": [{"name": "Act\\nOne", "location": "Stage\\nleft",
                  "visual_cues": "red\\nwash", "description": "The company\\nenters."}]
    }
    """

    private func decoded() throws -> OCRResult {
        try JSONDecoder().decode(OCRResult.self, from: Data(payload.utf8))
    }

    func testSingleLineFieldsComeBackAsOneLine() throws {
        let result = try decoded()
        let performer = try XCTUnwrap(result.performers.first)
        let piece = try XCTUnwrap(result.pieces.first)

        XCTAssertEqual(performer.name, "Jenna Robison")
        XCTAssertEqual(performer.role, "conductor and pianist")
        XCTAssertEqual(performer.voiceOrInstrument, "mezzo soprano")
        XCTAssertEqual(performer.handle, "@jenna robison")
        XCTAssertEqual(piece.composer, "Ludwig van Beethoven")
        XCTAssertEqual(piece.title, "Symphony No. 5")
        XCTAssertEqual(piece.movements, ["Allegro con brio"])
    }

    func testTheTwoFieldsThatAreProseKeepTheirLineBreaks() throws {
        // The test that stops the fix going too far, and it is why the rule is
        // per field rather than applied to the whole payload: notes is bound to
        // the multi line editor and a scene description is prose. A blanket
        // sweep would flatten both.
        let result = try decoded()

        XCTAssertEqual(try XCTUnwrap(result.pieces.first).notes,
                       "First\nperformed in 1808.",
                       "the multi line notes field was flattened")
        XCTAssertEqual(try XCTUnwrap(result.scenes.first).description,
                       "The company\nenters.",
                       "a scene's prose was flattened")
    }

    func testNoOtherSingleLineFieldQuietlyKeepsALineBreak() throws {
        // The completeness half (L113, L96). Reflecting over what was decoded
        // rather than listing the fields again means a field added next year is
        // covered the day it exists, instead of being exempt from the check
        // that was written for its siblings.
        let result = try decoded()
        let allowed: Set<String> = ["notes", "description"]

        func check(_ value: Any, in what: String) {
            for child in Mirror(reflecting: value).children {
                guard let label = child.label else { continue }
                let text: String?
                switch child.value {
                case let string as String: text = string
                case let strings as [String]: text = strings.joined(separator: " ")
                default: continue
                }
                guard let text, text.rangeOfCharacter(from: .newlines) != nil else {
                    continue
                }
                XCTAssertTrue(allowed.contains(label),
                              "\(what).\(label) still holds a line break, and it "
                              + "is not one of the two fields that are prose: "
                              + text.debugDescription)
            }
        }

        for performer in result.performers { check(performer, in: "Performer") }
        for piece in result.pieces { check(piece, in: "Piece") }
        for scene in result.scenes { check(scene, in: "ProgramScene") }
    }

    func testAValueStoredBeforeThisFixIsRepairedWhenItIsReadBack() throws {
        // Not only new payloads. Everything already in events.json comes back
        // through this same decoder, so a two line title stored last month is
        // folded the next time the event is opened rather than staying broken
        // forever with nothing able to reach it.
        let stored = try JSONEncoder().encode(
            OCRResult(pieces: [Piece(composer: "Ludwig van\nBeethoven",
                                     title: "Symphony\nNo. 5",
                                     notes: "First\nperformed in 1808.")]))

        let readBack = try JSONDecoder().decode(OCRResult.self, from: stored)

        XCTAssertEqual(readBack.pieces.first?.title, "Symphony No. 5")
        XCTAssertEqual(readBack.pieces.first?.notes, "First\nperformed in 1808.",
                       "the repair reached the prose field too")
    }

    func testTheProseFieldsAreReachedByThatSweepAtAll() throws {
        // The control for the sweep: if nothing in the payload came back with a
        // line break in it, the check above would pass having examined nothing
        // (L159, L98).
        let result = try decoded()
        XCTAssertTrue(try XCTUnwrap(result.pieces.first).notes
            .rangeOfCharacter(from: .newlines) != nil)
    }
}
