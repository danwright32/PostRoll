import XCTest

// MARK: - An import that was not saved may not be shown as a success (#439)
//
// The import summary was built from the in-memory merge alone, and it renders
// beside a green tick. Now that the app refuses to write over an analytics file
// it could not read, that made a real path where Dan imports a Meta export, sees
// "Imported 34 posts" in green, and finds them gone at next launch (L12).

final class ImportNoticeTests: XCTestCase {

    func testASavedImportReadsAsASuccess() {
        let notice = InsightsDisplay.importNotice(
            imported: 34, added: 5, updated: 29, warnings: 0, save: .saved)

        XCTAssertEqual(notice, .saved("Imported 34 posts (5 new, 29 updated)."))
    }

    func testWarningsAreCountedInTheSuccessLine() {
        let notice = InsightsDisplay.importNotice(
            imported: 34, added: 5, updated: 29, warnings: 2, save: .saved)

        guard case .saved(let text) = notice else { return XCTFail("\(notice)") }
        XCTAssertTrue(text.contains("2 warnings"), text)
    }

    func testOneWarningIsNotPluralised() {
        let notice = InsightsDisplay.importNotice(
            imported: 3, added: 3, updated: 0, warnings: 1, save: .saved)

        guard case .saved(let text) = notice else { return XCTFail("\(notice)") }
        XCTAssertTrue(text.contains("1 warning."), text)
    }

    func testARefusedSaveIsNotShownAsASuccess() {
        let notice = InsightsDisplay.importNotice(
            imported: 34, added: 5, updated: 29, warnings: 0, save: .blocked)

        guard case .notSaved(let text) = notice else {
            return XCTFail("a refused save reported as a success: \(notice)")
        }
        XCTAssertTrue(text.contains("nothing was saved"), text)
        XCTAssertTrue(text.contains("gone when you quit"),
                      "it has to say what happens next: \(text)")
    }

    func testAFailedSaveNamesTheReasonAndReadsAsOneSentence() {
        struct Stopped: LocalizedError {
            var errorDescription: String? { "The disk is full." }
        }
        struct Unstopped: LocalizedError {
            var errorDescription: String? { "input/output error" }
        }

        for error in [Stopped() as Error, Unstopped() as Error] {
            let notice = InsightsDisplay.importNotice(
                imported: 34, added: 5, updated: 29, warnings: 0,
                save: .failed(error.localizedDescription))

            guard case .notSaved(let text) = notice else {
                return XCTFail("a failed save reported as a success: \(notice)")
            }
            XCTAssertTrue(text.contains("could not be saved"), text)
            XCTAssertFalse(text.contains(".."), "double stop in: \(text)")
            XCTAssertFalse(text.contains(" ."), "orphaned stop in: \(text)")
        }
    }

    func testTheCountsStillReachTheReaderWhenTheSaveFailed() {
        // The import DID happen in this window, and saying so is not a claim
        // that it was kept. Dropping the numbers would leave Dan unable to tell
        // whether the CSV was even read.
        let notice = InsightsDisplay.importNotice(
            imported: 34, added: 5, updated: 29, warnings: 0, save: .blocked)

        guard case .notSaved(let text) = notice else { return XCTFail("\(notice)") }
        XCTAssertTrue(text.contains("34"), text)
        XCTAssertTrue(text.contains("5 new"), text)
    }
}
