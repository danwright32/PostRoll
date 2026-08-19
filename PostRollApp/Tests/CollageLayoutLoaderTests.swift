import XCTest

/// The layout gallery's render outlives the sheet that opened it (#718).
///
/// Rendering the layout options is a real render of every candidate collage.
/// Its in flight flag, its error and the candidates themselves lived in
/// `CollageLayoutGallery`'s own state, so closing the sheet, or switching
/// events with it open, threw the render away part way through and the next
/// open started it again from nothing.
///
/// The results already had somewhere app scoped to live,
/// `CollageCandidateCache`, which exists so reopening shows the SAME options
/// (#61). What was missing was an owner for the run itself.
@MainActor
final class CollageLayoutLoaderTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CollageLoad-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CollageCandidateCache.shared.remove(day: .wednesday)
        try? FileManager.default.removeItem(at: root)
    }

    private func event() -> Event {
        Event(name: "Spring Gala", org: "Decoda", venue: "Merkin Hall",
              date: Date(), shootType: .fullShow)
    }

    /// Candidates whose files really exist, because the cache drops any set
    /// whose files have gone and would otherwise report a miss (L48).
    private func candidates(_ n: Int) throws -> [CollageCandidate] {
        let dir = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<n).map { i in
            let file = dir.appendingPathComponent("cand-\(i).png")
            try Data([0x1]).write(to: file)
            return CollageCandidate(seed: i, path: file.path)
        }
    }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testTheRenderFinishesIntoTheCacheWithNoSheetWatching() async throws {
        let event = event()
        let rendered = try candidates(3)
        let loader = CollageLayoutLoader()
        loader.render = { _, _ in rendered }

        loader.start(event: event, day: .wednesday)
        await settle()

        XCTAssertEqual(loader.candidates(event: event, day: .wednesday)?.count, 3,
                       "the render completed into a sheet that was gone, so the "
                       + "work was thrown away rather than kept")
    }

    func testASecondOpenReusesWhatWasAlreadyRendered() async throws {
        // The whole reason the cache exists (#61): the options must not change
        // under Dan between one look and the next.
        let event = event()
        let rendered = try candidates(3)
        let loader = CollageLayoutLoader()
        let renders = Counter()
        loader.render = { _, _ in
            await renders.bump()
            return rendered
        }

        loader.start(event: event, day: .wednesday)
        await settle()
        loader.start(event: event, day: .wednesday)
        await settle()

        let count = await renders.value
        XCTAssertEqual(count, 1, "reopening re-rendered, so Dan is shown a "
                       + "different set of options for an unchanged day")
    }

    func testASecondStartIsRefusedWhileOneIsGoing() async throws {
        let event = event()
        let rendered = try candidates(2)
        let loader = CollageLayoutLoader()
        let renders = Counter()
        loader.render = { _, _ in
            await renders.bump()
            try await Task.sleep(for: .milliseconds(200))
            return rendered
        }

        loader.start(event: event, day: .wednesday)
        loader.start(event: event, day: .wednesday)
        await settle()

        let count = await renders.value
        XCTAssertEqual(count, 1)
    }

    func testARenderThatProducedNothingSaysSoRatherThanShowingAnEmptyGrid() async throws {
        // An empty state and an error state are different screens (L10). A day
        // with no photos assigned renders no candidates, and a blank grid tells
        // Dan nothing about why.
        let event = event()
        let loader = CollageLayoutLoader()
        loader.render = { _, _ in [] }

        loader.start(event: event, day: .wednesday)
        await settle()

        let failure = try XCTUnwrap(loader.failure(event: event, day: .wednesday))
        XCTAssertTrue(failure.lowercased().contains("photos"),
                      "the notice does not name what to do about it: \(failure)")
    }

    func testAFailedRenderKeepsItsReasonAfterTheSheetIsClosed() async throws {
        struct Refused: LocalizedError {
            var errorDescription: String? { "ffmpeg is not installed" }
        }
        let event = event()
        let loader = CollageLayoutLoader()
        loader.render = { _, _ in throw Refused() }

        loader.start(event: event, day: .wednesday)
        await settle()

        XCTAssertFalse(loader.isRunning(event: event, day: .wednesday))
        XCTAssertEqual(loader.failure(event: event, day: .wednesday),
                       "ffmpeg is not installed")
    }

    func testAStalledRenderBecomesAnErrorRatherThanASpinnerForever() async throws {
        let event = event()
        let loader = CollageLayoutLoader()
        loader.deadlineForTesting = 0.05
        loader.render = { _, _ in
            try await Task.sleep(for: .seconds(30))
            return []
        }

        loader.start(event: event, day: .wednesday)
        await settle()

        XCTAssertFalse(loader.isRunning(event: event, day: .wednesday))
        let failure = try XCTUnwrap(loader.failure(event: event, day: .wednesday))
        XCTAssertTrue(failure.lowercased().contains("come back"),
                      "a render that never returned was reported as something "
                      + "else: \(failure)")
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }
}
