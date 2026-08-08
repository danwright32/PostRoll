import XCTest

/// A stored generation error is a claim about a past run, not about the current
/// state. Once the inputs that error complained about are re-linked or removed,
/// the claim stops being true and the review screen must stop presenting it as
/// current (#181). On 2026-08-01 six failures naming files under a renamed
/// folder kept showing after every photo had been re-linked.
final class StoredErrorPolicyTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func eventWithErrors() -> Event {
        var ev = Event(name: "Greatest Hits", org: "Org", venue: "Hall",
                       date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        ev.mediaErrors = ["wednesday": "collage failed: /old/a.jpg not found",
                          "thursday": "reel failed: audio decode error"]
        var week = WeekGenerationResult()
        week.errors = ["wednesday": "caption failed", "sunday": "caption failed"]
        ev.weekResult = week
        return ev
    }

    func testFindsTheDayThatReferencesARelinkedPhoto() {
        let moved = url("/old/a.jpg")
        var ev = eventWithErrors()
        var wed = PostingDay(day: .wednesday)
        wed.photoPaths = [moved]
        ev.days["wednesday"] = wed

        XCTAssertEqual(StoredErrorPolicy.daysReferencing([moved], in: ev), ["wednesday"])
    }

    func testFindsTheDayThroughAStandaloneMediaSlot() {
        let moved = url("/old/bw.jpg")
        var ev = eventWithErrors()
        var tue = PostingDay(day: .tuesday)
        tue.bwPhotoPath = moved
        ev.days["tuesday"] = tue

        XCTAssertEqual(StoredErrorPolicy.daysReferencing([moved], in: ev), ["tuesday"],
                       "the B&W photo is an input to Tuesday's reel and Friday's graphic")
    }

    func testIncludesTheBlogWhenABlogPhotoMoved() {
        let moved = url("/old/a.jpg")
        var ev = eventWithErrors()
        ev.blogPhotoPaths = [moved]

        XCTAssertTrue(StoredErrorPolicy.daysReferencing([moved], in: ev).contains("blog"))
    }

    func testAFileNoDayReferencesTouchesNothing() {
        var ev = eventWithErrors()
        var wed = PostingDay(day: .wednesday)
        wed.photoPaths = [url("/storage/a.jpg")]
        ev.days["wednesday"] = wed

        XCTAssertTrue(StoredErrorPolicy.daysReferencing([url("/elsewhere/z.jpg")], in: ev).isEmpty)
    }

    func testClearingDropsBothErrorStoresForThoseDaysOnly() {
        let ev = eventWithErrors()

        let cleared = StoredErrorPolicy.clearingErrors(in: ev, forDays: ["wednesday"])

        XCTAssertNil(cleared.mediaErrors["wednesday"])
        XCTAssertNil(cleared.weekResult?.errors["wednesday"],
                     "the caption failure for that day is the same stale claim")
        XCTAssertEqual(cleared.mediaErrors["thursday"], "reel failed: audio decode error",
                       "an untouched day keeps its error")
        XCTAssertEqual(cleared.weekResult?.errors["sunday"], "caption failed")
    }

    func testClearingADayWithNoErrorIsANoOp() {
        let ev = eventWithErrors()

        let cleared = StoredErrorPolicy.clearingErrors(in: ev, forDays: ["friday"])

        XCTAssertEqual(cleared, ev)
    }

    func testClearingLeavesTheDayWithoutAssetsRatherThanLookingSuccessful() {
        // Dropping the error must not invent a result: a day with no assets and
        // no error has to stay distinguishable from a day that rendered.
        let ev = eventWithErrors()

        let cleared = StoredErrorPolicy.clearingErrors(in: ev, forDays: ["wednesday"])

        XCTAssertNil(cleared.weekResult?[.wednesday],
                     "no caption was produced, so none may appear")
        XCTAssertNil(cleared.previewMediaPaths["wednesday"],
                     "no graphic was produced, so none may appear")
    }
}
