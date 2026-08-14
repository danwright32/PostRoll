import XCTest

/// #518: a scan that could not read some pages says WHICH.
///
/// A large programme is read in several paid calls. After #479 a call that
/// fails no longer takes the rest with it, so the run finishes and keeps
/// everything it read. Which pages it lost lived only in a log line, and the
/// screen said nothing at all: the cast list was short by whatever those pages
/// held and the read looked clean.
final class UnreadProgramPagesTests: XCTestCase {

    func testAResultThatReadEverythingSaysNothing() {
        XCTAssertNil(OCRManager.unreadPagesNote([]),
                     "a clean read must not leave a warning on the screen, or a "
                     + "real one stops being read")
    }

    func testItNamesTheOnePageItCouldNotRead() {
        let note = OCRManager.unreadPagesNote(["/photos/programme/page4.jpg"])

        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("page4.jpg"), note!)
        XCTAssertFalse(note!.contains("/photos/"),
                       "the whole path is not what Dan calls that page: \(note!)")
    }

    func testItNamesEveryPageRatherThanACount() {
        let note = OCRManager.unreadPagesNote(["/x/page2.jpg", "/x/page7.jpg"])!

        XCTAssertTrue(note.contains("page2.jpg"), note)
        XCTAssertTrue(note.contains("page7.jpg"), note)
    }

    func testItSaysWhatIsStillThere() {
        // A message that only names what is missing reads as "this scan
        // failed", and the rest of the programme really was read and paid for.
        let note = OCRManager.unreadPagesNote(["/x/page2.jpg"])!
        XCTAssertTrue(note.lowercased().contains("everything else"), note)
    }

    func testItSaysWhatToDoAboutIt() {
        let note = OCRManager.unreadPagesNote(["/x/page2.jpg"])!
        XCTAssertTrue(note.lowercased().contains("scan again"), note)
    }

    // MARK: - the field it reads

    func testTheResultCarriesThePagesPythonNamed() throws {
        let json = """
        {"performers": [], "unread_pages": ["/x/page3.jpg"]}
        """
        let result = try JSONDecoder().decode(OCRResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.unreadPages, ["/x/page3.jpg"])
    }

    func testAStoredResultFromBeforeThisFieldExistedStillDecodes() throws {
        // events.json holds results written before the field existed, and a
        // decode that throws here wipes every saved event on the next launch.
        let json = """
        {"performers": [], "program_notes": "hello"}
        """
        let result = try JSONDecoder().decode(OCRResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.unreadPages, [])
        XCTAssertEqual(result.programNotes, "hello")
    }
}
