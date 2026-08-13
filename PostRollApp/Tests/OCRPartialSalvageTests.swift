import XCTest

/// #479: a large programme's OCR writes each batch to disk as it finishes, and
/// something has to read that file when the run dies.
///
/// Each batch is a 600s paid call. Python now persists the merge after every
/// one, so a stop partway (an exception, or the app's 1800s watchdog SIGTERM)
/// leaves the pages already read where they can be found. Without a reader on
/// this side that write protects nothing: the bridge throws on a non-zero exit
/// and never opens the file, the app reports a failed run, and the retry pays
/// for those pages again (L46).
///
/// A salvaged read is never presented as a finished one. Half a cast list that
/// looks complete is worse than a failure, because nothing on screen tells Dan
/// to check the rest against the printed programme.
final class OCRPartialSalvageTests: XCTestCase {

    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-partial-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    // MARK: - what counts as worth salvaging

    func testAPartialWithPerformersIsSalvaged() throws {
        let url = try write("""
        {"performers": [{"name": "A Singer", "role": "Soprano",
                         "voice_or_instrument": "Soprano", "handle": ""}],
         "pieces": [], "scenes": []}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let salvaged = PythonBridge.salvagedOCR(at: url)

        XCTAssertEqual(salvaged?.performers.count, 1)
    }

    func testAPartialWithOnlyPiecesIsStillWorthKeeping() throws {
        // A programme whose first pages are the repertoire and whose cast list
        // is on a page that failed. The pieces are real work, already paid for.
        let url = try write("""
        {"performers": [], "pieces": [{"composer": "Mahler", "title": "No. 2"}],
         "scenes": []}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(PythonBridge.salvagedOCR(at: url)?.pieces.count, 1)
    }

    func testAPartialWithOnlyProseIsStillWorthKeeping() throws {
        let url = try write("""
        {"performers": [], "pieces": [], "scenes": [],
         "program_notes": "Mahler composed the Resurrection over six years."}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNotNil(PythonBridge.salvagedOCR(at: url))
    }

    // MARK: - what is not

    func testAnEmptyPartialIsNotSalvaged() throws {
        // Nothing was read, so there is nothing to offer, and offering an empty
        // programme as a partial result would read as a programme with nothing
        // in it.
        let url = try write(#"{"performers": [], "pieces": [], "scenes": []}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(PythonBridge.salvagedOCR(at: url))
    }

    func testAMissingFileIsNotSalvaged() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-written-\(UUID().uuidString).json")

        XCTAssertNil(PythonBridge.salvagedOCR(at: url))
    }

    func testATruncatedFileIsNotSalvaged() throws {
        // A kill mid-write is exactly what the atomic rename on the Python side
        // exists to prevent, but a file that does not parse must never be
        // presented as a partial read.
        let url = try write(#"{"performers": [{"name": "A Sin"#)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(PythonBridge.salvagedOCR(at: url))
    }

    // MARK: - it is never mistaken for a finished run

    func testThePartialErrorCarriesBothTheDataAndTheReason() {
        var result = OCRResult()
        result.performers = [Performer(id: UUID(), name: "A Singer", role: "Soprano",
                                       voiceOrInstrument: "Soprano", handle: "")]

        let error = PythonBridgeError.partialOCR(result, reason: "the run was stopped")

        guard case .partialOCR(let carried, let reason) = error else {
            return XCTFail("the salvaged programme did not survive the error")
        }
        XCTAssertEqual(carried.performers.count, 1)
        XCTAssertEqual(reason, "the run was stopped")
    }

    func testThePartialMessageTellsDanItIsIncomplete() {
        let error = PythonBridgeError.partialOCR(OCRResult(), reason: "stopped")
        let message = error.errorDescription ?? ""

        XCTAssertTrue(message.lowercased().contains("part"),
                      "a partial read presented as a finished one is worse than "
                      + "a failure: \(message)")
        XCTAssertTrue(message.contains("stopped"), message)
    }
}
