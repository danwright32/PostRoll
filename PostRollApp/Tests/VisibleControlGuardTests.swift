import XCTest
import SwiftUI
import AppKit

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
    /// The `*Bodies` files are where the presentational half of each screen now
    /// lives (#396), which is also where these controls are drawn.
    private static let decisions = [
        "GenerationScreenBodies.swift|Use previous results",
        "GenerationScreenBodies.swift|Regenerate all",
        "FridayClipEditor.swift|Re-cut with AI",
        "ExportView.swift|Skip, text export only",
        "OCRReviewView.swift|Keep OCR Text",
        "PhotoAssignmentBodies.swift|Remove missing",
        "ProgramUploadView.swift|No program",
        // Came into view with the subfolder walk (#583). It is the only thing
        // offered when a search empties the post list, so it is that state's
        // whole way out.
        "InsightsPostsView.swift|Clear Search",
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
        "GenerationScreenBodies.swift|Regenerate blog post",
        "CaptionReviewBodies.swift|Regenerate All…",
    ]

    /// Colours that are the same as ordinary text, so a control wearing one is
    /// indistinguishable from a label.
    private static let labelColours: [Color] = [.warmMid, .warmDark, .warmFaint]

    /// Whether a colour written at a call site is one of those.
    ///
    /// Two spellings reach here: the token itself, and a name from
    /// `PaintedSurfaces`, which is how every accent is written since #580.
    /// Resolving only the first would read a named colour as "nothing set",
    /// which can never offend, so this guard would go quietly blind on exactly
    /// the sites the naming moved. A name that resolves to nothing is a failure
    /// rather than a pass, for the same reason (L42).
    private func isLabelColour(_ written: String) throws -> Bool {
        if let colour = Self.resolve(written) {
            return Self.labelColours.contains { same($0, colour) }
        }
        if written == "unset" { return false }
        XCTFail("""
            \(written) is drawn on a plain button and this check cannot resolve it to a \
            colour, so it cannot tell whether that button looks like a label. Add it to \
            PaintedSurfaces.byName.
            """)
        return false
    }

    /// A colour as written at a call site, or nil when this cannot say.
    ///
    /// Nil is what the caller turns into a failure. Kept separate from the
    /// judgement so the nil path can be exercised: a fail-closed branch nobody
    /// has watched behave is a branch nobody knows works (L1).
    static func resolve(_ written: String) -> Color? {
        if written.hasPrefix("PaintedSurfaces.") {
            return PaintedSurfaces.byName[String(written.dropFirst("PaintedSurfaces.".count))]
        }
        if written.hasPrefix("Color.") {
            return token(named: String(written.dropFirst("Color.".count)))
        }
        return nil
    }

    /// The palette tokens this rule is about, by the name a call site writes.
    /// Only the ones that matter here: anything else resolves through
    /// `PaintedSurfaces.byName` or fails above.
    private static func token(named name: String) -> Color? {
        ["warmMid": Color.warmMid, "warmDark": .warmDark, "warmFaint": .warmFaint,
         "roseGold": .roseGold, "roseDeep": .roseDeep, "roseButton": .roseButton,
         "cream": .cream, "creamDeep": .creamDeep, "creamEdge": .creamEdge,
         "hairline": .hairline, "white": .white, "black": .black,
         "primary": .primary, "secondary": .secondary, "clear": .clear][name]
    }

    private func same(_ a: Color, _ b: Color) -> Bool {
        guard let one = NSColor(a).usingColorSpace(.sRGB),
              let two = NSColor(b).usingColorSpace(.sRGB) else { return false }
        return abs(one.redComponent - two.redComponent) < 0.001
            && abs(one.greenComponent - two.greenComponent) < 0.001
            && abs(one.blueComponent - two.blueComponent) < 0.001
            && abs(one.alphaComponent - two.alphaComponent) < 0.001
    }

    private var viewsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
    }

    /// Every view file, at any depth (#583).
    ///
    /// This used to be `contentsOfDirectory`, which does not descend, so
    /// `Sources/Views/Insights/` was outside every rule in this file and any
    /// screen put in a new subfolder was exempt on arrival. Nothing reported
    /// it: a scan that reads fewer files simply finds fewer subjects, and
    /// finding nothing to object to is what passing looks like (L98).
    private func viewFiles() throws -> [URL] {
        try FileManager.default
            .subpathsOfDirectory(atPath: viewsDir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { viewsDir.appendingPathComponent($0) }
    }

    /// Every `.buttonStyle(.plain)` site, as `file|label|colour`.
    ///
    /// Reads the whole modifier chain around the style, both directions: the
    /// first version of this scan looked only forwards and reported four
    /// accent-coloured buttons as label-coloured, because their colour was set
    /// before the style rather than after.
    private func plainButtonSites() throws -> [(file: String, label: String, colour: String)] {
        var sites: [(String, String, String)] = []
        for url in try viewFiles() {
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
                // Both spellings: the palette token, and a name from
                // PaintedSurfaces, which is how the accent is written since
                // #580. Matching only the first left every renamed site reading
                // as "unset", which no rule below can ever object to.
                if let r = chain.range(of: #"foregroundStyle\(\s*(Color|PaintedSurfaces)\.\w+"#,
                                       options: .regularExpression) {
                    colour = String(chain[r])
                        .replacingOccurrences(of: #"foregroundStyle\(\s*"#, with: "",
                                              options: .regularExpression)
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

    /// The resolver decides whether this whole file can see anything, so its
    /// answers are checked rather than assumed. A name it cannot resolve has to
    /// come back nil, which the caller turns into a failure: reading it as "no
    /// colour set" instead is how a guard goes green while blind (#580).
    func testTheColourResolverAnswersForBothSpellingsAndRefusesTheRest() {
        XCTAssertEqual(Self.resolve("PaintedSurfaces.pageAccentText"),
                       PaintedSurfaces.pageAccentText)
        XCTAssertEqual(Self.resolve("Color.warmMid"), Color.warmMid)
        XCTAssertNil(Self.resolve("PaintedSurfaces.aNameNobodyDeclared"),
                     "an unresolvable name has to be reported as unresolvable, not as "
                     + "some colour this check is then happy about")
        XCTAssertNil(Self.resolve("someLocal"))
    }

    /// The scan reads the whole view tree, not just its top level (#583).
    ///
    /// Both rules above are only as wide as what this walk hands them, and a
    /// walk that stops descending reports every screen it never opened as
    /// clean. The count floor inside the rules cannot catch that: 56 of the 57
    /// labelled sites are at the top level, so dropping a subfolder moves the
    /// number by one and every floor still holds.
    ///
    /// The expected side is enumerated separately from the walk under test,
    /// because a check whose two halves come from one lookup can only prove
    /// that lookup agrees with itself (L70).
    func testTheScanReadsEveryViewFileIncludingTheSubfolders() throws {
        let expected = try expectedViewFiles()

        // Finding nothing to compare against is not a pass (L98). If the
        // expected side ever went blind this test would agree with any walk.
        XCTAssertTrue(expected.contains { $0.hasPrefix("Insights/") }, """
            the expected file list contains nothing under a subfolder, so it \
            cannot tell a walk that descends from one that does not. Either \
            Sources/Views has no subfolders any more, or this enumeration has \
            stopped working.
            """)

        let read = Set(try viewFiles().map { $0.path })
        let missing = expected
            .filter { !read.contains(viewsDir.appendingPathComponent($0).path) }
            .sorted()

        XCTAssertTrue(missing.isEmpty, """
            The scan behind every rule in this file never opens these view \
            files, so whatever they draw is exempt from all of them and \
            nothing says so:

            \(missing.joined(separator: "\n"))
            """)
    }

    /// Two files sharing a name would be one entry to every registry here,
    /// because a site is keyed by `lastPathComponent`. Harmless while the walk
    /// read one folder; once it descends, the second file silently inherits
    /// the first one's listing and can never be found stale.
    func testNoTwoViewFilesShareAName() throws {
        var seen: [String: [String]] = [:]
        for relative in try expectedViewFiles() {
            seen[(relative as NSString).lastPathComponent, default: []].append(relative)
        }
        let collisions = seen.values.filter { $0.count > 1 }.map { $0.sorted().joined(separator: " and ") }

        XCTAssertTrue(collisions.isEmpty, """
            These view files share a name, and every registry in this file \
            keys on the name alone, so one of them silently answers for the \
            other:

            \(collisions.sorted().joined(separator: "\n"))
            """)
    }

    /// Every view file, enumerated by a different route from `viewFiles()`.
    private func expectedViewFiles() throws -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: viewsDir, includingPropertiesForKeys: nil) else {
            XCTFail("Sources/Views could not be enumerated")
            return []
        }
        let root = viewsDir.standardizedFileURL.path
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { String($0.standardizedFileURL.path.dropFirst(root.count + 1)) }
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
        // A backstop only. It cannot tell whether the walk covers the tree,
        // because all but one of the labelled sites sit at the top level, so a
        // subfolder dropping out of view moves this by one (#583). What proves
        // the coverage is testTheScanReadsEveryViewFileIncludingTheSubfolders,
        // which compares the files read against a separate enumeration.
        XCTAssertGreaterThan(sites.count, 40,
                             "the scan found almost no plain buttons, so it has stopped working",
                             file: file, line: line)

        var offenders: [String] = []
        for site in sites where registry.contains("\(site.file)|\(site.label)") {
            if try isLabelColour(site.colour) {
                offenders.append("\(site.file): \(site.label) is \(site.colour)")
            }
        }

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
        for url in try viewFiles() {
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
