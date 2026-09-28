import XCTest

/// Leaving photographs out of the Thursday reel without taking them off the day.
///
/// The reel used every photograph assigned to Thursday, so the only way to slow
/// an over long strip was a longer reel, and at 90 seconds the slider ran out:
/// Broadway Undressed (2026-09-28) scrolled at 20.3px a frame against the
/// 10.81 Dan judged comfortable. He chose to keep the length and take photos
/// out, in the editor where he swaps and pans them, restorable afterwards.
///
/// So the day keeps every photograph and records which ones the reel leaves
/// out. Every render path has to agree on that list, or the editor, the
/// background pre-render and the export render three different reels.
@MainActor
final class ReelPhotoRemovalTests: XCTestCase {

    private let a = URL(fileURLWithPath: "/p/a.jpg")
    private let b = URL(fileURLWithPath: "/p/b.jpg")
    private let c = URL(fileURLWithPath: "/p/c.jpg")

    private func thursday(removing removed: [URL] = []) -> PostingDay {
        var pd = PostingDay(day: .thursday)
        pd.photoPaths = [a, b, c]
        pd.reelSeed = 163
        pd.reelCropOffsets = [c.absoluteString: CropOffset(x: 0.5, y: 0, scale: 1.2),
                              b.absoluteString: CropOffset(x: 0, y: -0.4, scale: 1)]
        pd.reelRemovedPhotos = Set(removed.map(\.absoluteString))
        return pd
    }

    private func event(_ pd: PostingDay) -> Event {
        var event = Event(name: "Broadway Undressed", org: "Tom Guthrie", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_800_000_000),
                          shootType: .fullShow)
        event.days = [DayName.thursday.rawValue: pd]
        return event
    }

    // MARK: - The day

    func testTheReelLeavesOutRemovedPhotosAndKeepsTheOrder() {
        XCTAssertEqual(thursday(removing: [b]).reelPhotoPaths, [a, c])
        XCTAssertEqual(thursday().reelPhotoPaths, [a, b, c])
    }

    func testARemovedPhotoStaysOnTheDayWithItsCrop() {
        // Restorable exactly: nothing about the photograph is thrown away.
        let pd = thursday(removing: [b])
        XCTAssertEqual(pd.photoPaths, [a, b, c])
        XCTAssertEqual(pd.reelCropOffsets[b.absoluteString]?.y, -0.4)
    }

    func testTheRemovedListSurvivesASaveAndLoad() throws {
        let data = try JSONEncoder().encode(thursday(removing: [b]))
        let back = try JSONDecoder().decode(PostingDay.self, from: data)
        XCTAssertEqual(back.reelRemovedPhotos, [b.absoluteString])
    }

    func testADayStoredBeforeThisHasNothingRemoved() throws {
        let data = try JSONEncoder().encode(thursday())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "reelRemovedPhotos")
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(PostingDay.self, from: old).reelRemovedPhotos, [])
    }

    func testAPhotoDroppedFromTheDayLeavesTheList() {
        let pd = thursday(removing: [b]).removingPhotos([b])
        XCTAssertTrue(pd.reelRemovedPhotos.isEmpty)
    }

    func testAMovedPhotoIsStillRemovedAtItsNewPath() {
        let moved = URL(fileURLWithPath: "/storage/b.jpg")
        let pd = thursday(removing: [b]).rebindingPhotos([b: moved])
        XCTAssertEqual(pd.reelRemovedPhotos, [moved.absoluteString])
        XCTAssertEqual(pd.reelPhotoPaths, [a, c])
    }

    // MARK: - Every render agrees

    func testTheRenderManifestSendsOnlyTheReelPhotosWithTheirOwnCrops() async throws {
        let manifest = await PythonBridge.shared.buildMediaManifest(event: event(thursday(removing: [b])))
        let days = try XCTUnwrap(manifest["days"] as? [String: Any])
        let day = try XCTUnwrap(days["thursday"] as? [String: Any])
        XCTAssertEqual(day["photos"] as? [String], [a.path, c.path])
        // Offsets are applied by index, so they must line up with the list
        // actually sent: c's crop belongs to the second photo now, not b's.
        // a was never moved, so it goes at the top anchored default.
        XCTAssertEqual(day["crop_offsets"] as? [[Double]], [[0, -1, 1], [0.5, 0, 1.2]])
    }

    func testTheEditorPreviewSendsOnlyTheReelPhotos() {
        let manifest = PythonBridge.buildReelPreviewManifest(day: thursday(removing: [b]))
        XCTAssertEqual(manifest["photos"] as? [String], [a.path, c.path])
        XCTAssertEqual(manifest["crop_offsets"] as? [[Double]], [[0, -1, 1], [0.5, 0, 1.2]])
    }

    func testTheCaptionRunIsToldWhatTheReelShows() async throws {
        var ev = event(thursday(removing: [b]))
        ev.ocrResult = OCRResult(performers: [], pieces: [], scenes: [])
        let week = try await PythonBridge.shared.buildManifest(event: ev)
        let days = try XCTUnwrap(week["days"] as? [String: Any])
        let day = try XCTUnwrap(days["thursday"] as? [String: Any])
        XCTAssertEqual(day["photos"] as? [String], [a.path, c.path])
    }

    func testRemovingAPhotoIsADifferentPreRender() {
        // Otherwise a background render made before the removal is adopted
        // for the reel after it, and the removed photo ships.
        let renderer = SpeculativeReelRenderer()
        XCTAssertNotEqual(renderer.fingerprint(for: event(thursday())),
                          renderer.fingerprint(for: event(thursday(removing: [b]))))
    }

    func testOnlyAMovedCropIsSentAsACrop() {
        // Crops left at the top anchored default are not crops. The check used
        // to compare against zero, so every untouched day sent a list.
        var pd = thursday()
        pd.reelCropOffsets = [a.absoluteString: CropOffset()]
        XCTAssertNil(PythonBridge.buildReelPreviewManifest(day: pd)["crop_offsets"])
        // And a crop moved only on a photo left out is not one the reel shows.
        pd.reelCropOffsets = [b.absoluteString: CropOffset(x: 1, y: 0, scale: 1)]
        pd.reelRemovedPhotos = [b.absoluteString]
        XCTAssertNil(PythonBridge.buildReelPreviewManifest(day: pd)["crop_offsets"])
    }

    func testARemovalForcesTheExportToRenderAgain() {
        var pd = thursday(removing: [b])
        pd.reelCropOffsets = [:]
        XCTAssertTrue(pd.hasReelEdits)
    }

    func testAStaleEntryForAPhotoNoLongerOnTheDayIsNotAnEdit() {
        // "Change photos" replaces the day's list outright. A removal left
        // over for a photo that is gone changes nothing about the reel.
        var pd = thursday()
        pd.reelCropOffsets = [:]
        XCTAssertFalse(pd.hasReelEdits)
        pd.reelRemovedPhotos = [URL(fileURLWithPath: "/p/gone.jpg").absoluteString]
        XCTAssertFalse(pd.hasReelEdits)
    }

    // MARK: - Marking in the editor

    private var keys: [String] { [a, b, c].map(\.absoluteString) }

    func testTappingAPhotoMarksItAndTappingAgainUnmarksIt() {
        let marked = ReelRemoval.toggling(b.absoluteString, in: [], shown: keys)
        XCTAssertEqual(marked, [b.absoluteString])
        XCTAssertEqual(ReelRemoval.toggling(b.absoluteString, in: marked, shown: keys), [])
    }

    func testTheLastPhotoCannotBeRemoved() {
        let two: Set = [a.absoluteString, b.absoluteString]
        XCTAssertEqual(ReelRemoval.toggling(c.absoluteString, in: two, shown: keys), two)
    }

    func testTheCountSaysWhenEnoughAreGone() {
        XCTAssertEqual(ReelRemoval.banner(marked: 0, shown: 130, comfortable: 70, reelSeconds: 56),
                       "Tap the photos to leave out of the reel. About 70 is comfortable at 56 seconds.")
        XCTAssertEqual(ReelRemoval.banner(marked: 14, shown: 130, comfortable: 70, reelSeconds: 56),
                       "14 marked, 116 photos left. About 70 is comfortable at 56 seconds.")
        XCTAssertEqual(ReelRemoval.banner(marked: 60, shown: 130, comfortable: 70, reelSeconds: 56),
                       "60 marked, 70 photos left. That is comfortable at 56 seconds.")
        XCTAssertEqual(ReelRemoval.banner(marked: 1, shown: 2, comfortable: nil, reelSeconds: nil),
                       "1 marked, 1 photo left.")
    }

    // MARK: - The removed row

    func testTheRowListsWhatTheRenderedStripLeftOut() {
        // The strip on screen shows a and c; b was removed and rendered out.
        let row = ReelRemoval.leftOut(all: [a, b, c], removed: [b.absoluteString],
                                      shown: [a, c].map(\.absoluteString))
        XCTAssertEqual(row, [ReelRemoval.LeftOut(url: b, returning: false)])
    }

    func testARestoredPhotoIsMarkedAsReturningUntilTheNextRender() {
        // Restored: no longer in the removed list, still not in the strip.
        let row = ReelRemoval.leftOut(all: [a, b, c], removed: [],
                                      shown: [a, c].map(\.absoluteString))
        XCTAssertEqual(row, [ReelRemoval.LeftOut(url: b, returning: true)])
    }

    func testAPhotoMarkedButStillInTheStripIsNotInTheRow() {
        // It is shown dimmed in the strip itself, so listing it again would
        // state one fact twice.
        let row = ReelRemoval.leftOut(all: [a, b, c], removed: [b.absoluteString],
                                      shown: keys)
        XCTAssertEqual(row, [])
    }

    // MARK: - The warning names both remedies

    func testTheSpeedWarningOffersFewerPhotosBesideALongerReel() throws {
        // A strip the slider CAN fix still says how many photos would do it at
        // the length Dan chose, since that is the remedy he prefers.
        let notice = try XCTUnwrap(ScrollReelTiming.speedNotice(
            stripHeight: 15_000, photoCount: 100, scrollSeconds: 40))
        let fewer = ScrollReelTiming.comfortablePhotoCount(
            stripHeight: 15_000, photoCount: 100, scrollSeconds: 40)
        XCTAssertLessThan(fewer, 100)
        XCTAssertTrue(notice.contains("or about \(fewer) photographs rather than 100"), notice)
    }
}
