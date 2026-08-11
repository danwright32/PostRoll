import XCTest

/// #293: finding every day whose cached assets are behind, in one pass.
///
/// The per-day badge only shows on the day you happen to open, and there are 66
/// day folders across 12 events on disk. After a design version is bumped there
/// was no way to find which days it dated short of visiting every one of them.
final class DesignStaleScanTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesignStaleScanTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A day folder holding an asset stamped at `version`.
    @discardableResult
    private func day(_ event: String, _ folder: String,
                     asset: String = "reel_scroll.mp4",
                     stamped template: String = "reel_scroll",
                     version: Int?) -> URL {
        let dir = root.appendingPathComponent(event).appendingPathComponent(folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(asset).path,
                                       contents: Data("x".utf8))
        if let version {
            let stamp = ["templates": [template: version]]
            let data = try! JSONSerialization.data(withJSONObject: stamp)
            try! data.write(to: dir.appendingPathComponent(DesignStamp.stampName))
        }
        return dir
    }

    private var currentScrollVersion: Int {
        MediaDesign.version(of: "reel_scroll") ?? 1
    }

    // MARK: - What it finds

    func testADayStampedBehindTheCurrentDesignIsListed() {
        day("dciny_vocal_color_2026-03-30", "5. Thursday", version: currentScrollVersion - 1)

        let found = DesignStaleScan.scan(previewRoot: root).stale

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].eventSlug, "dciny_vocal_color_2026-03-30")
        XCTAssertEqual(found[0].dayLabel, "Thursday")
        XCTAssertEqual(found[0].templates, ["reel_scroll"])
    }

    func testADayStampedAtTheCurrentDesignIsNotListed() {
        day("event_a_2026-01-01", "5. Thursday", version: currentScrollVersion)

        XCTAssertEqual(DesignStaleScan.scan(previewRoot: root).stale.count, 0)
    }

    func testADayWithNoStampAtAllIsNotListed() {
        // Measured on the real data, not assumed: treating "no record" as stale
        // badged all 66 day folders at once, and a badge on every day is one
        // nobody reads. The same rule has to hold here or this surface lists
        // every day on the machine the first time it is opened.
        day("event_a_2026-01-01", "5. Thursday", version: nil)

        XCTAssertEqual(DesignStaleScan.scan(previewRoot: root).stale.count, 0)
    }

    func testEveryEventAndEveryDayIsWalked() {
        day("event_a_2026-01-01", "3. Tuesday", asset: "reel_morph.mp4",
            stamped: "reel_morph", version: 0)
        day("event_a_2026-01-01", "5. Thursday", version: currentScrollVersion - 1)
        day("event_b_2026-02-02", "5. Thursday", version: currentScrollVersion - 1)

        let found = DesignStaleScan.scan(previewRoot: root).stale

        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found.map(\.dayLabel), ["Tuesday", "Thursday", "Thursday"])
        XCTAssertEqual(Set(found.map(\.eventSlug)),
                       ["event_a_2026-01-01", "event_b_2026-02-02"])
    }

    func testTheOrderIsStableAcrossScans() {
        day("event_b_2026-02-02", "5. Thursday", version: 0)
        day("event_a_2026-01-01", "5. Thursday", version: 0)
        day("event_a_2026-01-01", "3. Tuesday", asset: "reel_morph.mp4",
            stamped: "reel_morph", version: 0)

        let first = DesignStaleScan.scan(previewRoot: root).stale.map(\.id)
        let second = DesignStaleScan.scan(previewRoot: root).stale.map(\.id)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 3)
        // Day 3 before day 5 within an event: the numbers are there to order
        // them, and a plain string sort would put "10." before "3.".
        XCTAssertTrue(first[0].hasSuffix("3. Tuesday"), first[0])
    }

    // MARK: - Nothing found is not the same as nothing to look at

    func testAPreviewRootThatDoesNotExistIsReportedAsSuch() {
        let missing = root.appendingPathComponent("never-rendered")

        XCTAssertFalse(DesignStaleScan.hasPreviewRoot(missing))
        XCTAssertEqual(DesignStaleScan.scan(previewRoot: missing).stale, [])
    }

    func testAPreviewRootThatExistsIsReportedAsSuch() {
        XCTAssertTrue(DesignStaleScan.hasPreviewRoot(root))
    }

    func testAFileWhereAnEventFolderShouldBeIsIgnored() {
        FileManager.default.createFile(atPath: root.appendingPathComponent("stray.txt").path,
                                       contents: Data("x".utf8))

        XCTAssertEqual(DesignStaleScan.scan(previewRoot: root).stale, [])
    }

    // MARK: - An empty list is not a clean bill of health (#311)

    /// #311 measured the real library: all 66 day folders carry no record, and
    /// every asset on disk predates two changes that alter what a template
    /// renders (the bottom-only crop of 2026-08-07, the shared org and venue
    /// detail lines of 2026-08-10). Backfilling a version onto them was
    /// rejected, because a stamp is a record and that one would be a guess.
    ///
    /// So the permanent state of this surface on Dan's Mac is an empty list,
    /// and an empty list that reads as "everything is current" is the exact
    /// shape of L98: finding nothing to check is not the same as everything
    /// passing. The scan has to report how many days it looked at and how many
    /// of them could be compared at all.

    func testItSaysHowManyDaysItLookedAtEvenWhenNoneAreStale() {
        day("event_a_2026-01-01", "5. Thursday", version: nil)
        day("event_a_2026-01-01", "3. Tuesday", asset: "reel_morph.mp4",
            stamped: "reel_morph", version: nil)

        let found = DesignStaleScan.scan(previewRoot: root)

        XCTAssertEqual(found.stale, [])
        XCTAssertEqual(found.daysWithAssets, 2)
        XCTAssertEqual(found.daysWithARecord, 0,
                       "neither day records which design made it, so neither was "
                       + "compared against anything")
    }

    func testADayCarryingARecordCountsAsOneThatCouldBeChecked() {
        day("event_a_2026-01-01", "5. Thursday", version: currentScrollVersion)

        let found = DesignStaleScan.scan(previewRoot: root)

        XCTAssertEqual(found.stale, [])
        XCTAssertEqual(found.daysWithAssets, 1)
        XCTAssertEqual(found.daysWithARecord, 1)
    }

    func testACollageWhoseSidecarRecordsItsVersionCountsAsChecked() {
        // The sidecar #160 writes is a record too, and the reader already fills
        // the collage in from it. A day counted as unrecorded because only its
        // sidecar knows would understate what was actually compared.
        let dir = root.appendingPathComponent("event_a_2026-01-01")
            .appendingPathComponent("4. Wednesday")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("collage.png").path,
                                       contents: Data("x".utf8))
        let sidecar = ["version": MediaDesign.version(of: "collage") ?? 1, "cells": []] as [String: Any]
        try! JSONSerialization.data(withJSONObject: sidecar)
            .write(to: dir.appendingPathComponent("collage_layout.json"))

        let found = DesignStaleScan.scan(previewRoot: root)

        XCTAssertEqual(found.daysWithAssets, 1)
        XCTAssertEqual(found.daysWithARecord, 1)
    }

    func testADayFolderHoldingNothingVersionedIsNotCountedAsADay() {
        // An export leftover or a folder the run created and never filled. It
        // has no assets to be old, so counting it would inflate the number the
        // sentence quotes.
        let dir = root.appendingPathComponent("event_a_2026-01-01")
            .appendingPathComponent("7. Notes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("captions.txt").path,
                                       contents: Data("x".utf8))

        let found = DesignStaleScan.scan(previewRoot: root)

        XCTAssertEqual(found.daysWithAssets, 0)
        XCTAssertEqual(found.daysWithARecord, 0)
    }

    func testAStaleDayIsAlsoADayThatCouldBeChecked() {
        // The counts have to stay consistent with the list: a day that produced
        // a row necessarily carried a record, or it could not have been judged.
        day("event_a_2026-01-01", "5. Thursday", version: currentScrollVersion - 1)

        let found = DesignStaleScan.scan(previewRoot: root)

        XCTAssertEqual(found.stale.count, 1)
        XCTAssertEqual(found.daysWithARecord, 1)
        XCTAssertEqual(found.daysWithAssets, 1)
    }

    // MARK: - How a row reads

    func testTheDayLabelDropsTheOrderingNumber() {
        XCTAssertEqual(DesignStaleScan.dayLabel(from: "5. Thursday"), "Thursday")
        XCTAssertEqual(DesignStaleScan.dayLabel(from: "1. Sunday"), "Sunday")
    }

    func testAFolderNameWithNoNumberIsLeftAlone() {
        XCTAssertEqual(DesignStaleScan.dayLabel(from: "Thursday"), "Thursday")
        XCTAssertEqual(DesignStaleScan.dayLabel(from: "odd. name"), "odd. name")
    }

    func testTheAssetsAreNamedInWordsRatherThanAsFilenames() {
        // A row reading "reel_scroll is out of date" reads as a bug report
        // rather than as something to act on.
        let one = StaleDay(eventSlug: "e", dayFolder: root, dayLabel: "Thursday",
                           templates: ["reel_scroll"])
        let two = StaleDay(eventSlug: "e", dayFolder: root, dayLabel: "Thursday",
                           templates: ["reel_scroll", "reel_preview"])
        let three = StaleDay(eventSlug: "e", dayFolder: root, dayLabel: "Wednesday",
                             templates: ["collage", "story", "cover"])

        XCTAssertEqual(one.listedTemplates, "scroll reel")
        XCTAssertEqual(two.listedTemplates, "scroll reel and scroll reel preview")
        XCTAssertEqual(three.listedTemplates, "collage, story graphic, and cover image")
    }
}
