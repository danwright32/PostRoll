import XCTest

/// #1189: two estimates were chosen and read as measured.
///
/// `BlogSection` showed "~2 to 5 min" for a blog revision and "~1 to 3 min" for
/// a photo swap. Both were picked. Since #1164 they sit beside
/// `RepairRetryEstimate`, which is derived from timed calls, and a chosen figure
/// standing next to a measured one reads as a measurement with nothing at the
/// call site saying otherwise.
///
/// A sweep found four, not two: the caption week and the story graphics are the
/// same shape. Fixing the class rather than the instance (L30).
///
/// ## What this holds
///
/// That every estimate declares where it came from, and that no view goes back
/// to a literal. Not that any particular figure is right: measuring these costs
/// real Claude calls on real photographs, which is Dan's money and Dan's call,
/// and `tools/measure_blog_calls.py` is what spends it when he decides to.
@MainActor
final class RunEstimateTests: XCTestCase {

    func testEveryEstimateSaysWhereItCameFrom() {
        // The whole point. A figure with no provenance is one nobody can tell
        // from a reading, which is the state all four were in.
        XCTAssertGreaterThanOrEqual(RunEstimate.all.count, 4,
                                    "the list of estimates has shrunk, so this "
                                    + "is checking fewer than the app shows")
        for (name, figure) in RunEstimate.all {
            switch figure.provenance {
            case .measured(let fixture):
                XCTAssertFalse(fixture.isEmpty,
                               "\(name) claims to be measured and names no "
                               + "fixture, so the reading cannot be checked")
            case .chosen(let by):
                XCTAssertFalse(by.isEmpty,
                               "\(name) is chosen and names nothing that would "
                               + "measure it, so the entry is a note that it is "
                               + "not ideal rather than a way out of it (L111)")
            case .chosenAndNotYetMeasurable(let because):
                XCTAssertGreaterThan(because.split(separator: " ").count, 8,
                                     "\(name) says it cannot be measured yet "
                                     + "and does not say what is in the way, so "
                                     + "the next person starts from nothing")
            }
        }
    }

    func testAChosenEstimateNamesACommandThatExists() throws {
        // An entry naming a remedy nothing can perform is a dead end dressed as
        // a plan (L111). The tool has to be there.
        let root = RepoFixture.repoRoot()
        for (name, figure) in RunEstimate.all {
            guard case .chosen(let by) = figure.provenance else { continue }
            let tool = String(by.split(separator: " ").first ?? "")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath:
                    root.appendingPathComponent(tool).path),
                "\(name) says it would be measured by \(tool), which is not "
                + "there, so nobody can take the reading it asks for")
        }
    }

    func testSomethingIsStillMeasurable() {
        // The control on the case above. If every estimate were marked "not yet
        // measurable" the checks here would all pass while nothing could ever
        // be measured, which is the state this was written to get out of (L98,
        // L182).
        let measurable = RunEstimate.all.filter {
            if case .chosen = $0.figure.provenance { return true }
            if case .measured = $0.figure.provenance { return true }
            return false
        }

        XCTAssertGreaterThanOrEqual(measurable.count, 3,
                                    "only \(measurable.count) estimates can be "
                                    + "measured at all, so the tool that would "
                                    + "measure them has almost nothing to do")
    }

    func testEveryEstimateReadsAsATimeSomebodyCanActOn() {
        // A range or a duration, in the idiom the panel already uses. A figure
        // in some other shape beside three that are in this one is a fourth
        // thing to parse at a glance (L118).
        for (name, figure) in RunEstimate.all {
            XCTAssertTrue(figure.text.hasPrefix("~"),
                          "\(name) reads \(figure.text), which is not in the "
                          + "shape the other estimates on the panel use")
            XCTAssertTrue(figure.text.contains("min") || figure.text.contains("sec"),
                          "\(name) reads \(figure.text) and names no unit")
        }
    }

    func testNoViewWritesAnEstimateAsALiteral() throws {
        // What keeps this true. A literal at a call site is exactly what the
        // four were, and it is invisible: it reads as a measurement and there
        // is nowhere to look up whether it is one.
        let views = RepoFixture.repoRoot()
            .appendingPathComponent("PostRollApp/Sources/Views")
        var literals: [String] = []
        for (relative, url) in RepoFixture.files(under: views, withExtension: "swift") {
            let code = SwiftSourceText.withoutComments(
                try String(contentsOf: url, encoding: .utf8))
            // The spelling is assembled rather than written, so this file does
            // not itself hold a match for the thing it forbids (L135).
            if code.contains("estimate:" + " \"") { literals.append(relative) }
        }

        XCTAssertTrue(literals.isEmpty,
                      "these pass an estimate as a string literal, so the "
                      + "figure sits beside a measured one with nothing saying "
                      + "which it is (#1189): \(literals)")
    }

    func testTheSweepWouldSeeALiteralIfThereWereOne() {
        // The control (L159). Without it, "no view writes a literal" is
        // satisfied by a scan that has stopped matching, and the four this
        // exists to catch would come back unnoticed.
        let offender = "LongRunIndicator(label: \"x\", estimate:" + " \"~2 min\")"

        XCTAssertTrue(offender.contains("estimate:" + " \""),
                      "the spelling this searches for no longer matches an "
                      + "estimate written as a literal")
    }
}
