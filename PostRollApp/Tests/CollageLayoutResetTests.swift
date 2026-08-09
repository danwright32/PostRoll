import XCTest

/// #161: once a collage day had a saved cell override, `generate_collage` took
/// the override branch and rendered at the stored coordinates forever. There
/// was no way back to the automatic layout.
///
/// That became visible after the gallery-mat change: any day with a saved
/// override kept the old edge-to-edge geometry with no cream mat and could not
/// opt in to the new design at all.
///
/// Keeping a manual arrangement by default is right. It needed an escape hatch.
final class CollageLayoutResetTests: XCTestCase {

    private func cells() -> [CollageCell] {
        [CollageCell(photoPath: "/p/1.jpg", x: 0, y: 0, w: 540, h: 540),
         CollageCell(photoPath: "/p/2.jpg", x: 540, y: 0, w: 540, h: 540)]
    }

    func testAnOverrideIsWhatSendsTheRenderDownTheStoredBranch() {
        var day = PostingDay(day: .wednesday)
        XCTAssertNil(day.collageCellOverride, "no override means the planner runs")
        day.collageCellOverride = cells()
        XCTAssertNotNil(day.collageCellOverride)
    }

    func testClearingTheOverrideReturnsTheDayToTheAutomaticLayout() {
        var day = PostingDay(day: .wednesday)
        day.collageCellOverride = cells()

        day.collageCellOverride = nil

        XCTAssertNil(day.collageCellOverride,
                     "the next render has to go back through the shape-aware planner")
    }

    func testResettingOneDayLeavesAnotherDaysArrangementAlone() {
        var wednesday = PostingDay(day: .wednesday)
        var sunday = PostingDay(day: .sunday)
        wednesday.collageCellOverride = cells()
        sunday.collageCellOverride = cells()

        wednesday.collageCellOverride = nil

        XCTAssertNil(wednesday.collageCellOverride)
        XCTAssertNotNil(sunday.collageCellOverride, "only the day reset should change")
    }

    func testTheClearedOverrideSurvivesASaveAndReload() throws {
        // Cleared in memory but still on disk would come straight back on the
        // next launch, so the escape hatch has to actually persist.
        var day = PostingDay(day: .wednesday)
        day.collageCellOverride = cells()
        day.collageCellOverride = nil

        let round = try JSONDecoder().decode(
            PostingDay.self, from: try JSONEncoder().encode(day))

        XCTAssertNil(round.collageCellOverride)
    }

    func testCropOffsetsAreNotDiscardedByALayoutReset() {
        // The reset undoes the ARRANGEMENT. Per-photo crop is a different
        // setting, edited elsewhere, and taking it away would be a second
        // surprise on top of the one the person asked for.
        var day = PostingDay(day: .wednesday)
        day.collageCellOverride = cells()
        day.cropOffsets = ["/p/1.jpg": CropOffset(x: 0, y: -0.4)]

        day.collageCellOverride = nil

        XCTAssertEqual(day.cropOffsets["/p/1.jpg"]?.y, -0.4)
    }
}

/// The reset action itself, as the button drives it (#161).
extension CollageLayoutResetTests {

    private func override() -> [CollageCell] {
        [CollageCell(photoPath: "/p/1.jpg", x: 0, y: 0, w: 540, h: 540)]
    }

    func testTheControlIsHiddenWhenThereIsNoArrangementToUndo() {
        XCTAssertFalse(CollageLayoutReset.isOffered(cellOverride: nil))
    }

    func testTheControlAppearsOnceTheLayoutHasBeenDragged() {
        XCTAssertTrue(CollageLayoutReset.isOffered(cellOverride: override()))
    }

    func testResettingClearsTheOverride() {
        let outcome = CollageLayoutReset.apply(cellOverride: override())
        XCTAssertNil(outcome.cellOverride,
                     "clearing this is what sends the render back to the planner")
    }

    func testResettingClearsTheSelectedCell() {
        // The selection referred to the old plan, and the size slider hangs
        // off it, so leaving it points at a cell the new plan may not have.
        let outcome = CollageLayoutReset.apply(cellOverride: override())
        XCTAssertNil(outcome.selectedCellIndex)
    }

    func testResettingRebuildsThePreview() {
        // The stored image was rendered FROM the override, so without this the
        // screen keeps showing the arrangement just discarded.
        XCTAssertTrue(CollageLayoutReset.apply(cellOverride: override()).shouldRegenerate)
    }

    func testAResetWithNothingToUndoTriggersNoRebuild() {
        // A slow rebuild for a press that changes nothing.
        XCTAssertFalse(CollageLayoutReset.apply(cellOverride: nil).shouldRegenerate)
    }
}
