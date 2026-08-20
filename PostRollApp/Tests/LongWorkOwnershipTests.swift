import Foundation
import XCTest

/// A view does not own work that outlives it (#713).
///
/// The rule and the reasoning live on `JobTracker`, where the mechanism
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
    ///
    /// It is EMPTY as of #718, and that is a measurement, not a proof that this
    /// cannot happen: a count driven to zero stops being read as a number and
    /// starts being read as an impossibility, and then nobody re-examines it
    /// (L182). What keeps it honest is `testTheScannerCanStillSeeOne` below,
    /// which fails if the scanner has stopped matching. Without that control an
    /// empty list and a broken scanner look exactly alike.
    private static let known: [String: String] = [:]

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

            The rule and the shape to copy are on JobTracker. If one of \
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

    // MARK: - Nor the FAILURE of that work (#721)
    //
    // The in flight flag was only half of it. `CaptionReviewView` handed every
    // long run's progress to a manager in #718 and kept writing their failure
    // messages into one `@State` string of its own: five independent actions
    // sharing one status field, so whichever failed last erased the reason
    // before it (L53), and a run that failed after Dan had gone to another
    // event left nothing behind at all, because the run survived the remount
    // and its message did not (L148).

    /// The names of the view's own message state, which a long run must not
    /// write.
    ///
    /// Found by TYPE rather than by name: any `@State` optional string on a
    /// screen is a sentence waiting to be shown to Dan, whatever it is called.
    /// This used to match names containing "error" or "failure", and #728
    /// renamed this screen's notice field from `pickError` to `refusedAction`,
    /// a better name that sits outside that convention. A rule keyed on a
    /// naming convention only ever checks the names somebody remembered to
    /// follow, and the one it stops seeing is the one just renamed (L96).
    /// Measured when this was widened: it covers 18 fields across the views
    /// tree where the name rule covered 9, and flags none of them today.
    private static func ownedMessageNames(_ text: String) -> [String] {
        let pattern = #"@State\s+(?:private\s+)?var\s+(\w+)\s*:\s*String\?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: full).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The bodies of every `Task {` in `text`, brace balanced.
    private static func taskBodies(_ text: String) -> [String] {
        var bodies: [String] = []
        var search = text.startIndex
        while let start = text.range(of: "Task {", range: search..<text.endIndex) {
            var depth = 0
            var i = start.lowerBound
            var end: String.Index? = nil
            while i < text.endIndex {
                if text[i] == "{" { depth += 1 }
                if text[i] == "}" {
                    depth -= 1
                    if depth == 0 { end = text.index(after: i); break }
                }
                i = text.index(after: i)
            }
            bodies.append(String(text[start.lowerBound..<(end ?? text.endIndex)]))
            search = start.upperBound
        }
        return bodies
    }

    /// The view's own error fields that a call across to Python writes into.
    ///
    /// Scoped to the Task rather than the file, because the SHORT failures on
    /// these screens legitimately stay on the view: a file that could not be
    /// copied is over before the next redraw. What must not be view state is
    /// the outcome of a run that outlives the screen (L53, L148).
    static func failuresOfLongWork(_ text: String) -> [String] {
        let owned = Set(ownedMessageNames(text))
        guard !owned.isEmpty else { return [] }
        var offenders: Set<String> = []
        for body in taskBodies(text) where body.contains("PythonBridge.shared.") {
            for name in owned where body.range(
                of: "\\b" + name + #"\s*="#, options: .regularExpression) != nil {
                offenders.insert(name)
            }
        }
        return offenders.sorted()
    }

    func testNoScreenKeepsTheFailureOfWorkThatOutlivesIt() throws {
        var offenders: [String] = []
        for url in try Self.viewSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let found = Self.failuresOfLongWork(text)
            guard !found.isEmpty else { continue }
            offenders.append("\(url.lastPathComponent): \(found.joined(separator: ", "))")
        }

        XCTAssertTrue(offenders.isEmpty, """
            These screens write the failure of a call that goes across to Python \
            into their own state: \(offenders.joined(separator: "; ")).

            That state dies with the screen while the run does not, so a failure \
            arriving after an event switch leaves nothing behind, and several \
            actions sharing one field erase each other's reasons. Keep the \
            outcome on the manager that owns the run, the way \
            PreviewGraphicsManager.failDayRegen and CaptionWorkManager.Outcome do.
            """)
    }

    func testTheFailureScannerCanStillSeeOne() {
        // The control. This scanner reported one offender when it was written
        // and nothing after the fix, and those two look identical if it has
        // simply stopped matching (L98, L1).
        let offender = """
        struct SomeScreen: View {
            @State private var swapError: String?
            func go() {
                Task {
                    do { _ = try await PythonBridge.shared.runSwapReelAudio(event: e, day: d) }
                    catch { swapError = error.localizedDescription }
                }
            }
        }
        """
        XCTAssertEqual(LongWorkOwnershipTests.failuresOfLongWork(offender), ["swapError"])
    }

    func testAMessageFieldNotNamedForFailureIsStillOneOfThem() {
        // The third control, and the reason this reads the TYPE rather than the
        // name. #728 renamed this screen's own notice field from `pickError` to
        // `refusedAction`, which is a better name and put the field outside the
        // convention the scan was keyed on, so a long run's failure written
        // there became invisible to the rule written to catch exactly that
        // (L96). Nothing reported it: the list of offenders was empty before
        // and after, and an empty list is what the rule holding looks like.
        let offender = """
        struct SomeScreen: View {
            @State private var refusedAction: String?
            func go() {
                Task {
                    do { _ = try await PythonBridge.shared.runSwapReelAudio(event: e, day: d) }
                    catch { refusedAction = error.localizedDescription }
                }
            }
        }
        """
        XCTAssertEqual(LongWorkOwnershipTests.failuresOfLongWork(offender), ["refusedAction"])
    }

    func testAShortFailureOnTheViewIsNoneOfItsBusiness() {
        // The other control, and the reason the scan is scoped to the Task: a
        // file that could not be copied is a local failure, over before the
        // next redraw, and a rule that moved those onto a manager would be
        // unusable and would be turned off (L104).
        let innocent = """
        struct SomeScreen: View {
            @State private var pickError: String?
            func pick(_ url: URL) {
                if let message = ImportedPicks.copy([url]).failureMessage { pickError = message }
                Task { _ = try? await PythonBridge.shared.runPreviewGeneration(event: e) }
            }
        }
        """
        XCTAssertEqual(LongWorkOwnershipTests.failuresOfLongWork(innocent), [])
    }
}
