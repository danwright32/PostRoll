import XCTest

/// Every event claims its own folder before anything is written into it (#1450).
///
/// A duplicate keeps its original's name, organisation, venue and date, so both
/// derived one folder name and the copy's first render overwrote the
/// original's week. The claim pins a name at the first write: the derived one,
/// unless another event already resolves to it and this one has nothing on
/// disk, in which case the next free numbered name.
@MainActor
final class EventFolderClaimTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func state(_ events: [Event]) -> AppState {
        AppState(events: events,
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    private func rendered() -> Event {
        var ev = Event(name: "Broadway Undressed", org: "", venue: "54 Below",
                       date: Date(timeIntervalSince1970: 1_789_000_000), shootType: .fullShow)
        ev.previewMediaPaths = ["wednesday": ["collage": "/tmp/collage.png"]]
        return ev
    }

    func testADuplicateRenderedAtOnceGetsTheNextNumberedFolder() throws {
        let original = rendered()
        let state = state([original])
        let base = EventFolder.name(for: original)
        let copyID = try XCTUnwrap(state.duplicateEvent(id: original.id))

        let copy = try XCTUnwrap(state.claimFolder(copyID))

        XCTAssertEqual(EventFolder.name(for: copy), "\(base)_2")
        XCTAssertEqual(state.events.first { $0.id == copyID }?.folderName, "\(base)_2",
                       "the claim has to be saved, or the next write derives again")
    }

    func testTheOriginalKeepsItsFolderWhateverTheCopyResolvesTo() throws {
        // The copy has not claimed yet, so it still resolves to the shared
        // name. The original has a week on disk there and must keep it.
        let original = rendered()
        let state = state([original])
        _ = try XCTUnwrap(state.duplicateEvent(id: original.id))

        let claimed = try XCTUnwrap(state.claimFolder(original.id))

        XCTAssertEqual(claimed.folderName, EventFolder.name(for: original))
    }

    func testADuplicateRenamedFirstKeepsAnOrdinaryName() throws {
        let original = rendered()
        let state = state([original])
        let copyID = try XCTUnwrap(state.duplicateEvent(id: original.id))
        var copy = try XCTUnwrap(state.events.first { $0.id == copyID })
        copy = NewEventForm.edited(copy, name: "Broadway Undressed Night Two",
                                   org: copy.org, venue: copy.venue,
                                   venueContext: copy.venueContext)
        state.updateEvent(copy)

        let claimed = try XCTUnwrap(state.claimFolder(copyID))

        XCTAssertFalse(try XCTUnwrap(claimed.folderName).hasSuffix("_2"))
        XCTAssertTrue(try XCTUnwrap(claimed.folderName).contains("night_two"))
    }

    func testEachFurtherCopyTakesTheNextFreeNumber() throws {
        let original = rendered()
        let state = state([original])
        let base = EventFolder.name(for: original)
        let first = try XCTUnwrap(state.duplicateEvent(id: original.id))
        let second = try XCTUnwrap(state.duplicateEvent(id: original.id))

        let names = [try XCTUnwrap(state.claimFolder(first)).folderName,
                     try XCTUnwrap(state.claimFolder(second)).folderName]

        XCTAssertEqual(names, ["\(base)_2", "\(base)_3"])
    }

    func testAClaimIsKeptOnceMade() throws {
        // A second writer on the same event must land in the same folder as
        // the first, whatever else has changed since.
        let original = rendered()
        let state = state([original])
        let copyID = try XCTUnwrap(state.duplicateEvent(id: original.id))
        let once = try XCTUnwrap(state.claimFolder(copyID)).folderName
        state.events.removeAll { $0.id == original.id }

        XCTAssertEqual(try XCTUnwrap(state.claimFolder(copyID)).folderName, once)
    }

    func testAnEventWithNoRivalPinsTheNameItAlreadyHad() throws {
        // Every event on disk today goes through here on its next render, and
        // must come out writing exactly where it always has.
        let ev = rendered()
        let state = state([ev])

        XCTAssertEqual(try XCTUnwrap(state.claimFolder(ev.id)).folderName,
                       EventFolder.name(for: ev))
    }

    func testClaimingAnEventThatIsGoneAnswersNil() {
        XCTAssertNil(state([]).claimFolder(UUID()))
    }

    // MARK: - Every writer claims first

    /// A call that starts writing an event's files, and the function it sits in.
    private struct WriteSite {
        let file: String
        let function: String
        /// The function's text from its declaration up to the call.
        let before: String
    }

    private static let writeCalls = ["runPreviewGeneration(", "runMediaGeneration(",
                                     "renderPreview("]

    /// Functions that write from an event their caller already claimed, and
    /// that caller. Each is checked below: the caller must claim and then call
    /// it, or the entry excuses nothing (L233).
    private static let handedAClaimedEvent: [String: String] = [
        "runExport": "start",          // ExportManager: start claims, runExport writes
        "startRender": "schedule",     // SpeculativeReelRenderer: schedule claims
    ]

    private func sources() throws -> [(file: String, code: String)] {
        let root = RepoFixture.repoRoot().appendingPathComponent("PostRollApp/Sources")
        return try RepoFixture.files(under: root, withExtension: "swift")
            .filter { !$0.0.hasSuffix("PythonBridge.swift") }
            .map { ($0.0, SwiftSourceText.withoutComments(
                try String(contentsOf: $0.1, encoding: .utf8))) }
    }

    /// Every write call, found from the source rather than listed, so a new
    /// one is covered the day it is written (L96). The test seam's own
    /// declaration is skipped: it is where the real render is plugged in,
    /// not a writer.
    private func writeSites() throws -> [WriteSite] {
        var sites: [WriteSite] = []
        for (file, code) in try sources() {
            for call in Self.writeCalls {
                var searchFrom = code.startIndex
                while let hit = code.range(of: call, range: searchFrom..<code.endIndex) {
                    searchFrom = hit.upperBound
                    let head = code[..<hit.lowerBound]
                    if let seam = head.range(of: "renderPreview: @Sendable", options: .backwards),
                       !head[seam.upperBound...].contains("func ") { continue }
                    guard let decl = head.range(of: "func ", options: .backwards) else { continue }
                    let name = code[decl.upperBound...].prefix { $0.isLetter || $0.isNumber }
                    sites.append(WriteSite(file: file, function: String(name),
                                           before: String(code[decl.lowerBound..<hit.lowerBound])))
                }
            }
        }
        return sites
    }

    private func body(of function: String, in code: String) -> String? {
        guard let start = code.range(of: "func \(function)(") else { return nil }
        let rest = code[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    func testTheWriterSweepFindsTheWriters() throws {
        // The positive control: a sweep that found nothing would pass the
        // check below for every call (L98).
        let sites = try writeSites()
        for (file, count) in [("PreviewGraphicsManager.swift", 3), ("GenerationManager.swift", 1),
                              ("ExportManager.swift", 1), ("SpeculativeReelRenderer.swift", 1)] {
            XCTAssertGreaterThanOrEqual(sites.filter { $0.file.hasSuffix(file) }.count, count,
                                        "\(file) has fewer write calls than it really makes")
        }
    }

    func testEveryWriteClaimsTheFolderFirst() throws {
        // Per call, not per file: a file with three writers passes a
        // whole-file search while one of them skips the claim (L135).
        let missing = try writeSites()
            .filter { !$0.before.contains("claimFolder(") }
            .filter { Self.handedAClaimedEvent[$0.function] == nil }
            .map { "\($0.file) \($0.function)" }

        XCTAssertEqual(missing, [],
                       "these start writing an event's files without claiming its "
                       + "folder first, so a duplicate rendered there writes into "
                       + "its original's week")
    }

    func testEveryWriterHandedAnEventGetsItFromACaller() throws {
        let files = try sources()
        for (writer, caller) in Self.handedAClaimedEvent {
            // The caller in whichever file actually calls this writer, since
            // several types have a function called `start`.
            let callerBody = files.compactMap { body(of: caller, in: $0.code) }
                .first { $0.contains("\(writer)(") }
            let found = try XCTUnwrap(callerBody,
                                      "no \(caller) calls \(writer) any more, so this "
                                      + "entry excuses nothing")
            let beforeCall = found.components(separatedBy: "\(writer)(").first ?? ""
            XCTAssertTrue(beforeCall.contains("claimFolder("),
                          "\(caller) hands \(writer) an event it never claimed")
        }
    }
}
