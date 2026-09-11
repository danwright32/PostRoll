import XCTest

/// #1403: the export was the render path that minted no layout seed.
///
/// `ensureReelSeed` had exactly two callers, the photo screen's save and the
/// caption screen's regenerate. The export is a third render path and minted
/// nothing, so a Thursday that had not passed through one of those two screens
/// since #1062 shipped reached Python with no seed. `build_collage_strip`
/// refuses outright rather than reshuffling, so the export died, and the export
/// screen says only that the day's graphics could not be generated: the cause
/// never reached the person reading it.
///
/// Measured in the live store on 2026-09-11, 19 of 21 Thursday days carry no
/// seed, so this was most of the back catalogue rather than one event.
@MainActor
final class ExportReelSeedTests: XCTestCase {

    private var destination: URL!
    private var root: URL!

    override func setUp() async throws {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-seed-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: root)
    }

    private func state(_ events: [Event]) -> AppState {
        AppState(events: events,
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    private func event(thursdaySeed seed: Int?, photos: Int = 3) -> Event {
        var event = Event(name: "DiGangi With A G", org: "", venue: "The Green Room 42",
                          date: Date(timeIntervalSince1970: 1_755_000_000),
                          shootType: .fullShow)
        var pd = PostingDay(day: .thursday)
        pd.reelSeed = seed
        pd.photoPaths = (0..<photos).map { URL(fileURLWithPath: "/tmp/reel-\($0).jpg") }
        event.days = [DayName.thursday.rawValue: pd]
        return event
    }

    private func storedSeed(_ state: AppState, _ id: Event.ID) -> Int? {
        state.events.first(where: { $0.id == id })?
            .days[DayName.thursday.rawValue]?.reelSeed
    }

    // MARK: - The decision itself

    func testAThursdayWithNoSeedGetsOne() {
        var event = self.event(thursdaySeed: nil)
        XCTAssertTrue(event.ensureReelSeedForRender(using: { 4242 }),
                      "a day with no seed is a change the caller has to persist")
        XCTAssertEqual(event.days[DayName.thursday.rawValue]?.reelSeed, 4242)
    }

    func testAThursdayThatAlreadyHasASeedIsLeftAlone() {
        // The whole point. Minting on every export would reshuffle the reel
        // each time it was exported, which is the defect #1062 closed wearing
        // a stored value.
        var event = self.event(thursdaySeed: 111)
        XCTAssertFalse(event.ensureReelSeedForRender(using: { 4242 }),
                       "an unchanged event must not be written back to the store")
        XCTAssertEqual(event.days[DayName.thursday.rawValue]?.reelSeed, 111)
    }

    func testAnEventWithNoThursdayAtAllIsUntouched() {
        // Nothing renders, so there is no layout to decide. Asserted so the
        // fix cannot be written as "always create a Thursday".
        var event = Event(name: "Recital", org: "DCINY", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_755_000_000),
                          shootType: .fullShow)
        XCTAssertFalse(event.ensureReelSeedForRender(using: { 4242 }))
        XCTAssertNil(event.days[DayName.thursday.rawValue])
    }

    // MARK: - Wired into the export, not merely available to it

    func testStartingAnExportPersistsASeedForAThursdayThatHadNone() {
        // Built is not wired (L3). The function above can be perfect and never
        // called, which is exactly the state this issue describes.
        let manager = ExportManager()
        let event = self.event(thursdaySeed: nil)
        let state = self.state([event])

        manager.start(eventID: event.id, to: destination, appState: state,
                      regeneratingDays: [])

        XCTAssertNotNil(storedSeed(state, event.id),
                        "the export dispatches the reel render, so it must decide the layout")
    }

    func testStartingAnExportKeepsTheSeedAThursdayAlreadyHad() {
        // The negative control for the test above. Without it, a fix that
        // stamped a fresh seed on every export would pass that one while
        // relaying out the reel on each export.
        let manager = ExportManager()
        let event = self.event(thursdaySeed: 111)
        let state = self.state([event])

        manager.start(eventID: event.id, to: destination, appState: state,
                      regeneratingDays: [])

        XCTAssertEqual(storedSeed(state, event.id), 111,
                       "an export must not relay out a reel whose layout was already decided")
    }

    func testAnExportRefusedByTheReadinessGateMintsNothing() {
        // Ordering: the gate runs first, so an export that never starts does
        // not mutate the event on its way to being refused.
        let manager = ExportManager()
        let event = self.event(thursdaySeed: nil)
        let state = self.state([event])

        manager.start(eventID: event.id, to: destination, appState: state,
                      regeneratingDays: [.thursday])

        XCTAssertFalse(manager.isExporting(event.id), "the fixture must actually be refused")
        XCTAssertNil(storedSeed(state, event.id),
                     "a refused export decided no layout, so it must write none")
    }
}
