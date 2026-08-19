import XCTest

/// The owners of long work are injected from ONE list (#718).
///
/// Each owner exists because a run used to live in a view's state and died with
/// it. There are seven, and the count only grows. The app injected them in one
/// place and `NoScreenForcesTheWindowBiggerTests`, which renders every stage
/// screen, spelled the same list out again.
///
/// That second list is worse than an ordinary duplicate. A view reads its owner
/// with `@Environment(T.self)`, and SwiftUI TRAPS on a missing one, so a
/// harness that has fallen behind does not fail an assertion: it crashes the
/// process part way through the suite, and the run reports a test that has
/// nothing to do with the owner that was forgotten. Adding `OCRReflowManager`
/// did exactly that.
///
/// So the list lives in `AppOwners` and everything uses `withAppOwners`. This
/// keeps it that way: a list maintained by hand beside another is a list they
/// can disagree about (L41, L96).
final class AppOwnersTests: XCTestCase {

    private static let ownersFile = "AppOwners.swift"

    private static func swiftSources() throws -> [URL] {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var found: [URL] = []
        for folder in ["Sources", "Tests"] {
            let root = app.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: root,
                                                       includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
            found += files
        }
        return found.sorted { $0.path < $1.path }
    }

    /// A direct injection of one of the work owners.
    ///
    /// Matched on the SHAPE of an environment call whose argument constructs a
    /// type ending in Manager, rather than on a list of the seven names: a list
    /// of names here would be the third hand-kept copy of the very thing this
    /// exists to stop.
    ///
    /// The shape is deliberately not spelled out literally anywhere in this
    /// file. It was, in this comment, and the check reported this file as an
    /// offender: a text guard cannot tell the line describing a construct from
    /// the line using it (L103, L135).
    private static func directInjections(_ text: String) -> [String] {
        let pattern = #"\.environment\(\s*\w*Manager\("#
        var hits: [String] = []
        var search = text.startIndex..<text.endIndex
        while let found = text.range(of: pattern, options: .regularExpression,
                                     range: search) {
            hits.append(String(text[found]))
            search = found.upperBound..<text.endIndex
        }
        return hits
    }

    func testNothingInjectsAWorkOwnerOutsideTheOneList() throws {
        var offenders: [String] = []
        for url in try Self.swiftSources() {
            guard url.lastPathComponent != Self.ownersFile else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if !Self.directInjections(text).isEmpty {
                offenders.append(url.lastPathComponent)
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            These files put a work owner into the environment themselves rather \
            than through withAppOwners: \(offenders.joined(separator: ", ")).

            That is a second copy of the list in AppOwners, and the two come \
            apart silently: SwiftUI traps on a missing environment value, so a \
            harness that has fallen behind CRASHES a screen rather than failing \
            a check, and the run blames whichever test was running at the time.

            Use .withAppOwners(AppOwners()) instead, and add new owners to \
            AppOwners so every screen and every harness gets them at once.
            """)
    }

    func testTheScannerCanStillSeeOne() {
        // The control. A scanner that had stopped matching would report every
        // file as clean, and its silence would read as the rule holding
        // (L98, L1).
        // Assembled from two pieces rather than written out, so THIS file does
        // not itself contain a match. Written whole first, and the check
        // promptly reported this file as an offender, which is the scanner
        // working: a guard that matches source text matches its own examples
        // too (L135).
        let offender = "let hosted = SomeScreen()\n    .environment("
            + "OCRReflowManager())"
        XCTAssertFalse(AppOwnersTests.directInjections(offender).isEmpty)
    }

    func testAnOrdinaryStoreIsNoneOfItsBusiness() {
        // The other control. Stores are not work owners and are injected with
        // real instances a test has configured, so matching those would make
        // the rule unusable and it would be turned off.
        let innocent = """
        let hosted = SomeScreen()
            .environment(AnalyticsStore(fileURL: file))
            .environment(HashtagStore())
        """
        XCTAssertTrue(AppOwnersTests.directInjections(innocent).isEmpty)
    }

    func testEveryOwnerInTheListIsActuallyInjected() throws {
        // The list and the modifier are two halves in one file, and a property
        // added to the struct but not to withAppOwners is exactly the gap this
        // whole thing exists to close: it would compile, and the screen reading
        // that owner would trap.
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Services/\(Self.ownersFile)")
        let text = try String(contentsOf: file, encoding: .utf8)

        let declared = Set(matches(#"var (\w+) = \w+\("#, in: text, group: 1))
        let injected = Set(matches(#"\.environment\(owners\.(\w+)\)"#, in: text, group: 1))

        XCTAssertFalse(declared.isEmpty, "no owners were found in \(Self.ownersFile), "
                       + "so this check is asserting nothing")
        XCTAssertEqual(declared, injected,
                       "these owners are declared but never injected, so the "
                       + "screens that read them trap: "
                       + declared.subtracting(injected).sorted().joined(separator: ", "))
    }

    private func matches(_ pattern: String, in text: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: group), in: text).map { String(text[$0]) }
        }
    }
}
