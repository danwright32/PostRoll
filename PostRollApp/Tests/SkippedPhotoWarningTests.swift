import XCTest

/// #228: a photo skipped because it could not be read has to reach Dan.
///
/// The day still generates, from the photos that were fine, which is the whole
/// point. That makes the skip invisible unless it is reported: the captions
/// look complete, and the only trace is one alt text that is blank. A silent
/// degradation is what #215 was written to stop, so carrying on is only
/// allowed while the reason is on screen.
///
/// Warnings are a separate channel from errors on purpose. A day with a
/// skipped photo generated and is usable; filing it under `errors` would
/// either make a good day look broken or hide a real failure behind it.
final class SkippedPhotoWarningTests: XCTestCase {

    private func decode(_ json: String) throws -> WeekGenerationResult {
        try JSONDecoder().decode(WeekGenerationResult.self, from: Data(json.utf8))
    }

    func testASkippedPhotoIsDecodedFromThePythonOutput() throws {
        let result = try decode("""
        {"wednesday": {"caption": "A caption.", "alt_texts": ["one", "", "three"]},
         "errors": {},
         "warnings": {"wednesday": [{"file": "DSC_4471.jpg", "reason": "Truncated File Read"}]}}
        """)

        XCTAssertEqual(result.warnings["wednesday"]?.count, 1)
        XCTAssertEqual(result.warnings["wednesday"]?.first?.file, "DSC_4471.jpg")
    }

    func testTheWarningNamesTheFileAndSaysWhatHappened() throws {
        // "A photo was skipped" gives him nowhere to go. The file name is the
        // whole value of the message.
        let result = try decode("""
        {"errors": {},
         "warnings": {"wednesday": [{"file": "DSC_4471.jpg", "reason": "Truncated File Read"}]}}
        """)

        let message = result.warningMessage(for: .wednesday)
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("DSC_4471.jpg"), "got: \(message ?? "nil")")
    }

    func testADayWithNoWarningsHasNoMessage() throws {
        // Guards against a banner that shows on every ordinary day, which is
        // how a real warning gets ignored.
        let result = try decode("""
        {"wednesday": {"caption": "A caption."}, "errors": {}, "warnings": {}}
        """)

        XCTAssertNil(result.warningMessage(for: .wednesday))
    }

    func testSeveralSkippedPhotosAreAllNamed() throws {
        let result = try decode("""
        {"errors": {},
         "warnings": {"sunday": [{"file": "a.jpg", "reason": "x"},
                                 {"file": "b.jpg", "reason": "y"}]}}
        """)

        let message = result.warningMessage(for: .sunday)
        XCTAssertTrue(message?.contains("a.jpg") == true)
        XCTAssertTrue(message?.contains("b.jpg") == true)
    }

    func testAWarningIsNotCountedAsAnError() throws {
        // A day that generated must not read as failed, or Dan regenerates a
        // day that was fine and pays for it again.
        let result = try decode("""
        {"wednesday": {"caption": "A caption."},
         "errors": {},
         "warnings": {"wednesday": [{"file": "a.jpg", "reason": "x"}]}}
        """)

        XCTAssertEqual(result.errorCount, 0)
        XCTAssertNotNil(result.wednesday, "the day still has its caption")
    }

    func testOlderSavesWithNoWarningsKeyStillDecode() throws {
        // Every persisted Codable field decodes with decodeIfPresent, or the
        // next launch wipes saved work.
        let result = try decode("""
        {"wednesday": {"caption": "A caption."}, "errors": {}}
        """)

        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertNil(result.warningMessage(for: .wednesday))
    }
}
