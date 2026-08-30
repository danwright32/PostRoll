#if POSTROLL_TESTS
import XCTest
import AppKit

/// #992: the review sheet's rotation has to survive the suite running in
/// parallel.
///
/// `ReviewSheet` used to empty the whole sheet folder from a `static let`, and
/// said so in its own comment: "emptied once per test process ... `static let`
/// is Swift's once, which is what makes that safe without any ordering between
/// the classes." That is correct while there is exactly ONE test process.
///
/// XCTest's parallel mode runs test classes in separate processes, so every
/// worker runs that initialiser and clears the one shared folder. Measured on
/// 2026-08-30, the first parallel run of this suite:
/// `HostedControlLegibilityTests.testDumpEveryMeasuredScreenForReview` failed,
/// having rendered 82 screens and found fewer on disk, because a sibling worker
/// had emptied the folder underneath it.
///
/// This is the recorded shape of that class of bug: a comment that reads as
/// reassurance, justifying code that becomes actively destructive the moment
/// the invariant it names goes away (L204). The fix is not to re-establish the
/// invariant, which parallelism is deliberately removing, but to stop depending
/// on it: rotation is per GROUP now, and each group is written by exactly one
/// test in exactly one class, so no two workers ever touch the same files.
///
/// The layout stays FLAT. The `review-sheet` make target reads the folder with
/// `ls | grep '\.png$'` and `for f in "$folder"/*.png`, so per-group
/// subdirectories would have broken the one thing the sheet is for.
final class ReviewSheetGroupIsolationTests: XCTestCase {

    private func pngs(in url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasSuffix(".png") }.sorted()
    }

    private func plant(_ group: String, _ name: String) throws {
        try ReviewSheet.write(pixel(), group: group, name: name)
    }

    /// One real 1x1 bitmap, so these exercise the same write path the dumps do
    /// rather than a hand-written file that only looks like one.
    ///
    /// Built per call rather than held in a `static let`: `NSBitmapImageRep` is
    /// not `Sendable`, and a shared mutable one is exactly the kind of state
    /// this file exists to stop the suite depending on.
    private func pixel() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32)!
        rep.setColor(.black, atX: 0, y: 0)
        return rep
    }

    func testRotatingOneGroupLeavesEveryOtherGroupAlone() throws {
        try plant("isolation-keep", "kept")
        XCTAssertTrue(pngs(in: ReviewSheet.folder).contains("isolation-keep--kept.png"),
                      "the fixture never landed, so this proves nothing")

        try ReviewSheet.begin(group: "isolation-rotate")

        XCTAssertTrue(
            pngs(in: ReviewSheet.folder).contains("isolation-keep--kept.png"),
            """
            rotating one group deleted another group's image. Under parallel \
            testing those two groups are two processes running at once, so this \
            is one worker destroying another's work mid-run, which is what made \
            the screens dump fail the first time the suite ran in parallel.
            """)
    }

    func testRotatingAGroupDoesClearThatGroupsOwnImages() throws {
        try plant("isolation-rotate", "stale")
        XCTAssertTrue(pngs(in: ReviewSheet.folder).contains("isolation-rotate--stale.png"),
                      "the fixture never landed, so this proves nothing")

        try ReviewSheet.begin(group: "isolation-rotate")

        XCTAssertFalse(
            pngs(in: ReviewSheet.folder).contains("isolation-rotate--stale.png"),
            """
            an image from an earlier run survived the rotation, so the sheet \
            mixes a picture of a state the app may no longer produce with the \
            current ones, and nothing on it says which is which.
            """)
    }

    func testTheRotatedImagesBecomeTheBaselineRatherThanBeingDeleted() throws {
        try plant("isolation-baseline", "moved")

        try ReviewSheet.begin(group: "isolation-baseline")

        XCTAssertTrue(
            pngs(in: ReviewSheet.previous).contains("isolation-baseline--moved.png"),
            """
            the previous run was deleted instead of kept, so `make review-sheet` \
            has nothing to compare against and every screen reports as new. \
            "19 of 82 screens moved" is the answer that makes a change \
            reviewable at all (#636).
            """)
    }

    func testRotatingAGroupTwiceDoesNotCarryTheOlderBaselineForward() throws {
        try plant("isolation-twice", "first")
        try ReviewSheet.begin(group: "isolation-twice")
        try plant("isolation-twice", "second")
        try ReviewSheet.begin(group: "isolation-twice")

        let baseline = pngs(in: ReviewSheet.previous)
        XCTAssertTrue(baseline.contains("isolation-twice--second.png"))
        XCTAssertFalse(
            baseline.contains("isolation-twice--first.png"),
            """
            a baseline from two runs ago is still in place, so the comparison is \
            against whichever run happened to leave a file rather than against \
            the previous one, and a stale baseline reports screens as moved that \
            did not move.
            """)
    }
}
#endif
