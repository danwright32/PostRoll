import XCTest

/// #257: the paid-path choice has to survive the transport setting.
final class PaidPathOverrideTests: XCTestCase {

    func testAnOrdinaryRunExportsNothing() {
        // An empty line, not `=1`. A run nobody asked to pay for must keep
        // whatever the setting says rather than being pinned either way.
        XCTAssertEqual(Transport.overrideExport(forcePaidPath: false), "")
    }

    func testChoosingToPayPinsThatRunToTheMeteredApi() {
        XCTAssertEqual(Transport.overrideExport(forcePaidPath: true),
                       "export POSTROLL_USE_SUBSCRIPTION=0")
    }

    func testTheOverrideTurnsTheSubscriptionOffRatherThanOn() {
        // Inverting this is the worst possible bug here: the button that says
        // it will pay would force the run onto the allowance that just ran out.
        let line = Transport.overrideExport(forcePaidPath: true)
        XCTAssertTrue(line.hasSuffix("=0"), "the paid override reads \(line)")
        XCTAssertFalse(line.hasSuffix("=1"))
    }

    func testItExportsTheNamePythonActuallyReads() {
        XCTAssertTrue(
            Transport.overrideExport(forcePaidPath: true)
                .contains(Transport.subscriptionEnv))
    }
}
