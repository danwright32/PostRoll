import XCTest

/// #293: what the outdated designs list shows.
final class OutdatedDesignsDisplayTests: XCTestCase {

    private func event(_ name: String, org: String, date: String) -> Event {
        let day = ISO8601DateFormatter().date(from: "\(date)T12:00:00Z") ?? Date()
        return Event(name: name, org: org, venue: "Hall", date: day,
                     shootType: .fullShow)
    }

    private func day(slug: String, label: String = "Thursday",
                     templates: [String] = ["reel_scroll"]) -> StaleDay {
        StaleDay(eventSlug: slug,
                 dayFolder: URL(fileURLWithPath: "/tmp/\(slug)/\(label)"),
                 dayLabel: label, templates: templates)
    }

    // MARK: - Matching a preview folder back to its event

    func testAFolderIsMatchedToTheEventThatMadeIt() {
        let e = event("Vocal Color", org: "DCINY", date: "2026-03-30")
        let slug = ArchiveCleanup.slug(event: e)

        let groups = OutdatedDesignsDisplay.groups([day(slug: slug)], events: [e])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].eventID, e.id)
        XCTAssertEqual(groups[0].title, "Vocal Color")
    }

    func testAFolderWithNoEventOnRecordIsStillListedUnderItsFolderName() {
        // Its files are on disk. Dropping the row would make this surface claim
        // a clean machine while old assets sat there.
        let groups = OutdatedDesignsDisplay.groups(
            [day(slug: "deleted_event_2026-01-01")], events: [])

        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].eventID, "there is nothing to open, and nothing to regenerate from")
        XCTAssertEqual(groups[0].title, "deleted_event_2026-01-01")
    }

    func testEveryDayOfOneEventIsGroupedUnderIt() {
        let e = event("Vocal Color", org: "DCINY", date: "2026-03-30")
        let slug = ArchiveCleanup.slug(event: e)

        let groups = OutdatedDesignsDisplay.groups([
            day(slug: slug, label: "Tuesday", templates: ["reel_morph"]),
            day(slug: slug, label: "Thursday"),
        ], events: [e])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].days.map(\.dayLabel), ["Tuesday", "Thursday"])
    }

    func testTheGroupsKeepTheOrderTheScanFoundThemIn() {
        let a = event("A", org: "Org", date: "2026-01-01")
        let b = event("B", org: "Org", date: "2026-02-02")

        let groups = OutdatedDesignsDisplay.groups([
            day(slug: ArchiveCleanup.slug(event: b)),
            day(slug: ArchiveCleanup.slug(event: a)),
        ], events: [a, b])

        XCTAssertEqual(groups.map(\.title), ["B", "A"])
    }

    // MARK: - Nothing found is not one answer but two

    func testAMachineWithNothingRenderedSaysSoRatherThanReportingItIsCurrent() {
        // The reassuring sentence over a folder nothing has looked at is a
        // clean bill of health nobody measured (LESSONS.md L98).
        let text = OutdatedDesignsDisplay.summary(dayCount: 0, hasPreviewRoot: false)

        XCTAssertTrue(text.contains("no rendered assets"), text)
        XCTAssertFalse(text.contains("matches the current design"), text)
    }

    func testAMachineWhoseDaysAreAllCurrentSaysThat() {
        let text = OutdatedDesignsDisplay.summary(dayCount: 0, hasPreviewRoot: true)

        XCTAssertTrue(text.contains("matches the current design"), text)
    }

    func testTheCountIsWrittenOutForOneDayAndForSeveral() {
        XCTAssertTrue(OutdatedDesignsDisplay.summary(dayCount: 1, hasPreviewRoot: true)
            .hasPrefix("One day"))
        XCTAssertTrue(OutdatedDesignsDisplay.summary(dayCount: 7, hasPreviewRoot: true)
            .hasPrefix("7 days"))
    }

    // MARK: - How a row reads

    func testARowNamesTheDayAndWhatIsBehindOnIt() {
        let row = OutdatedDesignsDisplay.rowLabel(
            day(slug: "s", label: "Wednesday", templates: ["collage", "story"]))

        XCTAssertEqual(row, "Wednesday: collage and story graphic")
    }
}
