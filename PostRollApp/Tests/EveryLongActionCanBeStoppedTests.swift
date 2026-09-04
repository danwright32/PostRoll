import XCTest

/// #1050: every long action offers a way back.
///
/// #1047 was the export screen: once generation started there was no way to
/// stop it, and a run started by mistake left two ways out, waiting nearly
/// three minutes for work that was going to be thrown away, or quitting the
/// app. The issue said the same shape almost certainly existed on every other
/// long action here, and it did. Four of the nine owners started their work
/// with a bare `Task { }` and threw the handle away, so nothing could ever have
/// stopped them. Three more had each written their own cancel, and each got a
/// different part of it wrong.
///
/// ## Where the rule lives
///
/// `JobTracker`, which is the mechanism every such run is built on and where
/// the sibling rule about not owning long work in a view already lives. It
/// takes the handle on the work as part of its contract now, so an owner that
/// leaves it out does not compile.
///
/// ## What this adds on top of that
///
/// The compiler covers the handle. It cannot cover the OWNER exposing a way to
/// ask for a stop, so a manager could hold the task, satisfy the tracker, and
/// still give its screen no button. That is what this checks, and it enumerates
/// the owners from the source rather than from a list, because a hand written
/// registry checks only what somebody remembered to add and the entries anybody
/// remembers are the ones already safe (L96, L41).
final class EveryLongActionCanBeStoppedTests: XCTestCase {

    /// An owner of long work: anything composing a `JobTracker`.
    private func owners() throws -> [(name: String, code: String)] {
        let services = RepoFixture.repoRoot()
            .appendingPathComponent("PostRollApp/Sources/Services")
        var found: [(String, String)] = []
        for (relative, url) in RepoFixture.files(under: services,
                                                 withExtension: "swift") {
            let code = SwiftSourceText.withoutComments(
                try String(contentsOf: url, encoding: .utf8))
            guard code.contains("JobTracker<") else { continue }
            // JobTracker's own file declares the type rather than composing it.
            guard !relative.hasSuffix("JobTracker.swift") else { continue }
            found.append((relative, code))
        }
        return found.sorted { $0.0 < $1.0 }
    }

    func testTheSweepFindsTheOwners() throws {
        // The positive control. A sweep that found none would report every
        // owner as offering a stop, which is what the four that offered
        // nothing looked like before this (L98, L100).
        let names = try owners().map(\.name)

        XCTAssertGreaterThan(names.count, 7,
                             "only \(names.count) owners of long work were "
                             + "found, which is not this app: \(names)")
        for expected in ["ExportManager.swift", "GenerationManager.swift",
                         "InsightsWorkManager.swift", "CollageLayoutLoader.swift"] {
            XCTAssertTrue(names.contains { $0.hasSuffix(expected) },
                          "\(expected) is not among the owners the sweep "
                          + "found, so it is exempt by accident")
        }
    }

    func testEveryOwnerOffersAWayToStop() throws {
        // Named `cancel` or `stop`: both spellings are in use and which one
        // reads better depends on the screen. What matters is that one exists,
        // not which word it uses (L273).
        let missing = try owners()
            .filter { !$0.code.contains("func cancel") && !$0.code.contains("func stop") }
            .map(\.name)

        XCTAssertTrue(missing.isEmpty,
                      "these own work that takes long enough to put up a "
                      + "spinner and offer no way to stop it, so a run started "
                      + "by mistake can only be waited out or escaped by "
                      + "quitting the app (#1050, #1047): \(missing)")
    }

    func testEveryOwnerCanSayItIsWindingDown() throws {
        // The middle of the three states. Cancelling a task ASKS: a subprocess
        // gets SIGTERM and a grace period before SIGKILL. A screen that jumped
        // from the spinner straight to idle would claim the work had ended
        // before it had, which is the defect #1047 fixed on one screen.
        let missing = try owners()
            .filter { !$0.code.contains("isStopping") && !$0.code.contains("isCancelling") }
            .map(\.name)

        XCTAssertTrue(missing.isEmpty,
                      "these can be stopped but cannot say they are stopping, "
                      + "so the screen has no way to tell running from winding "
                      + "down and shows one of them for both: \(missing)")
    }

    func testStoppingGoesThroughTheOneImplementation() throws {
        // Three owners had written their own, and each got a different part of
        // it wrong: GenerationManager and OCRManager removed the run the
        // instant the button was pressed, so the screen went back to idle while
        // the subprocess was still dying. Sharing the data while copying the
        // code that applies it is not consolidation (L370).
        let bespoke = try owners()
            .filter { $0.code.contains("?.task?.cancel()") }
            .map(\.name)

        XCTAssertTrue(bespoke.isEmpty,
                      "these cancel the task themselves rather than going "
                      + "through JobTracker.requestStop, so the request is not "
                      + "recorded, a second press is not refused, and the run "
                      + "is not held in flight while it winds down: \(bespoke)")
    }

    func testNoOwnerThrowsAwayTheHandleOnItsWork() throws {
        // What the tracker's contract already enforces, asserted anyway
        // because it is the thing that made four of these unstoppable and a
        // compiler error is not a record of why (L27). A `Task { }` whose
        // result nothing binds cannot be cancelled by anybody.
        let discarded = try owners()
            .filter { $0.code.contains("\n        Task {") }
            .map(\.name)

        XCTAssertTrue(discarded.isEmpty,
                      "these start work with a bare Task and keep no handle on "
                      + "it, so nothing can ever stop it however many buttons "
                      + "the screen grows: \(discarded)")
    }

    // MARK: - Enumerated by the spinner, not by the spelling

    /// Every place the shared long run indicator is put on screen.
    ///
    /// This is the enumeration #1050 actually asks for: "each one that puts up
    /// a progress or spinner surface". Listing the owners that compose a
    /// `JobTracker` is one SPELLING of long work, and `PreviewGraphicsManager`
    /// reaches the same state by another route: it holds its own run state, so
    /// it got none of the stopping the tracker gained and was invisible to a
    /// sweep looking for a tracker (L247).
    private func indicatorSites() throws -> [(file: String, call: String)] {
        let views = RepoFixture.repoRoot()
            .appendingPathComponent("PostRollApp/Sources/Views")
        var found: [(String, String)] = []
        for (relative, url) in RepoFixture.files(under: views,
                                                 withExtension: "swift") {
            let code = SwiftSourceText.withoutComments(
                try String(contentsOf: url, encoding: .utf8))
            // The file that DECLARES it is not a site that shows it.
            guard !relative.hasSuffix("LongRunIndicator.swift") else { continue }
            var rest = Substring(code)
            while let at = rest.range(of: "LongRunIndicator(") {
                // To the closing paren of this call, counting depth so a nested
                // call in an argument does not end it early.
                var depth = 0
                var end = at.upperBound
                while end < rest.endIndex {
                    if rest[end] == "(" { depth += 1 }
                    if rest[end] == ")" {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    end = rest.index(after: end)
                }
                found.append((relative, String(rest[at.lowerBound...end])))
                rest = rest[rest.index(after: at.lowerBound)...]
            }
        }
        return found
    }

    func testTheIndicatorSweepFindsTheSurfaces() throws {
        // The positive control. A sweep finding none would report every spinner
        // as offering a stop (L98, L100).
        let sites = try indicatorSites()

        XCTAssertGreaterThan(sites.count, 10,
                             "only \(sites.count) long run indicators were "
                             + "found, which is not this app")
        XCTAssertTrue(sites.contains { $0.file.hasSuffix("InsightsOverviewView.swift") },
                      "the Insights spinners are not among the sites found")
    }

    func testEverySpinnerOffersAStop() throws {
        // #1050's own criterion, checked where it is visible: on screen. A
        // manager can hold its task, satisfy every rule above, and still leave
        // its screen with no way back.
        let missing = try indicatorSites()
            .filter { !$0.call.contains("onStop:") }
            .filter { Self.noStop[($0.file as NSString).lastPathComponent] == nil }
            .map(\.file)

        XCTAssertTrue(missing.isEmpty,
                      "these put a spinner on screen with no way to stop the "
                      + "work behind it, so a run started by mistake can only "
                      + "be waited out or escaped by quitting the app "
                      + "(#1050): \(Set(missing).sorted())")
    }

    func testEverySpinnerThatCanBeStoppedCanSayItIsStopping() throws {
        // A stop that made the button vanish would claim the work had ended
        // before it had: the subprocess gets SIGTERM and a grace period.
        let missing = try indicatorSites()
            .filter { $0.call.contains("onStop:") && !$0.call.contains("isStopping:") }
            .map(\.file)

        XCTAssertTrue(missing.isEmpty,
                      "these offer a stop and cannot say the work is winding "
                      + "down, so the press looks like it did nothing until "
                      + "the spinner disappears: \(Set(missing).sorted())")
    }


    /// A spinner that offers no stop, and why. Keyed by file, with the reason
    /// (L233): an entry with no reason is evidence nobody reasoned about it.
    ///
    /// One entry, and it is the app updating itself. The updater is a DETACHED
    /// bash script: it outlives PostRoll on purpose, because it quits the app
    /// to install the new build over it. Nothing this process can cancel would
    /// reach it, and stopping it half way through the install is how you get a
    /// broken app rather than an old one. A Stop button there would be a
    /// control that cannot do what it says (L109).
    private static let noStop: [String: String] = [
        "BuildBehindSheet.swift":
            "the updater is a detached script that outlives this process by "
            + "design, so nothing here could cancel it, and stopping it part "
            + "way through the install leaves a broken app rather than the old "
            + "one",
    ]

    func testEveryExemptionStillNamesASpinner() throws {
        // A stale entry excuses a real failure silently, and it is invisible
        // because the entry still reads as a considered decision (L217, L233).
        let shown = Set(try indicatorSites().map { ($0.file as NSString).lastPathComponent })
        let stale = Self.noStop.keys.filter { !shown.contains($0) }.sorted()

        XCTAssertTrue(stale.isEmpty,
                      "these exemptions name no screen that still shows a long "
                      + "run indicator: \(stale). Either the spinner went and "
                      + "the entry should go with it, or the file was renamed "
                      + "and the entry now excuses nothing")
    }

}
