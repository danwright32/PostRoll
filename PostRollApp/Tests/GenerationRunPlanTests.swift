import XCTest

/// #396: the retry timeline and subtitle, which were arithmetic inside a view
/// reading a singleton and so had never been checked by anything but running a
/// real retry.
final class GenerationRunPlanTests: XCTestCase {

    func testAFullRunHasNoRetryPlan() {
        XCTAssertNil(GenerationRunPlan.retryPlan(retryDays: nil, dayCount: 5))
    }

    func testARetryOfOneDayCostsThatDaysShareOfTheCaptionMean() throws {
        // Five days, a 100 second caption mean: one day is 20 seconds, plus the
        // fixed 5 second read of the photos.
        let plan = try XCTUnwrap(GenerationRunPlan.retryPlan(
            retryDays: ["sunday"], dayCount: 5,
            fullEstimate: 400, captionsMean: 100, blogMean: 80))

        XCTAssertEqual(plan.phases.map(\.name),
                       ["Re-reading photos", "Writing Sunday captions"])
        XCTAssertEqual(plan.phases.map(\.startsAt), [0, 5])
        XCTAssertEqual(plan.estimate, 25)
    }

    func testTwoDaysCostTwiceOneDay() throws {
        let one = try XCTUnwrap(GenerationRunPlan.retryPlan(
            retryDays: ["sunday"], dayCount: 5, captionsMean: 100))
        let two = try XCTUnwrap(GenerationRunPlan.retryPlan(
            retryDays: ["sunday", "monday"], dayCount: 5, captionsMean: 100))

        XCTAssertEqual(one.estimate, 25)
        XCTAssertEqual(two.estimate, 45, "two days is two shares of the mean, not one")
    }

    func testTheBlogIsItsOwnPhaseAfterTheDays() throws {
        let plan = try XCTUnwrap(GenerationRunPlan.retryPlan(
            retryDays: ["thursday", "blog"], dayCount: 4,
            captionsMean: 120, blogMean: 60))

        XCTAssertEqual(plan.phases.map(\.name),
                       ["Re-reading photos", "Writing Thursday captions", "Drafting blog post"])
        // 5 + 30 for the day, then the blog starts.
        XCTAssertEqual(plan.phases.last?.startsAt, 35)
        XCTAssertEqual(plan.estimate, 95)
    }

    func testABlogOnlyRetrySkipsThePhotoAndCaptionPhases() throws {
        let plan = try XCTUnwrap(GenerationRunPlan.retryPlan(
            retryDays: ["blog"], dayCount: 4, blogMean: 60))

        XCTAssertEqual(plan.phases.map(\.name), ["Drafting blog post"])
        XCTAssertEqual(plan.estimate, 60)
    }

    /// The degenerate input: no day has photos yet, so the per day divisor would
    /// be zero. A crash or an infinite estimate here reaches Dan as a screen that
    /// says nothing.
    func testAZeroDayWeekDoesNotDivideByZero() throws {
        let plan = try XCTUnwrap(GenerationRunPlan.retryPlan(
            retryDays: ["sunday"], dayCount: 0, captionsMean: 100))

        XCTAssertTrue(plan.estimate.isFinite)
        XCTAssertEqual(plan.estimate, 105, "with no known day count the whole mean is charged")
    }

    /// Nothing to retry at all. The set is empty rather than nil, which is a
    /// different thing from a full run and used to produce a timeline with no
    /// phases and an estimate of zero, which reads as a finished run.
    func testAnEmptyRetrySetProducesNoPhases() throws {
        let plan = try XCTUnwrap(GenerationRunPlan.retryPlan(
            retryDays: [], dayCount: 5, captionsMean: 100))

        XCTAssertTrue(plan.phases.isEmpty)
        XCTAssertEqual(plan.estimate, 0)
    }

    func testMissingTimingsFallBackToTheAppsOwnFigures() throws {
        // What a first run shows, before TimingStore has any history.
        let plan = try XCTUnwrap(GenerationRunPlan.retryPlan(
            retryDays: ["blog"], dayCount: 5))

        let expected = (GenerationRunPlan.fallbackEstimate
                        * GenerationRunPlan.blogShareOfRun).rounded()
        XCTAssertEqual(plan.estimate, expected)
    }

    // MARK: - Subtitle

    func testAFullRunSubtitleCountsTheDays() {
        XCTAssertEqual(GenerationRunPlan.subtitle(retryDays: nil, dayCount: 5),
                       "Generating all 5 days")
        XCTAssertEqual(GenerationRunPlan.subtitle(retryDays: nil, dayCount: 1),
                       "Generating all 1 day",
                       "one day must not read as days")
    }

    func testARetrySubtitleNamesWhatIsBeingRetried() {
        XCTAssertEqual(GenerationRunPlan.subtitle(retryDays: ["blog"], dayCount: 5),
                       "Retrying blog post")
        XCTAssertEqual(GenerationRunPlan.subtitle(retryDays: ["sunday"], dayCount: 5),
                       "Retrying Sunday")
        XCTAssertEqual(GenerationRunPlan.subtitle(retryDays: ["sunday", "blog"], dayCount: 5),
                       "Retrying Sunday + blog")
    }

    /// The names come out in week order, not in whatever order the set iterated,
    /// so the same retry reads the same way twice.
    func testRetriedDaysAreNamedInWeekOrder() {
        let subtitle = GenerationRunPlan.subtitle(
            retryDays: ["thursday", "monday", "sunday"], dayCount: 5)
        XCTAssertEqual(subtitle, "Retrying Sunday, Monday + Thursday")
    }

    // MARK: - Active phase

    func testTheActivePhaseIsTheLastOneReached() {
        let phases = [
            GenerationRunPlan.Phase(name: "a", startsAt: 0),
            GenerationRunPlan.Phase(name: "b", startsAt: 30),
            GenerationRunPlan.Phase(name: "c", startsAt: 90),
        ]
        XCTAssertEqual(GenerationRunPlan.activePhaseIndex(phases: phases, elapsedSeconds: 0), 0)
        XCTAssertEqual(GenerationRunPlan.activePhaseIndex(phases: phases, elapsedSeconds: 29), 0)
        XCTAssertEqual(GenerationRunPlan.activePhaseIndex(phases: phases, elapsedSeconds: 30), 1)
        XCTAssertEqual(GenerationRunPlan.activePhaseIndex(phases: phases, elapsedSeconds: 900), 2,
                       "a run past its estimate stays on the last phase rather than "
                       + "running off the end")
    }

    func testAnEmptyTimelineHasNoActivePhaseToPointAt() {
        XCTAssertEqual(GenerationRunPlan.activePhaseIndex(phases: [], elapsedSeconds: 60), 0)
    }
}
