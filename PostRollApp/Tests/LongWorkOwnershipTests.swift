import XCTest

/// A view does not own work that outlives it (#713).
///
/// The rule and the reasoning live on `EventJobTracker`, where the mechanism
/// is. This is what makes it hold: without a check, the next long call anyone
/// writes goes back into view state, and the defect returns one screen at a
/// time. That has now happened twice (#693, #707), which is what a rule living
/// only in an issue buys (L27).
///
/// What it looks for is narrow on purpose: a view that keeps an in flight flag
/// AND shells out to the Python side in the same file. A screen doing both is
/// holding the progress of a call that takes minutes and that outlives any
/// section being collapsed. A short lived flag on a local action is none of its
/// business, so it does not look at those.
final class LongWorkOwnershipTests: XCTestCase {

    /// The screens that still do this, each with what is left to do about it.
    ///
    /// Written down rather than fixed silently, so what remains is visible and
    /// countable rather than being rediscovered. An entry here is a statement
    /// that somebody looked, not that it is fine (L129, L65).
    private static let known: [String: String] = [
        "OCRReviewView.swift":
            "the reflow call, the third of the three #707 listed. It sits on its "
            + "own surface rather than in a collapsing section, so it is the "
            + "least exposed, and its result lands somewhere different again.",
        "CaptionReviewView.swift":
            "regenerate, revise, analyse edits and the audio swap. Not yet "
            + "converted: each writes to a different part of the week's result "
            + "and needs its own decision about where that lands.",
        "InsightsOverviewView.swift":
            "the CSV import and the insight generation. Neither is keyed by "
            + "event, so they need an owner shaped differently from the "
            + "per-event managers.",
    ]

    private static func viewSources() throws -> [URL] {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
        let found = FileManager.default.enumerator(at: views,
                                                   includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A view holding the progress of something long, by its own state.
    private static func holdsLongWork(_ text: String) -> Bool {
        // The participle can be anywhere in the name, not only at the end:
        // the two flags that actually caused this were `isFetchingNotes` and
        // `isLookingUpHandles`, and a pattern anchored at the end missed both
        // while matching `isRevising` and reading as though it worked.
        let flag = text.range(
            of: #"@State\s+(private\s+)?var\s+is[A-Z]\w*ing\w*"#,
            options: .regularExpression) != nil
        // The work being long is the other half: a call across to Python is
        // minutes, not milliseconds.
        let long = text.contains("PythonBridge.shared.")
        return flag && long
    }

    func testNoNewScreenHoldsTheProgressOfWorkThatOutlivesIt() throws {
        var offenders: [String] = []
        for url in try Self.viewSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard Self.holdsLongWork(text) else { continue }
            guard Self.known[url.lastPathComponent] == nil else { continue }
            offenders.append(url.lastPathComponent)
        }

        XCTAssertTrue(offenders.isEmpty, """
            These screens keep an in flight flag for a call that goes across to \
            Python, so the progress, the error and often the result belong to a \
            view that is destroyed whenever a section collapses or the event \
            changes: \(offenders.joined(separator: ", ")).

            The rule and the shape to copy are on EventJobTracker. If one of \
            these genuinely cannot be converted yet, add it to `known` in this \
            file with what is left to do, so it is visible rather than silent.
            """)
    }

    func testTheListOfKnownScreensIsStillAboutRealScreens() throws {
        // An exemption for a file that no longer does this is an exemption
        // protecting nothing, and it would hide the day a converted screen
        // regressed (L96).
        let names = Set(try Self.viewSources().map(\.lastPathComponent))
        for (file, reason) in Self.known {
            XCTAssertTrue(names.contains(file),
                          "\(file) is listed as still holding long work and does "
                          + "not exist: \(reason)")
            let text = try String(
                contentsOf: try XCTUnwrap(Self.viewSources().first {
                    $0.lastPathComponent == file
                }), encoding: .utf8)
            XCTAssertTrue(Self.holdsLongWork(text),
                          "\(file) no longer holds the progress of long work, so "
                          + "its entry should go rather than sit here excusing "
                          + "something that has been fixed")
        }
    }

    func testTheScannerCanStillSeeOne() {
        // The control. A scanner that had stopped matching would report every
        // screen as clean, and its silence would read as the rule holding
        // (L98, L1).
        let offender = """
        struct SomeScreen: View {
            @State private var isFetchingThings = false
            func go() async {
                _ = try? await PythonBridge.shared.fetchPieceNotes(
                    pieces: [], org: "", event: "")
            }
        }
        """
        XCTAssertTrue(LongWorkOwnershipTests.holdsLongWork(offender))
    }

    func testAShortLivedFlagIsNoneOfItsBusiness() {
        // The other control: a view with a flag and no long call must not trip
        // it, or the rule would be unusable and would be turned off.
        let innocent = """
        struct SomeRow: View {
            @State private var isHovering = false
            var body: some View { Text("hi").onHover { isHovering = $0 } }
        }
        """
        XCTAssertFalse(LongWorkOwnershipTests.holdsLongWork(innocent))
    }
}
