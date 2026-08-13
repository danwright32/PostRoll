import XCTest

/// #489: `cropConfidence` was decoded, persisted into events.json and
/// documented as the gate's final decision, and read by nothing.
///
/// A stored field with a writer and no reader looks alive to any is-this-used
/// check, because the write really does run, so the thing it was added for
/// silently never happens (L46).
final class FridayCropNoteTests: XCTestCase {

    private func selection(_ path: String, confidence: String) -> FridayClipSelection {
        FridayClipSelection(clipPath: path, trimIn: 0, trimOut: 2, transition: .cut,
                            cropX: 0, cropY: 0, cropConfidence: confidence)
    }

    private func plan(_ confidences: [String]) -> FridayClipPlan {
        var plan = FridayClipPlan()
        plan.selections = confidences.enumerated().map {
            selection("/clips/\($0.offset).mov", confidence: $0.element)
        }
        return plan
    }

    func testACutWhoseCropsWereAllTrustedSaysNothing() {
        XCTAssertNil(FridayReviewDisplay.cropNote(plan(["high", "high", "high"])))
    }

    func testNoPlanSaysNothing() {
        XCTAssertNil(FridayReviewDisplay.cropNote(nil))
        XCTAssertNil(FridayReviewDisplay.cropNote(FridayClipPlan()))
    }

    func testTheNoteCountsTheClipsShownUncropped() throws {
        let note = try XCTUnwrap(FridayReviewDisplay.cropNote(plan(["high", "low", "low", "high"])))
        XCTAssertTrue(note.contains("2 of 4"), note)
        XCTAssertTrue(note.contains("uncropped"), note)
    }

    func testOneClipReadsAsOneRatherThanAsPlural() throws {
        let note = try XCTUnwrap(FridayReviewDisplay.cropNote(plan(["high", "low"])))
        XCTAssertTrue(note.contains("1 of 2 clip is"), note)
        XCTAssertFalse(note.contains("clips are"), note)
    }

    func testAnUnrecognisedConfidenceCountsAsNotTrusted() throws {
        // `apply_selection` only ever writes "high" or "low", and an older saved
        // event decodes a missing value as "low". Anything else is not a claim
        // that the crop was trusted, so it must not be read as one.
        let note = try XCTUnwrap(FridayReviewDisplay.cropNote(plan(["high", ""])))
        XCTAssertTrue(note.contains("1 of 2"), note)
    }
}
