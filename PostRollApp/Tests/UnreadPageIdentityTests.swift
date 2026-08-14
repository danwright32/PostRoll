import XCTest

/// #558: the recorded gap has to survive the programme images being moved.
///
/// `unread_pages` named the pages an earlier run could not read by their full
/// file paths, and the rescan matched on those same strings. That holds only
/// while nothing moves the images, and this app does move them: `rebasePaths`
/// exists for exactly that.
///
/// Once they move, the stored gap names paths nothing can find. Every page in
/// it reads as missing, the control refuses with "upload the programme again",
/// and the only way back is paying for every page a second time, which is the
/// cost the feature exists to avoid. Nothing reports it as a defect: it looks
/// like an ordinary refusal (L15).
///
/// So the identity is the page's position in the uploaded programme, resolved
/// against the programme as it is NOW. The stored paths are still read, because
/// every gap recorded before this has nothing else, and they are placed against
/// the current programme rather than trusted.
final class UnreadPageIdentityTests: XCTestCase {

    private func programme(_ names: [String], in folder: String) -> [URL] {
        names.map { URL(fileURLWithPath: "\(folder)/\($0)") }
    }

    private func result(unread: [String], numbers: [Int] = []) -> OCRResult {
        var out = OCRResult()
        out.unreadPages = unread
        out.unreadPageNumbers = numbers
        return out
    }

    private let live = ["p1.jpg", "p2.jpg", "p3.jpg"]

    // MARK: - Keyed on position

    func testAGapKeyedOnPositionFollowsThePagesToWhereTheyAreNow() {
        let stored = result(unread: ["/old/place/p3.jpg"], numbers: [3])

        let pages = OCRRescan.pages(for: stored, in: programme(live, in: "/new/place"))

        XCTAssertEqual(pages, [OCRRescan.Page(number: 3, path: "/new/place/p3.jpg")])
    }

    func testEveryPageInTheGapIsResolved() {
        let stored = result(unread: ["/old/p1.jpg", "/old/p3.jpg"], numbers: [1, 3])

        let pages = OCRRescan.pages(for: stored, in: programme(live, in: "/new"))

        XCTAssertEqual(pages?.map(\.path), ["/new/p1.jpg", "/new/p3.jpg"])
    }

    /// The programme was re-uploaded shorter, so page 3 is not there any more.
    /// Inventing a page to send would spend money reading the wrong one.
    func testAPositionTheProgrammeNoLongerHasFallsBackToWhatWasStored() {
        let stored = result(unread: ["/old/p3.jpg"], numbers: [3])

        let pages = OCRRescan.pages(for: stored,
                                    in: programme(["p1.jpg"], in: "/new"))

        XCTAssertEqual(pages, [OCRRescan.Page(number: nil, path: "/old/p3.jpg")])
    }

    /// Paired by index or not paired at all: one page's number against another
    /// page's path is worse than no numbers (L83).
    func testListsOfDifferentLengthsAreNotPairedUp() {
        let stored = result(unread: ["/new/p2.jpg", "/new/p3.jpg"], numbers: [2])

        let pages = OCRRescan.pages(for: stored, in: programme(live, in: "/new"))

        XCTAssertEqual(pages?.map(\.number), [2, 3],
                       "the mismatched numbering was used instead of being ignored")
    }

    // MARK: - Gaps recorded before any of this existed

    func testAStoredPathIsPlacedAgainstTheProgrammeAsItIsNow() {
        let stored = result(unread: ["/old/place/p3.jpg"])

        let pages = OCRRescan.pages(for: stored, in: programme(live, in: "/new/place"))

        XCTAssertEqual(pages, [OCRRescan.Page(number: 3, path: "/new/place/p3.jpg")],
                       "a gap stored before #558 stayed pinned to a path nothing can find")
    }

    func testAStoredPathThatStillExistsIsLeftAlone() {
        let stored = result(unread: ["/new/p2.jpg"])

        let pages = OCRRescan.pages(for: stored, in: programme(live, in: "/new"))

        XCTAssertEqual(pages, [OCRRescan.Page(number: 2, path: "/new/p2.jpg")])
    }

    /// Nothing in the programme matches, so there is nothing to correct it to.
    /// It keeps what was stored and goes on to be refused as missing, which is
    /// the honest answer rather than a guess.
    func testAStoredPathMatchingNothingKeepsWhatWasStored() {
        let stored = result(unread: ["/old/appendix.jpg"])

        let pages = OCRRescan.pages(for: stored, in: programme(live, in: "/new"))

        XCTAssertEqual(pages, [OCRRescan.Page(number: nil, path: "/old/appendix.jpg")])
    }

    func testACleanRunOffersNothingToRescan() {
        XCTAssertNil(OCRRescan.pages(for: result(unread: []),
                                     in: programme(live, in: "/new")))
    }

    func testAnEmptyProgrammeStillReportsTheGapItWasGiven() {
        let stored = result(unread: ["/old/p3.jpg"], numbers: [3])

        XCTAssertEqual(OCRRescan.pages(for: stored, in: []),
                       [OCRRescan.Page(number: nil, path: "/old/p3.jpg")])
    }

    // MARK: - What gets sent (#575)
    //
    // A page nothing can place used to cost the WHOLE batch its positions: the
    // numbering was sent only when every page had one, so a single unplaceable
    // page dropped the lot and the rescan fell back to matching on file paths
    // for pages whose position was known perfectly well. That is the exact
    // matching #558 replaced, switched off for the good pages by one odd one
    // (L93). The plan now sends only the pages it can place and leaves the rest
    // in the gap, said out loud rather than dropped.

    /// Real pages on disk, because the plan decides its refusal by opening the
    /// pages it is about to send. Paths, in the order asked for.
    private func pagesOnDisk(_ names: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try names.map { name in
            let page = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: page)
            return page.path
        }
    }

    /// The defect, stated as a test.
    func testAPageThatCannotBePlacedDoesNotCostTheOthersTheirPositions() throws {
        let disk = try pagesOnDisk(["p1.jpg", "p3.jpg"])

        let plan = OCRRescan.plan(for: [
            OCRRescan.Page(number: 1, path: disk[0]),
            OCRRescan.Page(number: nil, path: "/old/appendix.jpg"),
            OCRRescan.Page(number: 3, path: disk[1]),
        ])

        XCTAssertEqual(plan.sendable,
                       [OCRRescan.PlacedPage(number: 1, path: disk[0]),
                        OCRRescan.PlacedPage(number: 3, path: disk[1])],
                       "the pages that were placed lost their positions to the "
                       + "one that was not, so the merge falls back to matching "
                       + "on paths for pages it could have matched on position")
        XCTAssertNil(plan.refusal,
                     "one unplaceable page stopped the pages that can be read")
    }

    /// The pages that cannot be placed stay in the gap, and the run says so.
    /// Dropping them from what is sent without a word would leave them listed
    /// as unread forever with nothing on screen explaining why a rescan keeps
    /// not reading them (L11, L98).
    func testThePagesLeftBehindAreNamedRatherThanSilentlySkipped() throws {
        let disk = try pagesOnDisk(["p1.jpg"])

        let plan = OCRRescan.plan(for: [
            OCRRescan.Page(number: 1, path: disk[0]),
            OCRRescan.Page(number: nil, path: "/old/appendix.jpg"),
        ])

        XCTAssertEqual(plan.unplaceable,
                       [OCRRescan.Page(number: nil, path: "/old/appendix.jpg")])
        let note = try XCTUnwrap(plan.note,
                                 "a page was quietly left out of the rescan")
        XCTAssertTrue(note.contains("appendix.jpg"), note)
        XCTAssertFalse(note.contains("/old/"),
                       "the whole path is not what Dan calls that page: \(note)")
        XCTAssertFalse(note.contains("p1.jpg"),
                       "the page that IS being read is named as one that is not: \(note)")
    }

    /// The ordinary gap: every page placed and readable. No note, because a
    /// notice that appears when nothing is wrong stops being read.
    func testAGapEveryPageOfWhichCanBePlacedRunsWithNothingToReport() throws {
        let disk = try pagesOnDisk(["p1.jpg", "p3.jpg"])

        let plan = OCRRescan.plan(for: [OCRRescan.Page(number: 1, path: disk[0]),
                                        OCRRescan.Page(number: 3, path: disk[1])])

        XCTAssertEqual(plan.sendable.map(\.number), [1, 3])
        XCTAssertNil(plan.refusal)
        XCTAssertNil(plan.note)
        XCTAssertEqual(plan.unplaceable, [])
    }

    /// Nothing to send is a refusal, not a run of zero pages. A button offered
    /// on a gap none of which can be placed would spend a paid call reading
    /// nothing, or worse, read pages the merge cannot key back to the gap.
    func testAGapNoPageOfWhichCanBePlacedRefusesInsteadOfRunning() throws {
        let plan = OCRRescan.plan(for: [
            OCRRescan.Page(number: nil, path: "/old/appendix.jpg"),
        ])

        XCTAssertEqual(plan.sendable, [])
        let refusal = try XCTUnwrap(plan.refusal)
        XCTAssertTrue(refusal.contains("appendix.jpg"), refusal)
        XCTAssertNil(plan.note,
                     "the same pages are reported twice, once as a refusal and "
                     + "once as a note")
    }

    /// A refusal means nothing is sent. Leaving pages in `sendable` beside a
    /// refusal would let a caller that checks one and not the other pay for a
    /// run the rule had already refused.
    func testARefusalLeavesNothingToSend() throws {
        let plan = OCRRescan.plan(for: [
            OCRRescan.Page(number: 1, path: "/nowhere/at/all/p1.jpg"),
            OCRRescan.Page(number: 3, path: "/nowhere/at/all/p3.jpg"),
        ])

        XCTAssertNotNil(plan.refusal)
        XCTAssertEqual(plan.sendable, [])
    }

    /// A gap can hold both faults at once, and a refusal reporting only one
    /// leaves the other pages unaccounted for while naming a remedy that cannot
    /// fix them (the rule this file's message builder already follows).
    func testARefusedRunStillAccountsForThePagesItCouldNotPlace() throws {
        let plan = OCRRescan.plan(for: [
            OCRRescan.Page(number: 1, path: "/nowhere/at/all/p1.jpg"),
            OCRRescan.Page(number: nil, path: "/old/appendix.jpg"),
        ])

        let refusal = try XCTUnwrap(plan.refusal)
        XCTAssertTrue(refusal.contains("p1.jpg"), refusal)
        XCTAssertTrue(refusal.contains("appendix.jpg"),
                      "the page nothing could place went unmentioned: \(refusal)")
    }

    /// The two causes are different faults with different remedies, so they must
    /// not be worded as each other (L11). A page that cannot be placed is not a
    /// page that moved: it is still where it was, and the programme is what
    /// changed.
    func testAPageThatCannotBePlacedIsNotReportedAsOneThatMoved() throws {
        let plan = OCRRescan.plan(for: [
            OCRRescan.Page(number: nil, path: "/old/appendix.jpg"),
        ])
        let refusal = try XCTUnwrap(plan.refusal)

        XCTAssertFalse(refusal.lowercased().contains("permissions problem"), refusal)
        XCTAssertTrue(refusal.lowercased().contains("programme"), refusal)
    }

    /// Read cold, in the state that produces it (L21). One page is the common
    /// case and the sentence has to agree with itself about how many there are.
    func testTheUnplaceableSentenceAgreesWithItselfAboutOnePage() throws {
        let one = try XCTUnwrap(OCRRescan.plan(for: [
            OCRRescan.Page(number: nil, path: "/old/appendix.jpg")]).refusal)
        let many = try XCTUnwrap(OCRRescan.plan(for: [
            OCRRescan.Page(number: nil, path: "/old/appendix.jpg"),
            OCRRescan.Page(number: nil, path: "/old/insert.jpg")]).refusal)

        XCTAssertFalse(one.contains("they"), one)
        XCTAssertFalse(one.contains("them"), one)
        XCTAssertFalse(one.contains("These pages"), one)
        XCTAssertTrue(many.contains("insert.jpg"), many)
    }

    /// The button names the amount of work, and after this it must name what
    /// will ACTUALLY be read rather than the size of the gap, or it promises to
    /// read a page it is about to leave behind (L21, L118).
    func testTheControlCountsOnlyThePagesThatWillBeRead() throws {
        let disk = try pagesOnDisk(["p1.jpg"])

        let plan = OCRRescan.plan(for: [
            OCRRescan.Page(number: 1, path: disk[0]),
            OCRRescan.Page(number: nil, path: "/old/appendix.jpg"),
        ])
        let title = OCRRescan.buttonTitle(pageCount: plan.sendable.count)

        XCTAssertTrue(title.lowercased().contains("1 page"), title)
    }

    // MARK: - The stored field survives a round trip

    func testThePositionsArePersistedAndReadBack() throws {
        let stored = result(unread: ["/new/p3.jpg"], numbers: [3])

        let data = try JSONEncoder().encode(stored)
        let back = try JSONDecoder().decode(OCRResult.self, from: data)

        XCTAssertEqual(back.unreadPageNumbers, [3])
    }

    func testAResultSavedBeforeThisFieldExistedStillDecodes() throws {
        let json = Data(#"{"performers":[],"unread_pages":["/old/p3.jpg"]}"#.utf8)

        let back = try JSONDecoder().decode(OCRResult.self, from: json)

        XCTAssertEqual(back.unreadPages, ["/old/p3.jpg"])
        XCTAssertEqual(back.unreadPageNumbers, [])
    }
}
