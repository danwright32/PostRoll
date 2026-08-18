import XCTest

/// #492: the bake reads the live event, not a snapshot a caller was holding.
///
/// This is the closure in an otherwise fully swept file that passed a captured
/// event into a destructive background task: it takes the page list off that
/// snapshot and then DELETES those scans once the PDF is verified. Every
/// neighbour re-reads the live event first (#103), and being the odd one out
/// matters more here than anywhere, because the odd one is the one that
/// deletes files.
///
/// A scratch bakery on a scratch AppState, never the shared ones: a test that
/// used those would bake against Dan's real events and delete his real program
/// scans (L2).
@MainActor
final class ProgramPDFBakeryLiveEventTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bakery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func event(withPages count: Int) throws -> Event {
        var event = Event(name: "Vocal Colors", org: "DCINY", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        for page in 0..<count {
            let url = dir.appendingPathComponent("page\(page).png")
            try Data("not really a png".utf8).write(to: url)
            event.programImagePaths.append(url)
        }
        return event
    }

    /// An id the store has never heard of. Nothing to read the pages off, so
    /// nothing starts: the alternative is a bake against a page list that came
    /// from somewhere other than the store it will write back to.
    func testAnEventTheStoreDoesNotHoldStartsNothing() throws {
        let bakery = ProgramPDFBakery()
        let state = AppState(events: [], storeURL: dir.appendingPathComponent("events.json"),
                             dataRoot: dir)

        bakery.bake(eventID: UUID(), appState: state)

        XCTAssertTrue(bakery.baking.isEmpty)
    }

    /// An event whose pages have all been reclaimed has nothing to bake, and
    /// must not start a run that would write an empty PDF over a good one.
    func testAnEventWithNoPagesStartsNothing() throws {
        var event = try event(withPages: 0)
        event.programImagePaths = []
        let bakery = ProgramPDFBakery()
        let state = AppState(events: [event],
                             storeURL: dir.appendingPathComponent("events.json"),
                             dataRoot: dir)

        bakery.bake(eventID: event.id, appState: state)

        XCTAssertTrue(bakery.baking.isEmpty)
    }

    /// The pages come from the STORE. A caller holding a snapshot from before
    /// the pages landed would otherwise have this do nothing at all.
    func testItReadsThePagesOffTheStoreRatherThanACallersCopy() throws {
        let withPages = try event(withPages: 2)
        var stale = withPages
        stale.programImagePaths = []          // what a screen drawn earlier holds
        let bakery = ProgramPDFBakery()
        let state = AppState(events: [withPages],
                             storeURL: dir.appendingPathComponent("events.json"),
                             dataRoot: dir)

        // Called with the id, so the stale copy cannot be what is read.
        bakery.bake(eventID: stale.id, appState: state)

        XCTAssertTrue(bakery.isBaking(stale.id),
                      "the bake read a page list that was not the store's")
    }

    /// A second press while one is in flight is the same work against the same
    /// destination.
    func testASecondCallWhileOneIsRunningIsANoOp() throws {
        let event = try event(withPages: 1)
        let bakery = ProgramPDFBakery()
        let state = AppState(events: [event],
                             storeURL: dir.appendingPathComponent("events.json"),
                             dataRoot: dir)

        bakery.bake(eventID: event.id, appState: state)
        bakery.bake(eventID: event.id, appState: state)

        XCTAssertEqual(bakery.baking.count, 1)
    }

    /// No call site may hand this an Event again, because that is the shape the
    /// staleness came in through.
    func testNoCallerPassesAnEventSnapshot() throws {
        let viewsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: viewsDir, includingPropertiesForKeys: nil)
        var callsSeen = 0
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = SwiftSourceText.withoutComments(
                try String(contentsOf: url, encoding: .utf8))
            callsSeen += text.components(separatedBy: ".bake(eventID:").count - 1
            if text.contains(".bake(event:") { offenders.append(url.lastPathComponent) }
        }

        XCTAssertGreaterThan(callsSeen, 0, "nothing calls the bake, so this checks nothing")
        XCTAssertTrue(offenders.isEmpty,
                      "these pass a captured event into the bake: \(offenders)")
    }
}
