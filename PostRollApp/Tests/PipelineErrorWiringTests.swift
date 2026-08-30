import Foundation
import XCTest

/// A day's rebuild failure keeps the pipeline's own error, not just prose (#730).
///
/// `generate_media.py` marks the "< 3 usable clips" case with an
/// `insufficient_clips:` PREFIX, deliberately, so the Friday card can offer the
/// two ways out of a state that will fail identically on every retry. The screen
/// wrapped that error into "Friday regeneration failed: …" before recording it,
/// so the prefix sat mid sentence, the card's check never matched, and the one
/// failure with an escape hatch was the one shown without it.
///
/// `PreviewGraphicsManager` now keeps the pipeline's text alongside the sentence,
/// and `FridayReviewDisplay` reads the typed failure rather than a string, so
/// prose cannot be handed to the check by mistake. What that leaves is this: a
/// screen can still choose the wrong recording call, and the compiler has
/// nothing to say about it. That is what this scans for.
final class PipelineErrorWiringTests: XCTestCase {

    private static func viewSources() throws -> [URL] {
        // Services as well as Views since #1010. Recording a day's failure
        // used to happen only on a screen; the day scoped redraw put it on the
        // manager too, which moved it straight out from under this scan. A
        // guard scoped to where the code WAS is exempt from wherever it goes
        // next (L247).
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return ["Sources/Views", "Sources/Services"].flatMap { folder -> [URL] in
            let dir = root.appendingPathComponent(folder)
            return (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? [])
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// How a per-day error from the Python side is named where it is read.
    ///
    /// Both spellings, because the wrapping that shipped bound it to a local
    /// first and a rule reading only the subscript would have passed it.
    private static let pipelineErrorNames = ["pyError", "pipelineError", "result.errors["]

    /// Calls that record a rebuild failure by folding a pipeline error into a
    /// sentence, losing the marker the card matches on.
    ///
    /// Brace balanced from the call rather than line by line: the wrapping that
    /// shipped spanned two lines, and a per-line scan saw a `reason:` on one and
    /// the error on the next and matched neither (L135, L178).
    static func wrappedPipelineErrors(_ text: String) -> [String] {
        var offenders: [String] = []
        var search = text.startIndex
        while let call = text.range(of: "failDayRegen(", range: search..<text.endIndex) {
            search = call.upperBound
            var depth = 1
            var i = call.upperBound
            while i < text.endIndex, depth > 0 {
                if text[i] == "(" { depth += 1 }
                if text[i] == ")" { depth -= 1 }
                i = text.index(after: i)
            }
            let arguments = String(text[call.upperBound..<i])
            guard arguments.contains("reason:") else { continue }
            guard Self.pipelineErrorNames.contains(where: { arguments.contains($0) })
            else { continue }
            let line = text[text.startIndex..<call.lowerBound]
                .filter { $0 == "\n" }.count + 1
            offenders.append("line \(line): "
                + arguments.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " "))
        }
        return offenders
    }

    func testNoScreenFoldsAPipelineErrorIntoAFailureSentence() throws {
        var offenders: [String] = []
        for url in try Self.viewSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for offence in Self.wrappedPipelineErrors(text) {
                offenders.append("\(url.lastPathComponent) \(offence)")
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            These record a rebuild failure by wrapping the Python side's own \
            error into a sentence: \(offenders.joined(separator: "; ")).

            The pipeline marks the cases it has a remedy for with a prefix, and \
            a prefix buried inside prose is a prefix nothing can match, so the \
            card that offers the way out never appears. Record it with \
            failDayRegen(_:for:pipelineError:), which keeps the marker and builds \
            the sentence from it.
            """)
    }

    func testTheScannerCanStillSeeOne() {
        // The control. This is the exact shape that shipped, over two lines,
        // and a scanner that had stopped matching would report every screen
        // clean while the banner stayed unreachable (L98, L1).
        let offender = """
                    graphics.failDayRegen(day, for: event.id,
                                          reason: "\\(day.displayName) regeneration failed: \\(pyError)")
        """
        XCTAssertEqual(Self.wrappedPipelineErrors(offender).count, 1)
    }

    func testAReasonWithNoPipelineErrorInItIsNoneOfItsBusiness() {
        // The other control, and the reason this is not a ban on `reason:`. A
        // swap that could not fetch a track, or a run that produced no output,
        // has no pipeline marker to keep: those failures are prose by nature,
        // and a rule that moved them too would be unusable and turned off
        // (L104).
        let innocent = """
                    graphics.failDayRegen(
                        day, for: event.id,
                        reason: "\\(day.displayName) audio swap failed: "
                              + "\\(error.localizedDescription)")
                    graphics.failDayRegen(
                        day, for: event.id,
                        reason: "\\(day.displayName) regeneration produced no output")
        """
        XCTAssertEqual(Self.wrappedPipelineErrors(innocent), [])
    }

    func testRecordingThePipelineErrorItselfIsNoneOfItsBusiness() {
        // The fixed shape, which must not read as an offence, or the rule would
        // fail the very call it exists to send people to.
        let fixed = """
                    graphics.failDayRegen(day, for: event.id, pipelineError: pyError)
        """
        XCTAssertEqual(Self.wrappedPipelineErrors(fixed), [])
    }
}
