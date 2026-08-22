import Foundation
import XCTest

/// A Friday reel that came back with no title has to say so (#824).
///
/// The title card is a finishing touch, so a failure must not cost the reel
/// already rendered. What it must not be is silent: both Python call sites used
/// to print the reason and carry on, and a printed line is gone with the
/// process, so a reel Dan posted untitled looked exactly like one he chose to
/// have no title on.
///
/// Two halves are checked here. The recording itself, which is on `Event` so
/// that both screens reporting it share one rule about clearing. And the wiring,
/// because a screen can still take the reason off a render result and drop it,
/// and the compiler has nothing to say about that.
final class UntitledReelReportTests: XCTestCase {

    private func eventWithFriday() -> Event {
        var event = Event(name: "Sing Play", org: "Org", venue: "Hall",
                          date: Date(), shootType: .fullShow)
        event.days["friday"] = PostingDay(day: .friday)
        return event
    }

    // MARK: - The recording

    func testAnUntitledReelIsRecordedAsAWarningNotAFailure() {
        var event = eventWithFriday()

        let changed = event.recordMediaOutcome(
            day: "friday", error: nil,
            warning: "title card skipped, so the reel carries no title: ffmpeg failed")

        XCTAssertTrue(changed)
        XCTAssertEqual(event.mediaWarnings["friday"],
                       "title card skipped, so the reel carries no title: ffmpeg failed")
        // Not an error: the reel is on disk and the export folder is complete.
        // Filing this as a failure would suppress an export over a finishing
        // touch, which is the worse of the two mistakes.
        XCTAssertNil(event.mediaErrors["friday"])
    }

    func testTheNextRenderClearsANoteItHasNothingToSayAbout() {
        var event = eventWithFriday()
        event.mediaWarnings["friday"] = "title card skipped, so the reel carries no title: ffmpeg failed"

        let changed = event.recordMediaOutcome(day: "friday", error: nil, warning: nil)

        XCTAssertTrue(changed)
        XCTAssertNil(event.mediaWarnings["friday"],
                     "a note kept past the render it was about is not stale, it is false")
    }

    func testARenderThatSaysTheSameThingTwiceIsNotAChange() {
        var event = eventWithFriday()
        event.mediaWarnings["friday"] = "same"

        XCTAssertFalse(event.recordMediaOutcome(day: "friday", error: nil, warning: "same"),
                       "an unchanged outcome must not report a change, or every render saves")
    }

    func testAFailureAndANoteAreKeptApart() {
        var event = eventWithFriday()
        event.recordMediaOutcome(day: "friday", error: "clip reel skipped: ffmpeg died",
                                 warning: "title card skipped, so the reel carries no title: x")

        XCTAssertEqual(event.mediaErrors["friday"], "clip reel skipped: ffmpeg died")
        XCTAssertEqual(event.mediaWarnings["friday"],
                       "title card skipped, so the reel carries no title: x")
    }

    func testOneDaysOutcomeIsNotAnothers() {
        var event = eventWithFriday()
        event.days["wednesday"] = PostingDay(day: .wednesday)
        event.recordMediaOutcome(day: "friday", error: nil, warning: "untitled")

        XCTAssertNil(event.mediaWarnings["wednesday"])
    }

    // MARK: - What the parser hands the screen

    func testTheReasonSurvivesTheParserItArrivesThrough() {
        let parsed = PythonBridge.parseFridayOverrideOutput([
            "reel": "/p/reel.mp4",
            "title_card_skipped": "title card skipped, so the reel carries no title: no such filter",
        ])
        XCTAssertEqual(parsed?.titleCardSkipped,
                       "title card skipped, so the reel carries no title: no such filter")
    }

    // MARK: - The wiring

    private static func viewSources() throws -> [URL] {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
        return (FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every mention of the reason in a screen, with whether it is being handed
    /// to a recording call.
    ///
    /// Brace balanced from the recording call rather than read line by line: the
    /// argument sits on its own line under `recordMediaOutcome(`, and a per-line
    /// scan would see the call on one line and the reason on the next and match
    /// neither (L135, L178).
    private static func mentionsNotRecorded(_ text: String) -> [String] {
        var recordedRanges: [Range<String.Index>] = []
        var search = text.startIndex
        while let call = text.range(of: "recordMediaOutcome(", range: search..<text.endIndex) {
            search = call.upperBound
            var depth = 1
            var i = call.upperBound
            while i < text.endIndex, depth > 0 {
                if text[i] == "(" { depth += 1 }
                if text[i] == ")" { depth -= 1 }
                i = text.index(after: i)
            }
            recordedRanges.append(call.upperBound..<i)
        }

        var stray: [String] = []
        var from = text.startIndex
        while let mention = text.range(of: "titleCardSkipped", range: from..<text.endIndex) {
            from = mention.upperBound
            guard !recordedRanges.contains(where: { $0.contains(mention.lowerBound) }) else { continue }
            let line = text[text.startIndex..<mention.lowerBound].filter { $0 == "\n" }.count + 1
            stray.append("line \(line)")
        }
        return stray
    }

    func testAScreenThatReadsTheReasonHandsItToTheRecording() throws {
        var mentions = 0
        var offenders: [String] = []
        for url in try Self.viewSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            mentions += text.components(separatedBy: "titleCardSkipped").count - 1
            offenders += Self.mentionsNotRecorded(text).map { "\(url.lastPathComponent) \($0)" }
        }

        // A scan that matched nothing is not a pass: if the screen stops reading
        // the reason at all, this check has to fail rather than go quiet (L98).
        XCTAssertGreaterThan(mentions, 0,
                             "no screen reads the reason a reel came back untitled, so nothing "
                             + "tells Dan about it and this check is measuring nothing")
        XCTAssertTrue(offenders.isEmpty,
                      "the reason a reel has no title is read and then not recorded at "
                      + "\(offenders.joined(separator: ", ")), so it reaches no surface")
    }
}
