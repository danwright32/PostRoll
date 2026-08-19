import XCTest

/// The two Insights runs outlive the screen that started them (#718).
///
/// The CSV import and the report generation both kept their in flight flag,
/// their start time and their error message in `InsightsOverviewView`'s own
/// `@State`. Moving the sidebar off Insights destroys that view, and with it
/// all three: a run still going, one that had finished, and one that had failed
/// then looked identical, because all three showed nothing. Coming back found
/// the idle button, so a second paid analysis was one click away.
///
/// Neither run is about an event, so this owner keys on its own small enum
/// rather than on an event id, through the same `JobTracker` every other
/// long run uses.
///
/// Most of what is below is a failure path. A happy path test cannot tell any
/// of these apart: it is precisely the runs that fail, stall, or are refused a
/// write that used to leave nothing on the screen.
@MainActor
final class InsightsWorkManagerTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("InsightsWork-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A store that cannot reach the real analytics.json (L2).
    private func store() -> AnalyticsStore {
        AnalyticsStore(fileURL: root.appendingPathComponent("analytics.json"))
    }

    nonisolated private static func post(_ id: String) -> IGPost {
        IGPost(igPostID: id, igPermalink: "https://example.com/p/\(id)",
               publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
               mediaType: .reel, caption: "a caption", hashtags: ["#one"],
               views: 10, reach: 9, likes: 8, shares: 1, follows: 0,
               comments: 2, saves: 3, replies: nil, navigation: nil,
               profileVisits: nil, stickerTaps: nil, durationSec: 12,
               org: "@dciny", isPersonal: false)
    }

    nonisolated private static func report(_ summary: String) -> InsightReport {
        let empty = InsightFindings(captionPatterns: [], hashtagPatterns: [],
                                    contentTypePatterns: [], timingPatterns: [])
        return InsightReport(
            id: UUID(), generatedAt: Date(),
            dateRangeStart: Date(timeIntervalSince1970: 1_700_000_000),
            dateRangeEnd: Date(timeIntervalSince1970: 1_800_000_000),
            postCount: 1, storyCount: 0, feedCount: 1, summary: summary,
            feedFindings: empty, storyFindings: empty,
            brandVoiceSuggestions: [], caveats: [])
    }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - It finishes whether or not anyone is looking

    func testAReportLandsInTheStoreWithNoScreenWatching() async throws {
        // The whole point. Nothing here renders anything, which is the state
        // the app is in the moment Dan clicks Events in the sidebar.
        let store = store()
        let manager = InsightsWorkManager()
        manager.runAnalysis = { _, _, _ in Self.report("posts do better on Sundays") }

        manager.startReport(store: store, globalHashtags: [])
        await settle()

        XCTAssertEqual(store.reports.first?.summary, "posts do better on Sundays",
                       "the analysis completed into nothing, so a paid model "
                       + "pass over the whole history was thrown away")
    }

    func testAnImportLandsInTheStoreWithNoScreenWatching() async throws {
        let store = store()
        let manager = InsightsWorkManager()
        manager.runImport = { _ in MetaImportResult(posts: [Self.post("1")], warnings: []) }

        manager.startImport(of: [URL(fileURLWithPath: "/tmp/a.csv")], into: store)
        await settle()

        XCTAssertEqual(store.posts.count, 1)
    }

    // MARK: - Three states that must not look alike

    func testARunningReportIsDistinguishableFromOneThatFinished() async throws {
        let store = store()
        let manager = InsightsWorkManager()
        manager.runAnalysis = { _, _, _ in
            try await Task.sleep(for: .milliseconds(200))
            return Self.report("done")
        }

        manager.startReport(store: store, globalHashtags: [])
        XCTAssertTrue(manager.isRunning(.generateReport))
        XCTAssertNotNil(manager.startedAt(.generateReport),
                        "with no start time the indicator cannot show elapsed "
                        + "time, which is the difference between alive and hung")
        XCTAssertNil(manager.outcome(for: .generateReport))

        await settle()

        XCTAssertFalse(manager.isRunning(.generateReport))
        XCTAssertNil(manager.outcome(for: .generateReport)?.note,
                     "a run that succeeded left something that renders as a problem")
    }

    func testAFailedReportKeepsItsReasonAfterTheScreenIsGone() async throws {
        // The state the view used to destroy. Nothing here holds a view at
        // all, so this is the failure arriving while Dan is on another screen.
        struct Refused: LocalizedError {
            var errorDescription: String? { "the model refused the request" }
        }
        let store = store()
        let manager = InsightsWorkManager()
        manager.runAnalysis = { _, _, _ in throw Refused() }

        manager.startReport(store: store, globalHashtags: [])
        await settle()

        XCTAssertFalse(manager.isRunning(.generateReport))
        XCTAssertEqual(manager.outcome(for: .generateReport)?.note,
                       "the model refused the request",
                       "the reason died with the screen, so Dan is left pressing "
                       + "the same button with nothing to read (L148)")
        XCTAssertNil(manager.outcome(for: .generateReport)?.success,
                     "a failed run offered something to show with a tick")
    }

    func testAStalledReportBecomesAnErrorRatherThanAnIndicatorForever() async throws {
        let store = store()
        let manager = InsightsWorkManager()
        manager.reportDeadlineForTesting = 0.05
        manager.runAnalysis = { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return Self.report("never")
        }

        manager.startReport(store: store, globalHashtags: [])
        await settle()

        XCTAssertFalse(manager.isRunning(.generateReport))
        let note = try XCTUnwrap(manager.outcome(for: .generateReport)?.note)
        XCTAssertTrue(note.lowercased().contains("come back")
                      || note.lowercased().contains("did not"),
                      "a run that never returned was reported as some other "
                      + "kind of failure: \(note)")
    }

    // MARK: - It refuses to run twice

    func testASecondReportIsRefusedWhileTheFirstIsGoing() async throws {
        // Coming back to Insights showed the idle button, so stacking two paid
        // analyses on one history was one click away.
        let store = store()
        let manager = InsightsWorkManager()
        let calls = Counter()
        manager.runAnalysis = { _, _, _ in
            await calls.bump()
            try await Task.sleep(for: .milliseconds(200))
            return Self.report("done")
        }

        manager.startReport(store: store, globalHashtags: [])
        manager.startReport(store: store, globalHashtags: [])
        await settle()

        let count = await calls.value
        XCTAssertEqual(count, 1, "a second analysis was started over the first")
    }

    func testAnImportDoesNotBlockAReport() async throws {
        // Two different jobs, tracked apart. An import running must not make
        // the Generate button read as busy.
        let store = store()
        let manager = InsightsWorkManager()
        manager.runImport = { _ in
            try await Task.sleep(for: .milliseconds(200))
            return MetaImportResult(posts: [], warnings: [])
        }

        manager.startImport(of: [URL(fileURLWithPath: "/tmp/a.csv")], into: store)

        XCTAssertTrue(manager.isRunning(.importCSV))
        XCTAssertFalse(manager.isRunning(.generateReport))
        await settle()
    }

    // MARK: - What it may claim (#439 carried over intact)

    func testARefusedWriteIsNeverShownAsAnImportThatHappened() async throws {
        // The summary row renders a green tick. A tick over a write that did
        // not land is the whole defect #439 fixed, and it must survive the move
        // off the view (L12).
        // The URL is spelled once and handed to both, so the gate cannot end
        // up blocking a different file from the one the store writes (L41).
        let file = root.appendingPathComponent("analytics.json")
        let store = AnalyticsStore(fileURL: file)
        StoreSaveGate.shared.block(file)
        defer { StoreSaveGate.shared.unblock(file) }

        let manager = InsightsWorkManager()
        manager.runImport = { _ in MetaImportResult(posts: [Self.post("1")], warnings: []) }

        manager.startImport(of: [URL(fileURLWithPath: "/tmp/a.csv")], into: store)
        await settle()

        XCTAssertNil(manager.outcome(for: .importCSV)?.success,
                     "a refused write was offered to the tick row")
        XCTAssertNotNil(manager.outcome(for: .importCSV)?.note)
    }

    func testWarningsFromAnImportThatLandedAreShownWithoutDenyingTheSuccess() async throws {
        let store = store()
        let manager = InsightsWorkManager()
        manager.runImport = { _ in
            MetaImportResult(posts: [Self.post("1")],
                             warnings: ["row 4 had no date"])
        }

        manager.startImport(of: [URL(fileURLWithPath: "/tmp/a.csv")], into: store)
        await settle()

        let outcome = try XCTUnwrap(manager.outcome(for: .importCSV))
        XCTAssertNotNil(outcome.success, "an import that landed said nothing")
        XCTAssertEqual(outcome.note, "row 4 had no date")
    }

    // MARK: - Quitting to update

    func testWorkInFlightIsVisibleToTheUpdater() async throws {
        // Updating quits the app to install (#686). A paid analysis half way
        // through is exactly the thing that must not be thrown away silently.
        let store = store()
        let manager = InsightsWorkManager()
        XCTAssertFalse(manager.hasWorkInFlight)

        manager.runAnalysis = { _, _, _ in
            try await Task.sleep(for: .milliseconds(200))
            return Self.report("done")
        }
        manager.startReport(store: store, globalHashtags: [])

        XCTAssertTrue(manager.hasWorkInFlight)
        await settle()
        XCTAssertFalse(manager.hasWorkInFlight)
    }

    /// Counts calls from whatever actor the stub runs on.
    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }
}
