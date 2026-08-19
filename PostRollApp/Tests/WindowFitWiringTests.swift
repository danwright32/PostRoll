import XCTest

/// The window guard is actually attached to the window (#690).
///
/// `WindowFitTests` proves the arithmetic and the taking back of the minimum.
/// All of that can be right while nothing in the app ever calls it, which is
/// the state the app was already in: it set a minimum size that was overwritten
/// and read as protection while protecting nothing (L3, L188).
///
/// Read from `WindowConfigurator`'s own source with comments stripped, so prose
/// about a guard cannot satisfy a check for the guard (L103).
final class WindowFitWiringTests: XCTestCase {

    private func windowConfigurator() throws -> String {
        let code = try MainWindowSource.stripped()
        guard let block = MainWindowSource.block(
            openedBy: "private struct WindowConfigurator", in: code)
        else {
            throw XCTSkip("WindowConfigurator is gone, so this guard has "
                          + "nothing to check")
        }
        return block
    }

    func testTheWindowIsHeldInsideTheScreenWhenItOpens() throws {
        // A window restored from a previous session already oversized has to
        // heal itself on open, rather than reopening in the state Dan could not
        // drag his way out of.
        let code = try windowConfigurator()
        XCTAssertTrue(code.contains("WindowFit.fit("),
                      "nothing brings the window inside the usable area at "
                      + "launch: \(code)")
    }

    func testTheWindowKeepsBeingHeldAfterItOpens() throws {
        // The half the old code was missing entirely. The opening frame ran
        // once at window creation, and the layout pass that breaks the window
        // comes later, so a launch time check cannot help.
        let code = try windowConfigurator()
        XCTAssertTrue(code.contains("WindowFit.watch("),
                      "the window is checked once and then never again, so any "
                      + "later layout pass is free to push it off screen: \(code)")
    }

    func testTheWatchIsHeldRatherThanRegisteredAndForgotten() throws {
        // A notification centre holds its observers unowned and outlives what
        // registers with them (L86). A watch created and dropped stops working,
        // and a watch created on every rebuild accumulates observers.
        let code = try windowConfigurator()
        XCTAssertTrue(code.contains("coordinator.watch"),
                      "the watch is not held by the coordinator, so it is "
                      + "either released immediately or created again on every "
                      + "rebuild: \(code)")
    }

    func testTheFloorHasOneSpelling() throws {
        // Two copies of the same minimum can disagree, and the one that lost
        // would be the window's, silently. The guard puts back whatever
        // `WindowFit.floor` says, so that is the value the window must be set
        // to in the first place.
        let code = try windowConfigurator()
        XCTAssertTrue(code.contains("window.minSize = WindowFit.floor"),
                      "the window's minimum is written out here as its own "
                      + "number, so the guard and the window can disagree "
                      + "about what the floor is: \(code)")
    }
}
