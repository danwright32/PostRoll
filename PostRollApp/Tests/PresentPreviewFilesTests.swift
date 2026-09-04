import XCTest

/// #1117: the last synchronous file reads inside a view body.
///
/// `ReviewMediaStrip` and `CaptionSection` decided what to show by calling
/// `FileManager.fileExists` from a computed property read by `body`, so the
/// answer was re-derived from the filesystem on every redraw, once per candidate
/// key. A `stat` is cheap next to the JPEG decodes #966 removed, which is why
/// this is the remainder rather than the freeze, but it is still file IO on the
/// main thread for an answer that changes only when the day is regenerated.
///
/// These pin what the two screens PICK before the reading moves, so the change
/// can be shown not to move it.
final class PresentPreviewFilesTests: XCTestCase {

    /// A reader that answers from a set rather than a disk, so nothing here
    /// touches the filesystem (L2).
    private func onDisk(_ paths: Set<String>) -> (String) -> Bool {
        { paths.contains($0) }
    }

    func testOnlyTheKeysWhoseFileIsThereAreReportedPresent() {
        let files = PresentPreviewFiles.of(
            ["reel": "/a/reel.mp4", "story": "/a/story.png"],
            exists: onDisk(["/a/reel.mp4"]))

        XCTAssertTrue(files.has("reel"))
        XCTAssertFalse(files.has("story"),
                       "a path that is recorded but whose file is gone reads as "
                       + "present, which is the broken image this guards")
    }

    func testNoPathsAtAllIsNothingPresent() {
        XCTAssertTrue(PresentPreviewFiles.of(nil, exists: onDisk([])).isEmpty)
    }

    func testTheStartingStateAnswersNoToEverything() {
        // A view holds this before its first refresh. Answering no is the right
        // starting state: a preview that appears a moment late is a redraw, and
        // one that appears and then vanishes is a broken image (L10).
        XCTAssertFalse(PresentPreviewFiles.none.has("reel"))
        XCTAssertTrue(PresentPreviewFiles.none.isEmpty)
    }

    func testThePriorityOrderIsTheCallersNotTheSets() {
        // These lists are PRIORITIES: the caller means "the best one available",
        // and a set has no order to inherit (L343).
        let files = PresentPreviewFiles.of(
            ["story": "/a/story.png", "before_after": "/a/ba.png"],
            exists: onDisk(["/a/story.png", "/a/ba.png"]))

        let picked = files.firstPresent(of: [("before_after", "BEFORE / AFTER"),
                                             ("story_cover", "STORY COVER"),
                                             ("story", "STORY")])

        XCTAssertEqual(picked?.key, "before_after")
        XCTAssertEqual(picked?.value, "BEFORE / AFTER")
    }

    func testAPriorityListSkipsPastWhatIsNotOnDisk() {
        let files = PresentPreviewFiles.of(
            ["before_after": "/a/ba.png", "story": "/a/story.png"],
            exists: onDisk(["/a/story.png"]))

        XCTAssertEqual(files.firstPresent(of: [("before_after", "BEFORE / AFTER"),
                                               ("story", "STORY")])?.key,
                       "story")
    }

    func testNothingPresentPicksNothing() {
        let files = PresentPreviewFiles.of(["story": "/a/story.png"],
                                           exists: onDisk([]))

        XCTAssertNil(files.firstPresent(of: [("story", "STORY")]))
    }

    func testEmptinessTellsNotRefreshedFromNothingToShow() {
        // Two states a view has to keep apart, which is why this is its own
        // question rather than something a caller derives (L11).
        let refreshedAndEmpty = PresentPreviewFiles.of(
            ["story": "/a/story.png"], exists: onDisk([]))

        XCTAssertTrue(refreshedAndEmpty.isEmpty)
        XCTAssertTrue(PresentPreviewFiles.none.isEmpty)
        XCTAssertEqual(refreshedAndEmpty, PresentPreviewFiles.none,
                       "these are equal by value, which is fine: what a caller "
                       + "needs is that neither shows anything")
    }
}
