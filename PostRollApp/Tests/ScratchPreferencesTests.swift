import XCTest

/// #744: the test bundle's scratch preferences suite was never cleared.
///
/// `AppPreferences.store` hands the test bundle a scratch `UserDefaults` suite
/// instead of Dan's real preferences (#734, #738). Nothing cleared it, so
/// whatever a test wrote stayed in that suite's plist and was there for the
/// next run of the suite, and every run after that. Every other scratch suite
/// in these tests deletes itself in teardown; this one was the odd one out.
///
/// Nothing was wrong on the day, because a test that cares which value it reads
/// passes its own suite. What this stops is a value left behind by one run
/// silently becoming an input to the next, which is diagnosed as a flaky test
/// rather than as leftover state.
///
/// Cleared once per RUN rather than per test, so tests that deliberately share
/// the suite within a run still can. That is why this drives `openScratchSuite`
/// against a suite of its own: `store` is opened once per process, so nothing
/// inside a run can watch the real one being opened.
final class ScratchPreferencesTests: XCTestCase {

    private var probe: String!

    override func setUpWithError() throws {
        // A name per test, so two of these can never be reading each other's
        // domain, and so a run that dies mid-test cannot leave a value that
        // decides the next one.
        probe = "com.dwphotony.PostRoll.tests.probe-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: probe)
    }

    func testOpeningAScratchSuiteLeavesNothingFromTheRunBefore() {
        // What the run before left behind, and the control that says it really
        // is there: a test asserting something is ABSENT is satisfied by a
        // fixture where it was never present (L159).
        let leftover = UserDefaults(suiteName: probe)
        leftover?.set("last run's answer", forKey: "postingPreset")
        XCTAssertEqual(leftover?.string(forKey: "postingPreset"), "last run's answer")

        let opened = AppPreferences.openScratchSuite(named: probe)

        XCTAssertNil(opened.string(forKey: "postingPreset"),
                     "the scratch suite opened holding a value from the run before")
    }

    func testTheSuiteIsUsableOnceItHasBeenCleared() {
        // The other half: clearing a suite that then refuses writes would be a
        // store nothing can use, and every test reading it would report the
        // default while looking isolated.
        let opened = AppPreferences.openScratchSuite(named: probe)
        opened.set("this run's answer", forKey: "postingPreset")
        XCTAssertEqual(opened.string(forKey: "postingPreset"), "this run's answer")
    }

    func testClearingOneScratchSuiteLeavesAnotherAlone() {
        let neighbour = "com.dwphotony.PostRoll.tests.probe-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: neighbour) }
        let kept = AppPreferences.openScratchSuite(named: neighbour)
        kept.set("not this one's business", forKey: "postingPreset")

        _ = AppPreferences.openScratchSuite(named: probe)

        // Clearing is scoped to the domain being opened. A clear that reached
        // wider would take out whichever suite a test had just set up for
        // itself, and the failure would read as the store not saving.
        XCTAssertEqual(kept.string(forKey: "postingPreset"), "not this one's business")
    }
}
