import XCTest

/// The claim's answer must not be thrown away.
///
/// This is the half a behaviour test cannot reach: `beginDayRegen` already
/// answers correctly, and every defect here was a caller that never looked.
/// Marking the answer discardable means the compiler will not say who, so this
/// does.
final class RebuildClaimScanTests: XCTestCase {

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

    /// The claims whose answer decides whether a run may start at all.
    private static let claims = ["beginDayRegen(", "beginCoverRegen(", "beginFullRun(",
                                 "beginThursdayEditorBuild("]

    /// Lines that CALL a claim and do nothing with what it said.
    ///
    /// A bare call as a statement is the whole defect. A `guard`, an `if`, an
    /// assignment or a `return` all keep the answer, which is the only thing
    /// that matters here.
    static func discardedClaims(_ text: String) -> [String] {
        var offenders: [String] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.hasPrefix("///") else { continue }
            guard Self.claims.contains(where: { line.contains($0) }) else { continue }
            let kept = line.hasPrefix("guard ") || line.hasPrefix("if ")
                || line.hasPrefix("return ") || line.hasPrefix("let ")
                || line.hasPrefix("var ") || line.contains("= ")
                || line.hasPrefix("&& ") || line.hasPrefix("|| ")
            if !kept { offenders.append("line \(index + 1): \(line)") }
        }
        return offenders
    }

    func testNoScreenStartsARunWithoutClaimingItFirst() throws {
        var offenders: [String] = []
        for url in try Self.viewSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for offence in Self.discardedClaims(text) {
                offenders.append("\(url.lastPathComponent) \(offence)")
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            These calls ask whether the work can start and throw the answer \
            away: \(offenders.joined(separator: "; ")).

            A refused claim means something else is already writing those files. \
            Check it, and check it BEFORE persisting anything the run is for, so \
            a refusal leaves the event as it was rather than describing a \
            rebuild that never happened.
            """)
    }

    func testTheScannerCanStillSeeOne() {
        // The control. Every offender this was written for is gone, and an empty
        // answer from a scanner that has stopped matching looks exactly the same
        // (L98, L1).
        XCTAssertEqual(
            Self.discardedClaims("        graphics.beginDayRegen(day, for: event.id)\n"),
            ["line 1: graphics.beginDayRegen(day, for: event.id)"])
    }

    func testAClaimThatIsCheckedIsNoneOfItsBusiness() {
        // The other control, on the four shapes that keep the answer.
        let innocent = """
        guard graphics.beginDayRegen(day, for: event.id) else { return }
        if graphics.beginCoverRegen(day, for: event.id) { run() }
        let claimed = PreviewGraphicsManager.shared.beginFullRun(id)
        return graphics.beginThursdayEditorBuild(id)
        """
        XCTAssertEqual(Self.discardedClaims(innocent), [])
    }

    func testACommentAboutAClaimIsNotACall() {
        let commented = "        // graphics.beginDayRegen(day, for: event.id) used to sit here\n"
        XCTAssertEqual(Self.discardedClaims(commented), [])
    }
}
