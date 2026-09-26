import XCTest

/// #1415: the reel length is chosen on a slider in one second steps, from one
/// declaration of the range.
///
/// It was six presets in two menus (15, 20, 30, 40, 50, 60) and a five second
/// slider on the photo assignment screen, three copies of one range. Dan asked
/// to move it a second at a time, and every change to it rebuilds the reel, so
/// the rule for WHEN a change is committed is as much the feature as the step.
final class ReelLengthControlTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Slider: Decodable {
            let min_s: Double
            let max_s: Double
            let step_s: Double
        }
        let slider: Slider
    }

    // MARK: - The range

    func testTheRangeAndStepAreTheOnesTheSharedContractRecords() throws {
        let fixture = try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/scroll_reel_timing.json"))

        XCTAssertEqual(ScrollReelTiming.reelLengthRange.lowerBound, fixture.slider.min_s)
        XCTAssertEqual(ScrollReelTiming.reelLengthRange.upperBound, fixture.slider.max_s)
        XCTAssertEqual(ScrollReelTiming.reelLengthStep, fixture.slider.step_s)
    }

    func testTheStepIsOneSecond() {
        // What Dan asked for, stated on its own so a later re-record of the
        // contract at a coarser step cannot pass by agreeing with itself (L70).
        XCTAssertEqual(ScrollReelTiming.reelLengthStep, 1)
    }

    func testTheLongestReelIsNinetySeconds() {
        // Dan, 2026-09-26: "why are we capping at 60s? can we cap at 90".
        // Nothing downstream set the 60; it was the top of the preset list.
        XCTAssertEqual(ScrollReelTiming.reelLengthRange.upperBound, 90)
        XCTAssertEqual(ScrollReelTiming.reelLengthRange.lowerBound, 15)
    }

    func testTheSpeedNoticeNamesTheTopOfTheSameRange() {
        // The notice decides whether to recommend a length or fewer photos by
        // whether the slider can reach the answer, so its maximum has to be
        // the slider's own.
        XCTAssertEqual(ScrollReelTiming.sliderMaximumSeconds,
                       ScrollReelTiming.reelLengthRange.upperBound)
    }

    // MARK: - When a change is committed

    func testADraggedValueIsCommittedAsAWholeSecond() {
        XCTAssertEqual(ScrollReelTiming.reelLengthToCommit(draft: 37.4, current: 40), 37)
        XCTAssertEqual(ScrollReelTiming.reelLengthToCommit(draft: 37.6, current: 40), 38)
    }

    func testReleasingOnTheCurrentLengthCommitsNothing() {
        // Every commit rebuilds the reel. Grabbing the thumb and letting go
        // where it was must not cost a rebuild, and nor must closing the
        // popover after the release already committed.
        XCTAssertNil(ScrollReelTiming.reelLengthToCommit(draft: 40, current: 40))
        XCTAssertNil(ScrollReelTiming.reelLengthToCommit(draft: 40.3, current: 40))
    }

    func testAValueOutsideTheRangeIsHeldToIt() {
        XCTAssertEqual(ScrollReelTiming.reelLengthToCommit(draft: 3, current: 40), 15)
        XCTAssertEqual(ScrollReelTiming.reelLengthToCommit(draft: 140, current: 40), 90)
    }

    func testAStoredLengthOffTheOldGridIsStillMovable() {
        // Stored reels were set in steps of five or ten; one second from any
        // of them is a real change.
        XCTAssertEqual(ScrollReelTiming.reelLengthToCommit(draft: 41, current: 40), 41)
    }

    // MARK: - One copy of the range

    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// Nothing outside `ScrollReelTiming` writes the range out for itself.
    ///
    /// The range lived in three places before this, and the preset lists were
    /// what a slider would have been added beside rather than instead of
    /// (L613). Comment lines are stripped so prose describing the range cannot
    /// trip it (L103).
    func testNoOtherSourceSpellsOutTheReelLengthRange() throws {
        let copies = try NSRegularExpression(
            pattern: #"reelLengthPresets|\b15(\.0)?\s*\.\.\.\s*60(\.0)?\b"#)
        var offenders: [String] = []
        var scanned = 0
        for entry in RepoFixture.files(under: sourcesDirectory, withExtension: "swift") {
            scanned += 1
            guard !entry.relativePath.hasSuffix("ScrollReelTiming.swift") else { continue }
            let code = try String(contentsOf: entry.url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            if copies.firstMatch(in: code, range: range) != nil {
                offenders.append(entry.relativePath)
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the sweep is not reading Sources at all")
        XCTAssertEqual(offenders, [],
                       "these write the reel length range out themselves rather than "
                       + "reading ScrollReelTiming.reelLengthRange")
    }

    // MARK: - #1420: no tick for every second, and the pace in both popovers

    func testADraggedPositionReadsAsAWholeSecondInsideTheRange() {
        // The slider is continuous so macOS draws no tick for each of its 75
        // steps, and this is what keeps the number and the rebuild on whole
        // seconds anyway.
        XCTAssertEqual(ScrollReelTiming.snappedReelLength(37.4), 37)
        XCTAssertEqual(ScrollReelTiming.snappedReelLength(37.6), 38)
        XCTAssertEqual(ScrollReelTiming.snappedReelLength(3), 15)
        XCTAssertEqual(ScrollReelTiming.snappedReelLength(140), 90)
    }

    /// The popover reads the pace from the reel's own layout file, so the
    /// phone mockup's copy, which knows nothing about the strip, says what the
    /// reel editor's says. Written in the shape `generate_reel_scroll.py`
    /// writes, at DiGangi's measured size (18695px, 149 photographs), which
    /// needs about 63 seconds.
    func testThePaceComesFromTheReelsOwnLayoutFile() throws {
        let cells: [[String: Any]] = (0..<149).map {
            ["photo_path": "/photos/\($0).jpg", "x": 0, "y": $0 * 100, "w": 1080, "h": 100]
        }
        let body: [String: Any] = ["strip_width": 1080, "strip_height": 18695, "cells": cells]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel_preview_layout_\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let layout = try XCTUnwrap(ReelStripLayout.load(from: url), "the layout did not decode")
        let notice = try XCTUnwrap(layout.paceNotice(scrollSeconds: 40), "a 40 second DiGangi reel is too fast")
        XCTAssertEqual(notice, ScrollReelTiming.speedNotice(
            stripHeight: 18695, photoCount: 149, scrollSeconds: 40))
        XCTAssertTrue(notice.contains("Try 63 seconds"), notice)
        XCTAssertNil(layout.paceNotice(scrollSeconds: 70), "70 seconds is comfortable for DiGangi")
    }

    func testAMissingLayoutGivesNoPaceRatherThanAWrongOne() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no_such_layout_\(UUID().uuidString).json")
        XCTAssertNil(ReelStripLayout.load(from: missing))
    }

    func testThePopoverSliderIsNotSteppedSoItDrawsNoTicks() throws {
        let code = try String(contentsOf: sourcesDirectory
            .appendingPathComponent("Views/CaptionReview/ReelLengthPopover.swift"), encoding: .utf8)
        let start = try XCTUnwrap(code.range(of: "Slider("), "the popover has no slider")
        // Up to the trailing editing closure, not the first brace: the value is
        // a Binding whose own closures open with braces, and stopping at the
        // first of those read four words of the call and passed whatever
        // followed them.
        let end = try XCTUnwrap(code[start.upperBound...].range(of: ") { editing in"),
                                "the slider no longer reports the end of a drag")
        let arguments = code[start.upperBound..<end.lowerBound]
        XCTAssertTrue(arguments.contains("ScrollReelTiming.reelLengthRange"),
                      "the span read is not the slider's arguments: \(arguments)")
        XCTAssertFalse(arguments.contains("step:"),
                       "a stepped Slider draws a tick for every second of the range")
    }

    /// Built is not wired (L3, L718): the mockup can take the layout and
    /// still be handed nothing by the one screen that draws it.
    func testThePhoneMockupIsHandedTheReelsLayout() throws {
        let code = try String(contentsOf: sourcesDirectory
            .appendingPathComponent("Views/CaptionReview/CaptionSection.swift"), encoding: .utf8)
        // Every mockup that offers the reel length, not the first one drawn:
        // Tuesday's two come earlier in the file and offer no length at all.
        let calls = code.components(separatedBy: "InstagramMockup(").dropFirst()
            .map { $0.components(separatedBy: "isRegenerating: isRegeneratingGraphic")[0] }
        let offeringLength = calls.filter { $0.contains("onChangeReelLength:") }
        XCTAssertFalse(offeringLength.isEmpty, "no phone mockup offers the reel length any more")
        for call in offeringLength {
            XCTAssertTrue(call.contains("reelLayoutURL: day == .thursday ? thursdayReelLayoutURL : nil"),
                          "a phone mockup offers the reel length without the reel's layout, "
                          + "so its popover has no pace")
        }
    }
}
