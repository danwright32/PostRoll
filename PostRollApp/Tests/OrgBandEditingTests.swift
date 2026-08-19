import XCTest

/// Correcting and clearing a stored follower band, on the real store (#712).
///
/// Two separate things: that a cleared band is actually gone from the file, and
/// that a change the store REFUSED to write is reported rather than shown as
/// done. The picker moves the instant it is clicked, so without the second one
/// a refused write and a saved one look identical on screen (L12).
final class OrgBandEditingTests: XCTestCase {

    private var dir: URL!
    private var file: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orgbands_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("analytics.json")
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: dir.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: file.path)
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - Clearing

    @MainActor
    func testAClearedBandIsGoneFromTheFile() {
        let store = AnalyticsStore(fileURL: file)
        store.setOrgBand("merkin_hall", .k10to50)
        store.setOrgBand("kyhs_music", .k1to10)

        XCTAssertEqual(store.clearOrgBand("merkin_hall"), .saved)

        let reloaded = AnalyticsStore(fileURL: file)
        XCTAssertEqual(reloaded.orgFollowerBands, ["kyhs_music": .k1to10],
                       "the cleared entry came back, or the other one went too")
    }

    /// Removed, not set to unknown. Storing unknown leaves a row that says
    /// nothing and can never be got rid of, which is the state this issue is
    /// about in the first place.
    @MainActor
    func testClearingRemovesTheKeyRatherThanStoringUnknown() {
        let store = AnalyticsStore(fileURL: file)
        store.setOrgBand("merkin_hall", .k10to50)
        store.clearOrgBand("merkin_hall")

        XCTAssertNil(store.orgFollowerBands["merkin_hall"])
        XCTAssertTrue(store.orgBandAudit.stranded.isEmpty,
                      "the row is still there after being cleared")
    }

    @MainActor
    func testClearingAnAccountThatHasNoBandChangesNothing() {
        let store = AnalyticsStore(fileURL: file)
        store.setOrgBand("kyhs_music", .k1to10)

        XCTAssertEqual(store.clearOrgBand("never_stored"), .saved)
        XCTAssertEqual(store.orgFollowerBands, ["kyhs_music": .k1to10])
    }

    // MARK: - A write the store refused

    /// A store whose file could not be read refuses every save, to avoid
    /// writing an empty in-memory copy over live data. Both edits have to
    /// report that, not swallow it.
    @MainActor
    private func blockedStore() throws -> AnalyticsStore {
        try XCTSkipIf(getuid() == 0, "permission based tests are meaningless as root")
        let seed = AnalyticsStore(fileURL: file)
        seed.setOrgBand("merkin_hall", .k10to50)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: file.path)
        let store = AnalyticsStore(fileURL: file)
        XCTAssertNotNil(store.recoveryMessage, "the store was not actually blocked")
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: file.path)
        return store
    }

    @MainActor
    func testSettingABandReportsAWriteThatWasRefused() throws {
        let store = try blockedStore()
        XCTAssertEqual(store.setOrgBand("kyhs_music", .k1to10), .blocked)
    }

    @MainActor
    func testClearingABandReportsAWriteThatWasRefused() throws {
        let store = try blockedStore()
        XCTAssertEqual(store.clearOrgBand("merkin_hall"), .blocked)
    }

    /// The control for the two above: the same two calls on a healthy store
    /// report saved, or `.blocked` would be the answer to everything and prove
    /// nothing about the refusal (L159).
    @MainActor
    func testAHealthyStoreReportsBothEditsAsSaved() {
        let store = AnalyticsStore(fileURL: file)
        XCTAssertEqual(store.setOrgBand("kyhs_music", .k1to10), .saved)
        XCTAssertEqual(store.clearOrgBand("kyhs_music"), .saved)
    }

    // MARK: - What Dan is told

    /// `XCTUnwrap` rather than a forced unwrap in every one of these: a nil
    /// crashes the whole test process, and a crashed run reports zero tests
    /// executed, which the mutation sweep cannot tell from a spec that matched
    /// nothing (L98). Seen doing exactly that on the first run of the guard
    /// entry for this file.
    func testARefusedChangeSaysItWillNotSurviveQuitting() throws {
        let notice = try XCTUnwrap(InsightsDisplay.unsavedBandNotice(
            save: .blocked, org: "kyhs_music", edit: .set))

        XCTAssertTrue(notice.contains("kyhs_music"),
                      "the notice has to name the account it is about")
        XCTAssertTrue(notice.contains("quit"),
                      "the notice has to say the change is only in this window")
    }

    /// A refused CLEAR and a refused SET leave opposite states behind: the
    /// cleared entry comes back at next launch, the set band does not. One
    /// message for both would be wrong for one of them (L11).
    func testARefusedClearSaysTheEntryWillComeBack() throws {
        let cleared = try XCTUnwrap(InsightsDisplay.unsavedBandNotice(
            save: .blocked, org: "merkin_hall", edit: .cleared))
        let set = InsightsDisplay.unsavedBandNotice(
            save: .blocked, org: "merkin_hall", edit: .set)

        XCTAssertNotEqual(cleared, set,
                          "a refused clear and a refused change say the same thing")
        XCTAssertTrue(cleared.contains("back"),
                      "a refused clear has to say the entry returns: \(cleared)")
    }

    func testAFailedWriteCarriesTheReason() throws {
        let notice = try XCTUnwrap(InsightsDisplay.unsavedBandNotice(
            save: .failed("the disk is full"), org: "kyhs_music", edit: .set))

        XCTAssertTrue(notice.contains("the disk is full"), notice)
    }

    func testASavedChangeSaysNothing() {
        XCTAssertNil(InsightsDisplay.unsavedBandNotice(
            save: .saved, org: "kyhs_music", edit: .set))
        XCTAssertNil(InsightsDisplay.unsavedBandNotice(
            save: .saved, org: "kyhs_music", edit: .cleared))
    }
}
