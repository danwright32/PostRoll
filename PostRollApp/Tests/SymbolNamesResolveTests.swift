import XCTest
import AppKit

/// #1215: an SF Symbol name that does not resolve draws NOTHING.
///
/// `Image(systemName:)` renders empty, no error is raised, and nothing in the
/// suite would notice. The legibility checks measure ink over a surface, and a
/// banner still has its fill, its border and its words, so a missing icon
/// barely moves the reading (L141).
///
/// Found while adding `folder.badge.questionmark` to the export folder banner in
/// #1110. That one does resolve, checked by hand against
/// `NSImage(systemSymbolName:)` with a deliberate bad name as the control, but
/// "checked by hand once" is exactly the state this repo does not leave things
/// in.
///
/// ## Where the names come from
///
/// Read out of the source rather than listed here. A hand written list checks
/// only what somebody remembered to add, and the ones you remember are the ones
/// already safe (L96, L41).
///
/// ## What this cannot tell you
///
/// A symbol that resolves on THIS Mac may not exist on the oldest macOS the app
/// supports, so a green run here is not a claim about the deployment target.
/// That is recorded rather than papered over: `NSImage(systemSymbolName:)`
/// answers about the running system and there is no API that answers about
/// another one. What this does catch is the whole of the failure it was written
/// for, which is a misspelling, and it catches it on the machine that ships the
/// build.
final class SymbolNamesResolveTests: XCTestCase {

    /// Every string handed to something that renders a symbol.
    ///
    /// The three spellings the app actually uses. Matched on the argument
    /// label and on a LITERAL, so a name assembled at run time is invisible
    /// here. Said plainly rather than implied: this covers the literals, which
    /// is every symbol the app writes today, and a name built from a variable
    /// would pass this check while drawing nothing. The control below is what
    /// stops a spelling silently going unread (L98).
    private static let spellings = [
        #"systemName: "([^"]+)""#,
        #"systemImage: "([^"]+)""#,
        #"icon: "([^"]+)""#,
    ]

    private func namesInTheApp() throws -> [String: [String]] {
        let sources = RepoFixture.repoRoot()
            .appendingPathComponent("PostRollApp/Sources")
        let files = RepoFixture.files(under: sources, withExtension: "swift")
        XCTAssertGreaterThan(files.count, 100,
                             "the sweep found almost no source files, so it is "
                             + "reading the wrong tree")

        var found: [String: [String]] = [:]
        for (relative, url) in files {
            let code = SwiftSourceText.withoutComments(
                try String(contentsOf: url, encoding: .utf8))
            for spelling in Self.spellings {
                let pattern = try NSRegularExpression(pattern: spelling)
                let range = NSRange(code.startIndex..., in: code)
                for match in pattern.matches(in: code, range: range) {
                    guard let at = Range(match.range(at: 1), in: code) else { continue }
                    found[String(code[at]), default: []].append(relative)
                }
            }
        }
        return found
    }

    func testEverySymbolTheAppNamesResolves() throws {
        let named = try namesInTheApp()
        XCTAssertGreaterThan(named.count, 40,
                             "only \(named.count) symbol names were found, "
                             + "which is not this app: the collector has "
                             + "stopped matching")

        var missing: [String] = []
        for (name, files) in named where NSImage(systemSymbolName: name,
                                                accessibilityDescription: nil) == nil {
            missing.append("\(name) (in \(files.sorted().joined(separator: ", ")))")
        }

        XCTAssertTrue(missing.isEmpty,
                      "these symbol names do not resolve, so they draw NOTHING "
                      + "and no error is raised: \(missing.sorted())")
    }

    func testADeliberatelyBadNameDoesNotResolve() {
        // The positive control (L159). Without it, "every name resolves" is
        // satisfied by a check that resolves anything at all, and by a
        // collector that found nothing.
        XCTAssertNil(NSImage(systemSymbolName: "not.a.real.symbol.name.at.all",
                             accessibilityDescription: nil))
    }

    func testTheCollectorFindsANameInEverySpellingTheAppUses() throws {
        // Each spelling is its own way of losing coverage: a name passed as
        // `icon:` to BrandBanner is as invisible as a misspelling if the
        // collector only knows `systemName:` (L96).
        let named = try namesInTheApp()

        // One name per spelling, each taken from what the app really writes
        // today rather than guessed: a control that names a symbol the app does
        // not use fails for a reason that has nothing to do with the collector
        // (L48).
        for (known, spelling) in [("archivebox", "systemName:"),
                                  ("arrow.up.arrow.down", "systemImage:"),
                                  ("bell.slash.fill", "icon:")] {
            XCTAssertNotNil(named[known],
                            "\(known) is written as \(spelling) somewhere in "
                            + "this app and the collector did not find it, so "
                            + "that spelling is not being read and every symbol "
                            + "passed that way is unchecked")
        }
    }
}
