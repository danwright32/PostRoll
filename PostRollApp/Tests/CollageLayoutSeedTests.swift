import XCTest

/// #1028: what a collage with no stored seed actually does.
///
/// Three places disagreed about it. `Event.swift` said nil meant "random each
/// time". `generate_collage.py` is deterministic with no seed: it takes the
/// first fitting arrangement rather than drawing a fresh one, and its docstring
/// says so. And the review screen stamped a FRESH RANDOM seed on the first
/// rebuild of any collage day that had none.
///
/// Those add up to a real change nobody asked for. A collage day whose first
/// render came from the week generation was laid out by the deterministic
/// default; the first rebuild after that, for any reason at all, minted a
/// random seed and re-laid it out. Dan adjusts a crop and the arrangement
/// changes underneath him, once, for a reason he did nothing to cause.
///
/// It is the same defect #1062 settled for the Thursday reel, and it is settled
/// the same way: the layout is decided when the day's photographs are, by one
/// piece of behaviour that every path calls, so nil never reaches a render.
@MainActor
final class CollageLayoutSeedTests: XCTestCase {

    private func wednesday(seed: Int? = nil) -> PostingDay {
        var pd = PostingDay(day: .wednesday)
        pd.collageSeed = seed
        pd.photoPaths = (0..<4).map { URL(fileURLWithPath: "/tmp/collage-\($0).jpg") }
        return pd
    }

    func testADayWithNoSeedGetsOne() {
        var pd = wednesday()

        XCTAssertEqual(pd.ensureCollageSeed(using: { 4242 }), 4242)
        XCTAssertEqual(pd.collageSeed, 4242)
    }

    func testADayThatAlreadyHasOneKeepsIt() {
        /// The whole point. A seed that changed on any later call would put the
        /// arrangement back to changing under him, which is what this removes.
        var pd = wednesday(seed: 111)

        XCTAssertEqual(pd.ensureCollageSeed(using: { 4242 }), 111)
    }

    func testAskingForANewLayoutMintsAFreshOne() {
        var pd = wednesday(seed: 111)

        XCTAssertEqual(pd.ensureCollageSeed(fresh: true, using: { 4242 }), 4242)
    }

    func testANewLayoutDoesNotDependOnThereBeingOneToReplace() {
        var pd = wednesday()

        XCTAssertEqual(pd.ensureCollageSeed(fresh: true, using: { 4242 }), 4242)
    }

    /// The per-cell arrangement Dan adjusted by hand is keyed to the layout it
    /// was made against, so a fresh seed has to drop it. Keeping it would place
    /// cells from the old arrangement over the new one.
    func testAFreshLayoutDropsThePerCellOverride() {
        var pd = wednesday(seed: 111)
        pd.collageCellOverride = [CollageCell(photoPath: "/tmp/collage-0.jpg",
                                              x: 0, y: 0, w: 10, h: 10)]

        pd.ensureCollageSeed(fresh: true, using: { 4242 })

        XCTAssertNil(pd.collageCellOverride,
                     "the hand adjusted cells survived a reshuffle, so they "
                     + "describe an arrangement that no longer exists")
    }

    /// Minting one is NOT a reshuffle: a day that had no seed had no
    /// arrangement anybody adjusted either, and dropping an override here would
    /// be dropping one made against the deterministic default.
    func testMintingAFirstSeedKeepsAnOverride() {
        var pd = wednesday()
        let cells = [CollageCell(photoPath: "/tmp/collage-0.jpg",
                                 x: 0, y: 0, w: 10, h: 10)]
        pd.collageCellOverride = cells

        pd.ensureCollageSeed(using: { 4242 })

        XCTAssertEqual(pd.collageCellOverride, cells)
    }
}
