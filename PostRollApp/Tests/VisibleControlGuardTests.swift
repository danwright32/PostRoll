import XCTest

/// #395: an action that IS the decision on its screen has to look like a
/// control at rest.
///
/// Found by rendering the halt screen (#393): its free option was a `Button`
/// with `.buttonStyle(.plain)` in the body text colour, so it read as a heading
/// above its own explanation while the option that spends money was the only
/// thing shaped like a button.
///
/// Deliberately narrow. A `Cancel` beside a filled primary in a sheet is read
/// correctly by convention and is not listed here; 35 more plain buttons carry
/// the rose accent and read as links, which is also fine. What this guards is
/// the case where the bare-text button is the choice being offered, and nothing
/// on screen says it can be pressed.
///
/// The list is named rather than derived, and the check runs in both directions:
/// an entry that no longer matches fails too, because a stale allowlist quietly
/// exempts whatever drifts into its place (L96).
final class VisibleControlGuardTests: XCTestCase {

    /// `file|button label` for every action that is the decision on its screen.
    /// None of these may be drawn in the body text colour.
    private static let decisions = [
        "AssetGenerationView.swift|Use previous results",
        "AssetGenerationView.swift|Regenerate all",
        "CaptionReviewView.swift|Re-cut with AI",
        "ExportView.swift|Skip, text export only",
        "OCRReviewView.swift|Keep OCR Text",
        "PhotoAssignmentView.swift|Remove missing",
        "ProgramUploadView.swift|No program",
    ]

    /// `file|button label` for every control that SPENDS MONEY.
    ///
    /// A separate rule from `decisions`, and separate because the two answer
    /// different questions. A paid action is often not the decision on its
    /// screen: `Approve & Export` is the decision on caption review, and
    /// `Continue to Review` is on the generation done screen, so the paid
    /// actions beside them are deliberately quieter and do not want a filled or
    /// outlined control. What they cannot be is invisible. Body-colour text
    /// gets found by clicking words to see what happens, which is how a paid
    /// run gets started by accident.
    ///
    /// The app's established quiet-but-visible treatment is the rose accent,
    /// which is what every sibling of these two already wears.
    private static let paidActions = [
        "AssetGenerationView.swift|Regenerate blog post",
        "CaptionReviewView.swift|Regenerate All…",
    ]

    /// Colours that are the same as ordinary text, so a control wearing one is
    /// indistinguishable from a label.
    private static let labelColours = ["warmMid", "warmDark", "warmFaint"]

    private var viewsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
    }

    /// Every `.buttonStyle(.plain)` site, as `file|label|colour`.
    ///
    /// Reads the whole modifier chain around the style, both directions: the
    /// first version of this scan looked only forwards and reported four
    /// accent-coloured buttons as label-coloured, because their colour was set
    /// before the style rather than after.
    private func plainButtonSites() throws -> [(file: String, label: String, colour: String)] {
        var sites: [(String, String, String)] = []
        for url in try FileManager.default.contentsOfDirectory(at: viewsDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "swift" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (i, line) in lines.enumerated() {
                guard line.contains("buttonStyle(.plain)"),
                      !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }

                var label: String?
                for j in stride(from: i, through: max(0, i - 8), by: -1) {
                    if let r = lines[j].range(of: #"Button\("[^"]+""#, options: .regularExpression) {
                        label = String(lines[j][r]).replacingOccurrences(of: "Button(\"", with: "")
                            .replacingOccurrences(of: "\"", with: "")
                        break
                    }
                }
                guard let label else { continue }   // icon buttons carry no text

                var start = i, end = i
                while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix(".") { start -= 1 }
                while end + 1 < lines.count, lines[end + 1].trimmingCharacters(in: .whitespaces).hasPrefix(".") { end += 1 }
                let chain = lines[start...end].joined(separator: "\n")
                var colour = "unset"
                if let r = chain.range(of: #"foregroundStyle\(\s*Color\.\w+"#, options: .regularExpression) {
                    colour = String(chain[r]).components(separatedBy: "Color.").last ?? "unset"
                }
                sites.append((url.lastPathComponent, label, colour))
            }
        }
        return sites
    }

    // MARK: - The two rules, each run in both directions

    func testNoDecisionIsDrawnInTheBodyTextColour() throws {
        try assertNoneWearALabelColour(
            Self.decisions,
            because: "These buttons ARE the decision on their screen and are drawn in the "
                   + "same colour as ordinary text, so nothing says they can be pressed")
    }

    func testNoPaidActionIsDrawnInTheBodyTextColour() throws {
        try assertNoneWearALabelColour(
            Self.paidActions,
            because: "These buttons SPEND MONEY and are drawn in the same colour as ordinary "
                   + "text, so the only way to discover them is to click words and find out")
    }

    func testEveryListedDecisionStillExists() throws {
        try assertNothingIsStale(Self.decisions)
    }

    func testEveryListedPaidActionStillExists() throws {
        try assertNothingIsStale(Self.paidActions)
    }

    // MARK: - Shared checks

    /// One implementation for both registries, because two copies of this drift
    /// and only one of them gets the next fix.
    private func assertNoneWearALabelColour(_ registry: [String], because reason: String,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) throws {
        let sites = try plainButtonSites()
        XCTAssertGreaterThan(sites.count, 40,
                             "the scan found almost no plain buttons, so it has stopped working",
                             file: file, line: line)

        let offenders = sites.filter { site in
            registry.contains("\(site.file)|\(site.label)")
                && Self.labelColours.contains(site.colour)
        }.map { "\($0.file): \($0.label) is \($0.colour)" }

        XCTAssertTrue(offenders.isEmpty, """
            \(reason):

            \(offenders.joined(separator: "\n"))
            """, file: file, line: line)
    }

    /// The other direction: an entry that has outlived its button.
    private func assertNothingIsStale(_ registry: [String],
                                     file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        let sites = try plainButtonSites()
        let present = Set(sites.map { "\($0.file)|\($0.label)" })
        // A plain-styled entry that has since become a filled button is no
        // longer a plain button at all, which is the fix, not a failure.
        let filled = try filledButtonLabels()
        let stale = registry.filter { !present.contains($0) && !filled.contains($0) }

        XCTAssertTrue(stale.isEmpty, """
            These entries match nothing any more. An entry that has outlived its \
            button silently exempts whatever drifts into its place, so delete them:

            \(stale.joined(separator: "\n"))
            """, file: file, line: line)
    }

    /// `file|label` for buttons wearing one of the app's real control styles.
    private func filledButtonLabels() throws -> Set<String> {
        var found: Set<String> = []
        for url in try FileManager.default.contentsOfDirectory(at: viewsDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "swift" }) {
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (i, line) in lines.enumerated() {
                guard line.contains("BrandButtonStyle()") || line.contains("BrandOutlineButtonStyle()") else { continue }
                for j in stride(from: i, through: max(0, i - 8), by: -1) {
                    if let r = lines[j].range(of: #"Button\("[^"]+""#, options: .regularExpression) {
                        let label = String(lines[j][r]).replacingOccurrences(of: "Button(\"", with: "")
                            .replacingOccurrences(of: "\"", with: "")
                        found.insert("\(url.lastPathComponent)|\(label)")
                        break
                    }
                }
            }
        }
        return found
    }
}
