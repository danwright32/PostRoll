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

// MARK: - The screen must not write its old copy over a finished rescan (#518)
//
// The review screen loads its working copy of the cast list once, at init, and
// is keyed on the event id, so it does not reload when the event's stored
// result changes. The rescan is the first thing that ever changes that result
// while the screen is open.
//
// Without this, a successful rescan saved the newly read pages, the screen went
// on showing the older draft (so the rescan looked like it did nothing), and the
// next keystroke persisted that stale draft back over the merge, discarding the
// pages just read and paid for. That is the exact loss the feature exists to
// prevent (L14, L17).

extension UnreadProgramPagesTests {

    private func draft(performers: [String]) -> OCRResult {
        var r = OCRResult()
        r.performers = performers.map { Performer(name: $0) }
        return r
    }

    func testTheScreenAdoptsWhatARescanMerged() {
        let onScreen = draft(performers: ["Ana"])
        let merged = draft(performers: ["Ana", "Bo"])

        XCTAssertTrue(OCRDraftRefresh.shouldAdopt(stored: merged, draft: onScreen,
                                                  isRunning: false),
                      "the screen would keep showing the pre-rescan list and then "
                      + "write it back over the merged one")
    }

    /// While the run is still going, the stored result is mid-flight and the
    /// draft must be left alone.
    func testNothingIsAdoptedWhileTheRescanIsStillRunning() {
        XCTAssertFalse(OCRDraftRefresh.shouldAdopt(stored: draft(performers: ["Ana", "Bo"]),
                                                   draft: draft(performers: ["Ana"]),
                                                   isRunning: true))
    }

    /// The ordinary case, every keystroke: the draft is already what is stored,
    /// so adopting would be a pointless write and a possible edit loop.
    func testNothingIsAdoptedWhenTheyAlreadyAgree() {
        let same = draft(performers: ["Ana"])
        XCTAssertFalse(OCRDraftRefresh.shouldAdopt(stored: same, draft: same,
                                                   isRunning: false))
    }

    /// An event with nothing stored must not blank the draft on screen.
    func testAnAbsentStoredResultNeverReplacesTheDraft() {
        XCTAssertFalse(OCRDraftRefresh.shouldAdopt(stored: nil,
                                                   draft: draft(performers: ["Ana"]),
                                                   isRunning: false))
    }
}

extension UnreadProgramPagesTests {

    /// Built is not wired (L3), and this rule existing while nothing calls it is
    /// precisely the defect it was written for. Comments stripped, because the
    /// file explains this in prose right beside the code (L103).
    func testTheReviewScreenAdoptsAndStopsPersistingDuringARescan() throws {
        let code = try source("Sources/Views/OCRReviewView.swift")

        XCTAssertTrue(code.contains("OCRDraftRefresh.shouldAdopt"),
                      "the screen never takes up what a rescan merged, so it will "
                      + "write its older list back over the newly read pages")
        XCTAssertTrue(code.contains("guard !ocrManager.isRunning(event.id) else { return }"),
                      "the draft is still persisted while a rescan is in flight, "
                      + "so an edit mid-run overwrites the merge that is landing")
    }
}

// MARK: - A denied folder is not a page that moved (#557)
//
// The refusal used to be decided by `FileManager.fileExists`, which answers
// false for a path the process is DENIED as well as for one that is absent. A
// macOS permissions refusal therefore reported the pages as gone and sent Dan
// to upload a programme that had never moved, while the one thing that would
// have fixed it, a settings change, went unmentioned (L11). The stores in this
// repo already refuse to use `fileExists` for exactly this reason; this brings
// the rescan's check into line with them.

extension UnreadProgramPagesTests {

    /// A directory whose permissions are stripped, so the page inside it is
    /// present on disk and unreadable by this process. Returns the page path.
    ///
    /// This is the real mechanism the bug reports wrongly: with the folder
    /// unsearchable, `fileExists` on the page answers false while the file is
    /// perfectly intact.
    private func pageInsideADeniedFolder() throws -> (page: String, cleanup: () -> Void) {
        try XCTSkipIf(getuid() == 0,
                      "root bypasses the permission this test depends on")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = dir.appendingPathComponent("page3.jpg")
        try Data("x".utf8).write(to: page)

        let cleanup = {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: dir.path)

        // The premise of the whole test, asserted rather than assumed: if the
        // platform stopped denying this, every case below would pass for the
        // wrong reason (L1).
        guard !FileManager.default.fileExists(atPath: page.path) else {
            cleanup()
            throw XCTSkip("this filesystem does not enforce directory permissions")
        }
        return (page.path, cleanup)
    }

    func testAPageInADeniedFolderIsSeenAsUnreadableRatherThanAbsent() throws {
        let (page, cleanup) = try pageInsideADeniedFolder()
        defer { cleanup() }

        XCTAssertEqual(OCRRescan.readability(ofPage: page), .denied,
                       "a page the process cannot read was classified as one that "
                       + "is no longer on disk")
    }

    func testAPageThatIsGenuinelyGoneIsSeenAsAbsent() {
        XCTAssertEqual(OCRRescan.readability(ofPage: "/nowhere/at/all/page3.jpg"),
                       .missing)
    }

    func testAReadablePageIsSeenAsReadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("page3.jpg")
        try Data("x".utf8).write(to: page)

        XCTAssertEqual(OCRRescan.readability(ofPage: page.path), .readable)
    }

    /// The defect as Dan met it: the message named the wrong cause and the wrong
    /// remedy.
    func testTheDeniedMessageDoesNotSayThePageMovedAndNamesTheRealFix() throws {
        let (page, cleanup) = try pageInsideADeniedFolder()
        defer { cleanup() }

        let refusal = try XCTUnwrap(OCRRescan.refusal(forPages: [page]))

        XCTAssertFalse(refusal.lowercased().contains("no longer where"),
                       "a permissions refusal still reads as a page that moved, so "
                       + "Dan is sent to re-upload work that was never lost: \(refusal)")
        XCTAssertFalse(refusal.lowercased().contains("upload the programme again"),
                       "the remedy offered cannot fix a permissions refusal: \(refusal)")
        XCTAssertTrue(refusal.contains("page3.jpg"), refusal)
        XCTAssertTrue(refusal.lowercased().contains("privacy & security"),
                      "the one thing that would fix this is not named: \(refusal)")
    }

    /// The absent case must keep its own message, or the fix has merely moved
    /// the wrong diagnosis onto the other cause.
    func testTheAbsentMessageStillSaysThePageMovedAndSaysToUploadAgain() throws {
        let refusal = try XCTUnwrap(
            OCRRescan.refusal(forPages: ["/nowhere/at/all/page3.jpg"]))

        XCTAssertTrue(refusal.lowercased().contains("no longer where"), refusal)
        XCTAssertTrue(refusal.lowercased().contains("upload the programme again"),
                      refusal)
        XCTAssertFalse(refusal.lowercased().contains("privacy & security"),
                       "a page that really is gone must not send Dan to settings: "
                       + "\(refusal)")
    }

    /// A gap can hold both at once, and a message that reports only one of them
    /// leaves the other page silently unaccounted for.
    func testAGapHoldingBothCausesReportsBoth() throws {
        let (denied, cleanup) = try pageInsideADeniedFolder()
        defer { cleanup() }

        let refusal = try XCTUnwrap(
            OCRRescan.refusal(forPages: [denied, "/nowhere/at/all/page9.jpg"]))

        XCTAssertTrue(refusal.contains("page3.jpg"), refusal)
        XCTAssertTrue(refusal.contains("page9.jpg"), refusal)
        XCTAssertTrue(refusal.lowercased().contains("privacy & security"), refusal)
        XCTAssertTrue(refusal.lowercased().contains("upload the programme again"),
                      refusal)
    }

    /// A page that opens for some third reason neither remedy covers must not
    /// be filed under either of them. This one is worded through the same
    /// message builder the app uses, because a disk that produces an arbitrary
    /// open failure on demand cannot be arranged in a unit test.
    func testAnUnexplainedFailureClaimsNeitherRemedy() throws {
        let refusal = try XCTUnwrap(OCRRescan.message(
            for: [("/x/page3.jpg", .unreadable("Too many open files"))]))

        XCTAssertTrue(refusal.contains("page3.jpg"), refusal)
        XCTAssertTrue(refusal.contains("Too many open files"),
                      "the message does not say what actually happened: \(refusal)")
        XCTAssertFalse(refusal.lowercased().contains("upload the programme again"),
                       refusal)
        XCTAssertFalse(refusal.lowercased().contains("privacy & security"), refusal)
    }

    /// Every page readable is the ordinary case, and it must leave the control
    /// live rather than refusing with an empty sentence.
    func testNothingIsRefusedWhenEveryPageOpens() {
        XCTAssertNil(OCRRescan.message(for: [("/x/page3.jpg", .readable),
                                             ("/x/page4.jpg", .readable)]))
    }

    /// Built is not wired (L3). The classification has to be what the shipped
    /// refusal is decided by, and `fileExists` must be gone from this file, or
    /// the old answer is still reachable. Comments stripped, because the file
    /// explains the ban in prose right beside the code (L103).
    func testTheRefusalNoLongerDecidesWithFileExists() throws {
        let code = try source("Sources/Services/OCRRescan.swift")

        XCTAssertFalse(code.contains("fileExists"),
                       "the check that cannot tell a denied folder from a missing "
                       + "page is still deciding the refusal")
    }
}
