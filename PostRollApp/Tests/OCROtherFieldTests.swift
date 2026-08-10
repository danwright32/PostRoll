import XCTest

/// #262: the programme's "other" text reaches the blog prompt.
///
/// OCR asks Claude for `other` on every programme (sponsor notes, dedications,
/// audience instructions) and `ocr_program.py` returns it. `OCRResult` had no
/// field for it, so it was dropped the moment it crossed into Swift, and
/// `generate_blog.py`'s prompt slot for `other` rendered "(none)" on every
/// event that has ever been generated. Paid for every time, used never.
///
/// The manifest is built by serialising OCRResult, so the field reaching the
/// prompt and the field surviving a save are the same fact.
final class OCROtherFieldTests: XCTestCase {

    func testTheProgramManifestCarriesOtherThroughToPython() throws {
        var ocr = OCRResult()
        ocr.performers = [Performer(id: UUID(), name: "A", role: "", voiceOrInstrument: "", handle: "")]
        ocr.other = "Sponsored by the Hartwell Foundation. Please silence phones."

        let data = try JSONEncoder().encode(ocr)
        let dict = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["other"] as? String,
                       "Sponsored by the Hartwell Foundation. Please silence phones.",
                       "generate_blog.py reads program[\"other\"]; without this key "
                       + "in the manifest its prompt slot renders \"(none)\" forever")
    }

    func testItUsesPythonsKeyNameNotSwiftsPropertyName() throws {
        // A snake_case mismatch here is silent: the prompt slot just stays
        // empty, exactly as it did before this field existed.
        var ocr = OCRResult()
        ocr.other = "x"
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(ocr)) as? [String: Any])
        XCTAssertNotNil(dict["other"])
    }

    func testItDecodesWhatPythonWrites() throws {
        let json = #"{"performers": [], "pieces": [], "scenes": [], "other": "Dedicated to M.R."}"#
        let ocr = try JSONDecoder().decode(OCRResult.self, from: Data(json.utf8))
        XCTAssertEqual(ocr.other, "Dedicated to M.R.")
    }

    func testAProgramSavedBeforeThisFieldExistedStillDecodes() throws {
        // Persisted inside events.json. A field that cannot tolerate its own
        // absence wipes every saved event on the first launch after the upgrade.
        let json = #"{"performers": [], "pieces": [], "scenes": []}"#
        let ocr = try JSONDecoder().decode(OCRResult.self, from: Data(json.utf8))
        XCTAssertEqual(ocr.other, "")
    }

    func testAnEmptyOtherRoundTripsAsEmptyRatherThanMissing() throws {
        // Python sends "" when the programme had nothing extra, and that has to
        // survive as "" so the review screen shows an empty box rather than
        // treating the field as unavailable.
        var ocr = OCRResult()
        ocr.other = ""
        let back = try JSONDecoder().decode(
            OCRResult.self, from: try JSONEncoder().encode(ocr))
        XCTAssertEqual(back.other, "")
    }
}
