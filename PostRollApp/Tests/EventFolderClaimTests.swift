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

    /// The places that start writing an event's files, found from the source
    /// rather than listed, so a new one is covered the day it is written (L96).
    private func writers() throws -> [String] {
        let services = RepoFixture.repoRoot().appendingPathComponent("PostRollApp/Sources")
        var found: [String] = []
        for (relative, url) in RepoFixture.files(under: services, withExtension: "swift") {
            guard !relative.hasSuffix("PythonBridge.swift") else { continue }
            let code = SwiftSourceText.withoutComments(try String(contentsOf: url, encoding: .utf8))
            let calls = ["runPreviewGeneration(", "runMediaGeneration(", "renderPreview("]
            if calls.contains(where: code.contains) { found.append(relative) }
        }
        return found.sorted()
    }

    func testTheWriterSweepFindsTheWriters() throws {
        // The positive control: a sweep that found nothing would pass the
        // check below for every file (L98).
        let found = try writers()
        for expected in ["GenerationManager.swift", "ExportManager.swift",
                         "PreviewGraphicsManager.swift", "SpeculativeReelRenderer.swift"] {
            XCTAssertTrue(found.contains { $0.hasSuffix(expected) },
                          "\(expected) was not found among \(found)")
        }
    }

    func testEveryWriterClaimsTheFolderFirst() throws {
        let missing = try writers().filter { relative in
            let url = RepoFixture.repoRoot().appendingPathComponent("PostRollApp/Sources")
                .appendingPathComponent(relative)
            let code = SwiftSourceText.withoutComments(
                (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            return !code.contains("claimFolder(")
        }

        XCTAssertEqual(missing, [],
                       "these start writing an event's files without claiming its "
                       + "folder, so a duplicate rendered there writes into its "
                       + "original's week")
    }
}
