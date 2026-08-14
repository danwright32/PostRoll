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

// MARK: - Rescanning just the pages that went unread (#518)

extension UnreadProgramPagesTests {

    /// The control only makes sense when there is a gap to close, and offering
    /// it on a clean read would be a button that does nothing.
    func testTheRescanIsOfferedOnlyWhenPagesWentUnread() {
        var clean = OCRResult()
        clean.unreadPages = []
        XCTAssertNil(OCRRescan.pages(for: clean))

        var partial = OCRResult()
        partial.unreadPages = ["/x/page3.jpg"]
        XCTAssertEqual(OCRRescan.pages(for: partial), ["/x/page3.jpg"])
    }

    /// The pages sent must be exactly the ones the earlier run named, because
    /// the merge that folds the answer back in matches on those same strings.
    /// Sending a basename, or the whole programme, breaks the match silently.
    func testItSendsTheExactPathsTheEarlierRunNamed() {
        var partial = OCRResult()
        partial.unreadPages = ["/photos/programme/page3.jpg",
                               "/photos/programme/page4.jpg"]

        XCTAssertEqual(OCRRescan.pages(for: partial),
                       ["/photos/programme/page3.jpg",
                        "/photos/programme/page4.jpg"])
    }

    /// A page named in the gap that is no longer on disk cannot be rescanned,
    /// and saying so beats sending a path Python will fail on (L67).
    func testItRefusesWhenAPageInTheGapIsGone() {
        let missing = "/nowhere/at/all/page3.jpg"
        XCTAssertNotNil(OCRRescan.refusal(forPages: [missing]))
    }

    func testItDoesNotRefuseWhenEveryPageIsStillThere() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("page3.jpg")
        try Data("x".utf8).write(to: page)

        XCTAssertNil(OCRRescan.refusal(forPages: [page.path]))
    }

    /// What the button says. It has to name the work, because "Scan again" beside
    /// a warning about three pages reads as re-running the whole programme, which
    /// is the paid thing this exists to avoid.
    func testTheControlSaysItIsOnlyScanningTheMissingPages() {
        let one = OCRRescan.buttonTitle(pageCount: 1)
        let many = OCRRescan.buttonTitle(pageCount: 3)

        XCTAssertTrue(one.lowercased().contains("1 page"), one)
        XCTAssertTrue(many.lowercased().contains("3 pages"), many)
        XCTAssertFalse(one.lowercased().contains("whole"), one)
    }
}

// MARK: - That the screen and the manager actually use it

extension UnreadProgramPagesTests {

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .appendingPathComponent(relative)
        return SwiftSourceText.withoutComments(
            try String(contentsOf: url, encoding: .utf8))
    }

    /// Built is not wired (L3). Comments are stripped first, because these files
    /// carry prose naming these very symbols and a guard satisfied by an
    /// explanation is indistinguishable from one satisfied by the code (L103).
    func testTheReviewScreenOffersTheRescan() throws {
        let code = try source("Sources/Views/OCRReviewView.swift")
        XCTAssertTrue(code.contains("OCRRescan.pages"),
                      "the screen does not decide with the shared rule")
        XCTAssertTrue(code.contains("startRescanOfUnreadPages"),
                      "the control is not wired to anything that scans")
    }

    /// The rescan must carry the stored result to merge into. Without it Python
    /// replaces the programme with whatever these few pages hold, which is the
    /// paid work the feature exists to protect.
    func testTheRescanCarriesTheStoredResultToMergeInto() throws {
        let code = try source("Sources/Services/OCRManager.swift")
        XCTAssertTrue(code.contains("mergeInto: rescan?.previous"),
                      "the rescan does not hand over the result to merge into, "
                      + "so it would replace it instead of adding to it")
    }
}
