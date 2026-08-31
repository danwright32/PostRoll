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

    // MARK: - Nothing found is not one answer but four

    private func survey(stale: Int = 0, days: Int, recorded: Int) -> DesignScanResult {
        DesignScanResult(
            stale: (0..<stale).map {
                StaleDay(eventSlug: "e\($0)",
                         dayFolder: URL(fileURLWithPath: "/tmp/e\($0)"),
                         dayLabel: "Thursday", templates: ["reel_scroll"])
            },
            daysWithAssets: days,
            daysWithARecord: recorded)
    }

    func testAMachineWithNothingRenderedSaysSoRatherThanReportingItIsCurrent() {
        // The reassuring sentence over a folder nothing has looked at is a
        // clean bill of health nobody measured (LESSONS.md L98).
        let text = OutdatedDesignsDisplay.summary(survey(days: 0, recorded: 0),
                                                  hasPreviewRoot: false)

        XCTAssertTrue(text.contains("no rendered assets"), text)
        XCTAssertFalse(text.contains("matches the current design"), text)
    }

    /// #311: the state Dan's Mac is actually in, and will stay in until a day is
    /// rendered again. 66 day folders, none carrying a record, so nothing could
    /// be compared. Saying "every rendered day matches the current design" there
    /// is the reassuring sentence over a library nothing has been able to check.
    func testDaysThatRecordNoDesignAreReportedAsUncheckedNotAsCurrent() {
        let text = OutdatedDesignsDisplay.summary(survey(days: 66, recorded: 0),
                                                  hasPreviewRoot: true)

        XCTAssertFalse(text.contains("matches the current design"), text)
        XCTAssertTrue(text.contains("66"), text)
        XCTAssertTrue(text.lowercased().contains("could not be checked")
                      || text.lowercased().contains("do not record"), text)
    }

    func testAMachineWhoseCheckedDaysAreAllCurrentSaysSoAndOwnsWhatItSkipped() {
        let text = OutdatedDesignsDisplay.summary(survey(days: 10, recorded: 4),
                                                  hasPreviewRoot: true)

        XCTAssertTrue(text.contains("matches the current design"), text)
        XCTAssertTrue(text.contains("6"), "the six days it could not check must be "
                      + "owned in the same sentence, not left out: \(text)")
    }

    func testAMachineWhereEveryDayWasCheckedAndIsCurrentSaysJustThat() {
        let text = OutdatedDesignsDisplay.summary(survey(days: 4, recorded: 4),
                                                  hasPreviewRoot: true)

        XCTAssertTrue(text.contains("matches the current design"), text)
        XCTAssertFalse(text.lowercased().contains("could not be checked"),
                       "there is nothing unchecked to mention here: \(text)")
    }

    func testTheCountIsWrittenOutForOneDayAndForSeveral() {
        XCTAssertTrue(OutdatedDesignsDisplay
            .summary(survey(stale: 1, days: 1, recorded: 1), hasPreviewRoot: true)
            .hasPrefix("One day"))
        XCTAssertTrue(OutdatedDesignsDisplay
            .summary(survey(stale: 7, days: 7, recorded: 7), hasPreviewRoot: true)
            .hasPrefix("7 days"))
    }

    // MARK: - Days that have already gone out (#925)

    private func survey(staleNotExported: Int, staleExported: Int,
                        days: Int, recorded: Int) -> DesignScanResult {
        let exportedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let out = (0..<staleExported).map {
            StaleDay(eventSlug: "gone\($0)",
                     dayFolder: URL(fileURLWithPath: "/tmp/gone\($0)"),
                     dayLabel: "Thursday", templates: ["reel_scroll"],
                     exportedAt: exportedAt)
        }
        let waiting = (0..<staleNotExported).map {
            StaleDay(eventSlug: "here\($0)",
                     dayFolder: URL(fileURLWithPath: "/tmp/here\($0)"),
                     dayLabel: "Thursday", templates: ["reel_scroll"])
        }
        return DesignScanResult(stale: waiting + out,
                                daysWithAssets: days, daysWithARecord: recorded)
    }

    /// The whole point of #925: the list meant to point at work worth doing is
    /// padded with days where there is none, and the ratio gets worse as
    /// history builds. The count that leads the sentence is the actionable one.
    func testTheLeadingCountIsTheDaysStillWorthRebuilding() {
        let text = OutdatedDesignsDisplay.summary(
            survey(staleNotExported: 2, staleExported: 9, days: 11, recorded: 11),
            hasPreviewRoot: true)

        XCTAssertTrue(text.hasPrefix("2 days"),
                      "nine of the eleven have gone out and are not work: \(text)")
    }

    /// Counted, never dropped, so "nothing stale" stays a different answer from
    /// "nothing stale that has not gone out yet" (L98).
    func testTheExportedOnesAreStillCountedInTheSentence() {
        let text = OutdatedDesignsDisplay.summary(
            survey(staleNotExported: 2, staleExported: 9, days: 11, recorded: 11),
            hasPreviewRoot: true)

        XCTAssertTrue(text.contains("9"), text)
    }

    /// Exported is not posted, and the sentence may only claim what the record
    /// supports. The app knows the files were written into an export folder; it
    /// does not know they reached Instagram.
    func testTheSentenceSaysExportedRatherThanPosted() {
        let text = OutdatedDesignsDisplay.summary(
            survey(staleNotExported: 1, staleExported: 3, days: 4, recorded: 4),
            hasPreviewRoot: true).lowercased()

        XCTAssertTrue(text.contains("export"), text)
        XCTAssertFalse(text.contains("posted"), text)
        XCTAssertFalse(text.contains("published"), text)
    }

    /// With nothing recorded, the list has not shrunk and the sentence has to
    /// say why rather than let it read as "none of these has gone out". Every
    /// day folder on the machine is in that state the day this ships (L223).
    func testWithNoRecordsAtAllTheSentenceOwnsThatItCouldNotTell() {
        let text = OutdatedDesignsDisplay.summary(
            survey(staleNotExported: 12, staleExported: 0, days: 12, recorded: 12),
            hasPreviewRoot: true)

        XCTAssertTrue(text.hasPrefix("12 days"), text)
        XCTAssertTrue(text.lowercased().contains("records"), text)
        XCTAssertFalse(text.lowercased().contains("none of them has gone out"), text)
    }

    /// And it stops saying it once there is something to go on, so the line is
    /// not a permanent fixture nobody reads (L36).
    func testTheCouldNotTellLineGoesAwayOnceADayRecordsAnExport() {
        let text = OutdatedDesignsDisplay.summary(
            survey(staleNotExported: 11, staleExported: 1, days: 12, recorded: 12),
            hasPreviewRoot: true)

        XCTAssertFalse(text.lowercased().contains("no day here records"), text)
    }

    /// Nothing stale at all is still the reassuring sentence, and the export
    /// record has nothing to add to it.
    func testAnEntirelyCurrentLibraryIsUnchangedByTheExportRecord() {
        let text = OutdatedDesignsDisplay.summary(
            survey(staleNotExported: 0, staleExported: 0, days: 4, recorded: 4),
            hasPreviewRoot: true)

        XCTAssertTrue(text.contains("matches the current design"), text)
        XCTAssertFalse(text.lowercased().contains("export"), text)
    }

    /// Every day that has gone out is still reachable in its own section rather
    /// than hidden behind a count, so the surface never claims a cleaner
    /// machine than it measured.
    func testTheExportedDaysStillGroupIntoOpenableRows() {
        let e = event("Vocal Color", org: "DCINY", date: "2026-03-30")
        let slug = ArchiveCleanup.slug(event: e)
        let gone = StaleDay(eventSlug: slug,
                            dayFolder: URL(fileURLWithPath: "/tmp/\(slug)/Thursday"),
                            dayLabel: "Thursday", templates: ["reel_scroll"],
                            exportedAt: Date(timeIntervalSince1970: 1_780_000_000))

        let groups = OutdatedDesignsDisplay.groups([gone], events: [e])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].eventID, e.id)
    }

    /// What one already exported row says. It names the date, because "already
    /// exported" with no when is a claim the reader cannot weigh against a
    /// design change they remember making.
    func testAnExportedRowNamesWhenItWentOut() {
        let gone = StaleDay(eventSlug: "e", dayFolder: URL(fileURLWithPath: "/tmp/e"),
                            dayLabel: "Thursday", templates: ["reel_scroll"],
                            exportedAt: Date(timeIntervalSince1970: 1_780_000_000))

        let label = OutdatedDesignsDisplay.rowLabel(gone)

        XCTAssertTrue(label.contains("Thursday"), label)
        XCTAssertTrue(label.lowercased().contains("exported"), label)
    }

    func testARowWithNoRecordSaysNothingAboutExporting() {
        let label = OutdatedDesignsDisplay.rowLabel(day(slug: "e"))

        XCTAssertFalse(label.lowercased().contains("export"), label)
    }

    func testStaleDaysAndUncheckedDaysAreBothNamed() {
        // Two different facts about the same library, and reporting only the
        // first makes the second invisible for as long as it lasts.
        let text = OutdatedDesignsDisplay.summary(survey(stale: 2, days: 30, recorded: 5),
                                                  hasPreviewRoot: true)

        XCTAssertTrue(text.hasPrefix("2 days"), text)
        XCTAssertTrue(text.contains("25"), text)
    }

    // MARK: - How a row reads

    func testARowNamesTheDayAndWhatIsBehindOnIt() {
        let row = OutdatedDesignsDisplay.rowLabel(
            day(slug: "s", label: "Wednesday", templates: ["collage", "story"]))

        XCTAssertEqual(row, "Wednesday: collage and story graphic")
    }
}
