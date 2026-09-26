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
}
