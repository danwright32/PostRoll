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

    func testNoDecisionIsDrawnInTheBodyTextColour() throws {
        let sites = try plainButtonSites()
        XCTAssertGreaterThan(sites.count, 40,
                             "the scan found almost no plain buttons, so it has stopped working")

        let offenders = sites.filter { site in
            Self.decisions.contains("\(site.file)|\(site.label)")
                && Self.labelColours.contains(site.colour)
        }.map { "\($0.file): \($0.label) is \($0.colour)" }

        XCTAssertTrue(offenders.isEmpty, """
            These buttons ARE the decision on their screen and are drawn in the \
            same colour as ordinary text, so nothing says they can be pressed:

            \(offenders.joined(separator: "\n"))
            """)
    }

    func testEveryListedDecisionStillExists() throws {
        let sites = try plainButtonSites()
        let present = Set(sites.map { "\($0.file)|\($0.label)" })
        // A plain-styled entry that has since become a filled button is no
        // longer a plain button at all, which is the fix, not a failure.
        let filled = try filledButtonLabels()
        let stale = Self.decisions.filter { !present.contains($0) && !filled.contains($0) }

        XCTAssertTrue(stale.isEmpty, """
            These entries match nothing any more. An entry that has outlived its \
            button silently exempts whatever drifts into its place, so delete them:

            \(stale.joined(separator: "\n"))
            """)
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
