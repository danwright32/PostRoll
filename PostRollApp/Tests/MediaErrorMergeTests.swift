import XCTest

/// The graphics step of a generation run reports per-day failures the same way
/// the caption step does, but the run used to read only the rendered paths out of
/// the result and drop `errors` on the floor (behind a `try?` that also swallowed
/// an outright crash). A failed Wednesday collage therefore reported success and
/// simply left the day with no story. These pin the failure path: a graphics
/// failure has to survive into the event, and only a run that actually re-rendered
/// a day may clear that day's recorded failure.
final class MediaErrorMergeTests: XCTestCase {

    // MARK: - mergeMediaErrors

    func testFullRunReplacesAllRecordedMediaErrors() {
        let existing = ["wednesday": "collage failed: old", "thursday": "reel failed"]
        let fresh = ["wednesday": "collage failed: new"]

        let merged = PreviewMergePolicy.mergeMediaErrors(
            existing: existing, fresh: fresh, renderedDays: nil)

        XCTAssertEqual(merged, fresh, "a full run re-rendered everything, so it owns the whole error set")
    }

    func testRetryClearsOnlyTheDaysItRendered() {
        let existing = ["wednesday": "collage failed", "thursday": "reel failed"]

        let merged = PreviewMergePolicy.mergeMediaErrors(
            existing: existing, fresh: [:], renderedDays: ["wednesday"])

        XCTAssertNil(merged["wednesday"], "Wednesday rendered cleanly this time")
        XCTAssertEqual(merged["thursday"], "reel failed",
                       "Thursday was never re-attempted, so its failure must not be silently cleared")
    }

    func testCaptionOnlyRetryKeepsGraphicsFailuresIntact() {
        // A partial retry skips graphics entirely (shouldRenderGraphics == false),
        // so it renders no days and must leave every recorded failure standing.
        let existing = ["wednesday": "collage failed"]

        let merged = PreviewMergePolicy.mergeMediaErrors(
            existing: existing, fresh: [:], renderedDays: [])

        XCTAssertEqual(merged, existing)
    }

    func testRetryThatFailsAgainRecordsTheNewMessage() {
        let merged = PreviewMergePolicy.mergeMediaErrors(
            existing: ["wednesday": "collage failed: old"],
            fresh: ["wednesday": "collage failed: still broken"],
            renderedDays: ["wednesday"])

        XCTAssertEqual(merged["wednesday"], "collage failed: still broken")
    }

    // MARK: - retryPlan

    func testRetryOfAGraphicsFailureRerendersThatDaysGraphics() {
        // The default partial retry skips graphics, which would make the retry
        // button look like it did nothing for a collage failure.
        let plan = PreviewMergePolicy.retryPlan(
            failedKeys: ["wednesday"], mediaErrorKeys: ["wednesday"])

        XCTAssertEqual(plan.days, ["wednesday"])
        XCTAssertEqual(plan.regenerateGraphics, true)
    }

    func testRetryOfACaptionOnlyFailureLeavesGraphicsAlone() {
        let plan = PreviewMergePolicy.retryPlan(
            failedKeys: ["monday", "blog"], mediaErrorKeys: [])

        XCTAssertEqual(plan.days, ["monday", "blog"])
        XCTAssertNil(plan.regenerateGraphics, "no graphics failure, so keep the cheap caption-only retry")
    }

    func testWholeGraphicsRunCrashRetriesAsAFullRun() {
        // The crash key names no day, so it cannot be passed to --only-days.
        let plan = PreviewMergePolicy.retryPlan(
            failedKeys: [PreviewMergePolicy.graphicsRunKey],
            mediaErrorKeys: [PreviewMergePolicy.graphicsRunKey])

        XCTAssertNil(plan.days, "nothing day-shaped to retry, so re-run the whole thing")
        XCTAssertNil(plan.regenerateGraphics, "a full run renders graphics anyway")
    }

    func testGraphicsCrashAlongsideADayFailureStillRetriesThatDay() {
        let plan = PreviewMergePolicy.retryPlan(
            failedKeys: ["wednesday", PreviewMergePolicy.graphicsRunKey],
            mediaErrorKeys: ["wednesday", PreviewMergePolicy.graphicsRunKey])

        XCTAssertEqual(plan.days, ["wednesday"], "the non-day crash key must be filtered out")
        XCTAssertEqual(plan.regenerateGraphics, true)
    }

    // MARK: - Persistence

    func testMediaErrorsSurviveASaveAndReload() throws {
        var event = Event(name: "Spring Concert", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        event.mediaErrors = ["wednesday": "collage failed: no such file"]

        let data = try JSONEncoder().encode(event)
        let reloaded = try JSONDecoder().decode(Event.self, from: data)

        XCTAssertEqual(reloaded.mediaErrors, ["wednesday": "collage failed: no such file"])
    }

    func testMediaErrorsDefaultToEmptyForEventsSavedBeforeTheFieldExisted() throws {
        let legacy = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Old Show","org":"Org",
         "venue":"Hall","date":0,"shootType":"Performance"}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(Event.self, from: legacy)

        XCTAssertEqual(event.mediaErrors, [:])
    }
}
