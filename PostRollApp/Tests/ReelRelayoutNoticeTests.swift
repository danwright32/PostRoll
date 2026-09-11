import XCTest

/// #1407: a reel that was laid out before layouts were recorded cannot be
/// re-rendered as it stands, and the export re-renders it without saying so.
///
/// A Thursday with any hand adjusted framing is sent to Python on every export
/// rather than copied from the approved preview. When the day has no stored
/// `reelSeed`, that render mints one (#1403) and arranges the photographs
/// differently from the video that was reviewed and posted. Measured in the
/// live store on 2026-09-11: all 21 Thursdays with photos carry crop offsets,
/// so every one re-renders, and 18 of them have no seed.
///
/// It cannot be repaired by backfilling. The original arrangements came from
/// entropy nobody recorded, so they are gone. The only honest remedy is to say
/// so before the render and offer the video that already exists.
@MainActor
final class ReelRelayoutNoticeTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-relayout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A file that is really there, because the question turns on presence.
    private func made(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url.path
    }

    private func event(seed: Int?, assets: [String: String], photos: Int = 3) -> Event {
        var event = Event(name: "DiGangi With A G", org: "", venue: "The Green Room 42",
                          date: Date(timeIntervalSince1970: 1_755_000_000),
                          shootType: .fullShow)
        var pd = PostingDay(day: .thursday)
        pd.reelSeed = seed
        pd.photoPaths = (0..<photos).map { URL(fileURLWithPath: "/tmp/reel-\($0).jpg") }
        event.days = [DayName.thursday.rawValue: pd]
        event.previewMediaPaths = [DayName.thursday.rawValue: assets]
        return event
    }

    // MARK: - When the question is owed

    func testADayWhoseLayoutWasNeverRecordedIsAsked() throws {
        let event = self.event(seed: nil, assets: [
            "reel": try made("reel_scroll.mp4"),
            "reel_preview": try made("reel_preview.png"),
        ])
        let notice = try XCTUnwrap(ReelRelayoutNotice.question(for: event),
                                   "a reel that cannot be reproduced must not be re-rendered silently")
        XCTAssertEqual(notice.day, .thursday)
        XCTAssertTrue(notice.canKeepApproved,
                      "every preview file is on disk, so the approved video really can be kept")
    }

    func testKeepingIsNotOfferedWhenTheCopyWouldNotActuallyHappen() throws {
        // The copy step refuses unless EVERY preview file for the day is there,
        // and a refusal falls straight through to a re-render. So an offer to
        // keep the video, made without checking, would do the opposite of what
        // it says (L111). The question is still asked: the reel still changes.
        let event = self.event(seed: nil, assets: [
            "reel": try made("reel_scroll.mp4"),
            "reel_preview": root.appendingPathComponent("gone.png").path,
        ])
        let notice = try XCTUnwrap(ReelRelayoutNotice.question(for: event))
        XCTAssertFalse(notice.canKeepApproved,
                       "keeping is only offerable when the copy would really be taken")
    }

    // MARK: - When it is not

    func testADayWithARecordedLayoutIsNotAsked() throws {
        // The render reproduces the same arrangement, so there is nothing to
        // warn about and a warning here would be noise on every export.
        let event = self.event(seed: 4242, assets: [
            "reel": try made("reel_scroll.mp4"),
            "reel_preview": try made("reel_preview.png"),
        ])
        XCTAssertNil(ReelRelayoutNotice.question(for: event))
    }

    func testADayWithNoRenderedReelIsNotAsked() throws {
        // Nothing has been approved, so nothing can be lost.
        XCTAssertNil(ReelRelayoutNotice.question(for: self.event(seed: nil, assets: [:])))
    }

    func testAReelRecordedButNoLongerOnDiskIsNotAsked() throws {
        // The path is remembered and the file is gone, so there is no video to
        // offer and nothing to preserve. Asked separately from the empty case
        // because a stored path reads as presence until it is stat'd.
        let event = self.event(seed: nil, assets: [
            "reel": root.appendingPathComponent("gone.mp4").path,
        ])
        XCTAssertNil(ReelRelayoutNotice.question(for: event))
    }

    func testADayWithNoPhotosIsNotAsked() throws {
        var event = self.event(seed: nil, assets: ["reel": try made("reel_scroll.mp4")], photos: 0)
        XCTAssertNil(ReelRelayoutNotice.question(for: event))
        event.days = [:]
        XCTAssertNil(ReelRelayoutNotice.question(for: event))
    }

    // MARK: - What it says

    func testTheQuestionNamesTheConsequenceNotTheMechanism() throws {
        let event = self.event(seed: nil, assets: [
            "reel": try made("reel_scroll.mp4"),
            "reel_preview": try made("reel_preview.png"),
        ])
        let notice = try XCTUnwrap(ReelRelayoutNotice.question(for: event))

        XCTAssertTrue(notice.message.contains("Thursday"), notice.message)
        XCTAssertTrue(notice.message.lowercased().contains("different"),
                      "the consequence is that the reel comes out different: \(notice.message)")
        for jargon in ["seed", "render", "masonry", "entropy"] {
            XCTAssertFalse(notice.message.lowercased().contains(jargon),
                           "the message explains the mechanism, not what happens: \(notice.message)")
        }
    }

    func testTheMessageSaysSoWhenTheApprovedVideoCannotBeKept() throws {
        let event = self.event(seed: nil, assets: [
            "reel": try made("reel_scroll.mp4"),
            "reel_preview": root.appendingPathComponent("gone.png").path,
        ])
        let notice = try XCTUnwrap(ReelRelayoutNotice.question(for: event))
        XCTAssertNotEqual(notice.message,
                          try XCTUnwrap(ReelRelayoutNotice.question(for: self.event(
                            seed: nil,
                            assets: ["reel": try made("r2.mp4"),
                                     "reel_preview": try made("p2.png")]))).message,
                          "a state with no way out must not read identically to one with a way out")
    }

    // MARK: - Wired into the export, not merely available to it

    private func state(_ events: [Event]) -> AppState {
        AppState(events: events,
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    private func destination() throws -> URL {
        let url = root.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func unanswerable() throws -> Event {
        event(seed: nil, assets: ["reel": try made("reel_scroll.mp4"),
                                  "reel_preview": try made("reel_preview.png")])
    }

    func testAnExportStopsAndAsksRatherThanRelayingOutSilently() throws {
        let manager = ExportManager()
        let event = try unanswerable()
        let state = self.state([event])

        manager.start(eventID: event.id, to: try destination(), appState: state,
                      regeneratingDays: [])

        guard case .awaitingReelDecision(let question, _, _)? = manager.run(for: event.id)?.phase
        else { return XCTFail("the export ran without asking, which is the defect") }
        XCTAssertEqual(question.day, .thursday)
        XCTAssertFalse(manager.isExporting(event.id), "nothing may start before it is answered")
    }

    func testAskingDecidesNoLayoutOfItsOwn() throws {
        // Minting the seed is what fixes a new arrangement in place, so it must
        // not happen on the way to asking about it. Otherwise the question is
        // put after the decision it is asking about has been taken (L157).
        let manager = ExportManager()
        let event = try unanswerable()
        let state = self.state([event])

        manager.start(eventID: event.id, to: try destination(), appState: state,
                      regeneratingDays: [])

        XCTAssertNil(state.events.first?.days[DayName.thursday.rawValue]?.reelSeed,
                     "a question about the layout must not settle the layout")
    }

    func testKeepingTheApprovedVideoLeavesTheLayoutUndecided() throws {
        // Nothing renders, so nothing decides an arrangement, so stamping one
        // would be a record of a decision nobody made (L192).
        let manager = ExportManager()
        let event = try unanswerable()
        let state = self.state([event])

        manager.start(eventID: event.id, to: try destination(), appState: state,
                      regeneratingDays: [], reelDecision: .keepApproved)

        XCTAssertNil(state.events.first?.days[DayName.thursday.rawValue]?.reelSeed)
    }

    func testChoosingToMakeItAgainRecordsTheNewLayout() throws {
        // The positive control for the two above. Without it they are satisfied
        // by an export that never records a layout at all, which is the bug
        // #1403 closed (L159).
        let manager = ExportManager()
        let event = try unanswerable()
        let state = self.state([event])

        manager.start(eventID: event.id, to: try destination(), appState: state,
                      regeneratingDays: [], reelDecision: .relayOut)

        XCTAssertNotNil(state.events.first?.days[DayName.thursday.rawValue]?.reelSeed,
                        "a reel made again is one whose arrangement is now written down")
    }

    func testAnEventWithNothingToLoseIsNeverAsked() throws {
        // The gate does not fire when it should not. A question on every export
        // is how a real one stops being read.
        let manager = ExportManager()
        let event = self.event(seed: 4242, assets: ["reel": try made("reel_scroll.mp4")])
        let state = self.state([event])

        manager.start(eventID: event.id, to: try destination(), appState: state,
                      regeneratingDays: [])

        if case .awaitingReelDecision? = manager.run(for: event.id)?.phase {
            XCTFail("a reel whose arrangement is recorded comes out the same, so say nothing")
        }
    }

    func testARunWaitingOnAnAnswerCannotBeCancelled() throws {
        // Nothing has started, so there is nothing to stop, and a cancel that
        // reported success would claim it had stopped work that never ran.
        let manager = ExportManager()
        let event = try unanswerable()
        let state = self.state([event])

        manager.start(eventID: event.id, to: try destination(), appState: state,
                      regeneratingDays: [])

        XCTAssertFalse(manager.cancel(eventID: event.id))
    }

    // MARK: - The way out looks like one

    func testTheOnlyWayForwardIsDrawnAsTheMainControl() {
        // With nothing to choose between, a plain link is the whole screen's
        // route out and does not read as a control at all (L49).
        XCTAssertTrue(ReelRelayoutChoice(message: "m", canKeepApproved: false).relayOutIsPrimary)
    }

    func testTheUndoableChoiceLeadsWhenThereIsOne() {
        // And where there IS a choice, the one that cannot be undone is not the
        // emphasised one.
        XCTAssertFalse(ReelRelayoutChoice(message: "m", canKeepApproved: true).relayOutIsPrimary)
    }
}
