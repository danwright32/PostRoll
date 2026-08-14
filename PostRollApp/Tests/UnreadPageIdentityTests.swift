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

    // MARK: - What gets sent

    /// All the positions or none of them. A rescan that numbered some of its
    /// pages and not others would hand Python a numbering it has to pad, and a
    /// padded position matches whatever else could not be placed.
    func testPositionsAreSentOnlyWhenEveryPageHasOne() {
        let all = [OCRRescan.Page(number: 1, path: "/new/p1.jpg"),
                   OCRRescan.Page(number: 3, path: "/new/p3.jpg")]
        let some = [OCRRescan.Page(number: 1, path: "/new/p1.jpg"),
                    OCRRescan.Page(number: nil, path: "/old/appendix.jpg")]

        XCTAssertEqual(OCRRescan.pageNumbers(of: all), [1, 3])
        XCTAssertNil(OCRRescan.pageNumbers(of: some),
                     "a partial numbering was sent, which Python has to pad")
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
