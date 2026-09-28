import XCTest

/// Editing an event's name, organisation and venue after it exists (#1448).
///
/// The folder an event's media lives in was named from those same fields and
/// found again by rebuilding the name from them, so any change to one lost the
/// folder. Worse than lost: the orphan sweep deletes every preview folder no
/// live event resolves to, so an edit would have cost the rendered week. The
/// name an event was rendered under is now pinned on the event the moment an
/// edit would move it, and every reader resolves through `EventFolder`.
final class EventDetailsEditTests: XCTestCase {

    private let showDate = Date(timeIntervalSince1970: 1_789_000_000)

    private func broadwayUndressed(rendered: Bool) -> Event {
        var ev = Event(name: "Broadway Undressed", org: "Tom Guthrie", venue: "54 Below",
                       date: showDate, shootType: .fullShow)
        if rendered {
            ev.previewMediaPaths = ["wednesday": ["collage": "/tmp/collage.png"]]
        }
        return ev
    }

    private func edit(_ ev: Event, org: String = "Tom Guthrie",
                      name: String = "Broadway Undressed") -> Event {
        NewEventForm.edited(ev, name: name, org: org, venue: ev.venue,
                            venueContext: ev.venueContext)
    }

    func testAnEditToARenderedEventKeepsTheFolderItWasRenderedUnder() {
        let before = broadwayUndressed(rendered: true)
        let original = EventFolder.name(for: before)

        let after = edit(before, org: "")

        XCTAssertEqual(after.org, "")
        XCTAssertEqual(EventFolder.name(for: after), original)
        XCTAssertTrue(original.hasPrefix("tom_guthrie_"), original)
    }

    func testAnEditToAnEventWithNothingOnDiskFollowsTheNewDetails() {
        // Nothing was rendered under the old name, so there is nothing to keep,
        // and a Duplicate (which clears its media) edited into a second night
        // must not end up writing into the first night's folder.
        let after = edit(broadwayUndressed(rendered: false), org: "")

        XCTAssertNil(after.folderName)
        XCTAssertTrue(EventFolder.name(for: after).hasPrefix("54_below_broadway_undressed_"),
                      EventFolder.name(for: after))
    }

    func testAnExportedEventCountsAsHavingAFolder() {
        var ev = broadwayUndressed(rendered: false)
        ev.exportPath = URL(fileURLWithPath: "/tmp/socials/tom_guthrie_broadway_undressed")
        let original = EventFolder.name(for: ev)

        XCTAssertEqual(EventFolder.name(for: edit(ev, org: "")), original)
    }

    func testASecondEditKeepsTheNamePinnedByTheFirst() {
        let before = broadwayUndressed(rendered: true)
        let original = EventFolder.name(for: before)

        let twice = edit(edit(before, org: ""), name: "Broadway Undressed Encore")

        XCTAssertEqual(EventFolder.name(for: twice), original)
    }

    func testAnEditChangesOnlyTheFourDetails() {
        var before = broadwayUndressed(rendered: true)
        before.stage = .captionsReviewed
        before.mediaErrors = ["friday": "boom"]

        let after = NewEventForm.edited(before, name: "New Name", org: "New Org",
                                        venue: "Joe's Pub", venueContext: "Upstairs")

        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.date, before.date)
        XCTAssertEqual(after.shootType, before.shootType)
        XCTAssertEqual(after.stage, before.stage)
        XCTAssertEqual(after.previewMediaPaths, before.previewMediaPaths)
        XCTAssertEqual(after.mediaErrors, before.mediaErrors)
        XCTAssertEqual([after.name, after.org, after.venue, after.venueContext],
                       ["New Name", "New Org", "Joe's Pub", "Upstairs"])
    }

    func testAnEditFoldsEveryFieldToOneLine() {
        // The same rule Create applies (#688), since these reach captions and
        // the handle book's keys exactly as they did before.
        let after = NewEventForm.edited(broadwayUndressed(rendered: false),
                                        name: "Broadway\nUndressed", org: " Tom  Guthrie ",
                                        venue: "54\nBelow", venueContext: "Main\nRoom")

        XCTAssertEqual([after.name, after.org, after.venue, after.venueContext],
                       ["Broadway Undressed", "Tom Guthrie", "54 Below", "Main Room"])
    }

    func testThePinnedFolderNameSurvivesTheStore() throws {
        let pinned = edit(broadwayUndressed(rendered: true), org: "")

        let back = try JSONDecoder().decode(Event.self, from: JSONEncoder().encode(pinned))

        XCTAssertEqual(back.folderName, pinned.folderName)
        XCTAssertEqual(EventFolder.name(for: back), EventFolder.name(for: pinned))
    }

    func testAnEventStoredBeforeThisStillFindsItsFolder() throws {
        // Every event on disk today has no pinned name, and must resolve to the
        // folder it already has.
        let legacy = broadwayUndressed(rendered: true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
            as! [String: Any]
        json.removeValue(forKey: "folderName")

        let back = try JSONDecoder().decode(
            Event.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertNil(back.folderName)
        XCTAssertEqual(EventFolder.name(for: back),
                       EventFolder.name(org: "Tom Guthrie", venue: "54 Below",
                                        name: "Broadway Undressed", isoDate: legacy.isoDate))
    }

    func testTheOrphanSweepKeepsTheFolderOfAnEditedEvent() throws {
        // The failure this whole change exists to prevent: the sweep deletes a
        // preview folder no event resolves to, so an edit that moved the name
        // would have deleted the week Dan had just rendered.
        let previewDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-details-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: previewDir) }
        let before = broadwayUndressed(rendered: true)
        let folder = previewDir.appendingPathComponent(EventFolder.name(for: before))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let removed = OrphanedMediaCleanup.sweepPreviewFolders(
            events: [edit(before, org: "")], previewDir: previewDir)

        XCTAssertEqual(removed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testTheMediaManifestNamesThePinnedFolder() {
        // Python builds the folder it renders into; it has to be told the
        // pinned name, or it renders the edited event into a new folder the
        // sweep then deletes as an orphan.
        let pinned = edit(broadwayUndressed(rendered: true), org: "")

        let manifest = PythonBridge.shared.buildMediaManifest(event: pinned)

        XCTAssertEqual(manifest["folder_name"] as? String, EventFolder.name(for: pinned))
    }

    @MainActor
    func testADuplicateDoesNotInheritAPinnedFolder() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-details-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = edit(broadwayUndressed(rendered: true), org: "")
        let state = AppState(events: [pinned],
                             storeURL: root.appendingPathComponent("events.json"),
                             dataRoot: root)

        let copyID = state.duplicateEvent(id: pinned.id)
        let copy = state.events.first { $0.id == copyID }

        XCTAssertNil(copy?.folderName)
    }

    // MARK: - What a save offers to refresh

    func testASaveThatChangedNothingOffersNothing() {
        let ev = broadwayUndressed(rendered: true)

        let saved = EventDetailsSave(before: ev, after: edit(ev))

        XCTAssertFalse(saved.changed)
        XCTAssertEqual(saved.refreshDays, [])
    }

    func testAChangedDetailOffersEveryRenderedDayInWeekOrder() {
        // Nearly every template prints the organisation or venue, so every day
        // with graphics is redrawn, never a guessed subset.
        var ev = broadwayUndressed(rendered: false)
        ev.previewMediaPaths = ["wednesday": ["collage": "/c.png"],
                                "sunday": ["story": "/s.png"],
                                "thursday": ["reel": "/r.mp4"]]

        let saved = EventDetailsSave(before: ev, after: edit(ev, org: ""))

        XCTAssertTrue(saved.changed)
        XCTAssertEqual(saved.refreshDays, [.sunday, .wednesday, .thursday])
    }

    func testAChangedHallAloneRedrawsNothing() {
        // It reaches the blog and captions only; no template prints it.
        let ev = broadwayUndressed(rendered: true)

        let saved = EventDetailsSave(before: ev, after: NewEventForm.edited(
            ev, name: ev.name, org: ev.org, venue: ev.venue, venueContext: "Main Room"))

        XCTAssertTrue(saved.changed)
        XCTAssertEqual(saved.refreshDays, [])
    }

    func testAChangedEventWithNothingRenderedHasNothingToRefresh() {
        let ev = broadwayUndressed(rendered: false)

        let saved = EventDetailsSave(before: ev, after: edit(ev, org: ""))

        XCTAssertTrue(saved.changed)
        XCTAssertEqual(saved.refreshDays, [])
    }

    func testAnExportedEventSaysTheExportKeepsTheOldText() {
        var ev = broadwayUndressed(rendered: true)
        ev.stage = .exported
        ev.exportPath = URL(fileURLWithPath: "/tmp/socials/x")

        XCTAssertTrue(EventDetailsSave(before: ev, after: edit(ev, org: "")).exportIsStale)
        XCTAssertFalse(EventDetailsSave(before: ev, after: edit(ev)).exportIsStale,
                       "nothing changed, so the export is exactly as current as it was")
        XCTAssertFalse(EventDetailsSave(before: broadwayUndressed(rendered: true),
                                        after: edit(broadwayUndressed(rendered: true), org: ""))
                        .exportIsStale)
    }

    // MARK: - Refresh text

    func testAnEditLeavesEveryPhotoWhereDanPutIt() throws {
        // Refresh text is a redraw from the edited event, so what it hands
        // Python for each day (the layout seed, every crop and zoom) has to be
        // exactly what it was before the edit. Only the words may move.
        var before = broadwayUndressed(rendered: true)
        var wednesday = PostingDay(day: .wednesday)
        wednesday.photoPaths = (1...4).map { URL(fileURLWithPath: "/photos/\($0).jpg") }
        wednesday.collageSeed = 424_242
        wednesday.collageCropOffsets = [wednesday.photoPaths[1].absoluteString:
                                            CropOffset(x: 0.3, y: -0.2, scale: 1.4)]
        before.days["wednesday"] = wednesday

        let after = edit(before, org: "")
        let bridge = PythonBridge.shared
        let days = { (ev: Event) in
            try JSONSerialization.data(withJSONObject: bridge.buildMediaManifest(event: ev)["days"]!,
                                       options: .sortedKeys)
        }

        XCTAssertEqual(try days(after), try days(before))
        XCTAssertEqual(bridge.buildMediaManifest(event: after)["org"] as? String, "")
    }

    private actor Reached {
        private(set) var event: Event?
        func record(_ e: Event) { event = e }
    }

    private static func waitUntil(_ message: String,
                                  until condition: @Sendable () async -> Bool) async {
        // On the condition, never a fixed time (L290).
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(message)
    }

    @MainActor
    func testARefreshCanBeStoppedAndAStopIsNotAFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-details-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ev = edit(broadwayUndressed(rendered: true), org: "")
        let state = AppState(events: [ev],
                             storeURL: root.appendingPathComponent("events.json"),
                             dataRoot: root)
        let manager = PreviewGraphicsManager()
        let reached = Reached()
        manager.renderPreview = { rendering, _ in
            await reached.record(rendering)
            // Stands in for a render that takes minutes, and ends only when
            // it is cancelled, as the real subprocess does.
            try await Task.sleep(for: .seconds(600))
            return PythonBridge.PreviewGenerationResult(paths: [:], errors: [:])
        }

        XCTAssertTrue(manager.startRedraw([.wednesday], for: ev.id, appState: state,
                                          work: .detailsEdited))
        await Self.waitUntil("the refresh never started") { await reached.event != nil }
        let rendered = await reached.event
        XCTAssertEqual(rendered?.org, "", "it rendered the old details")

        XCTAssertTrue(manager.stopRedraw(ev.id))
        XCTAssertTrue(manager.isStoppingRedraw(ev.id),
                      "a stop that looks like nothing happened until the spinner goes")
        await Self.waitUntil("the stopped refresh never let go of its day") {
            await MainActor.run { manager.regeneratingDays(ev.id).isEmpty }
        }

        XCTAssertNil(manager.dayFailure(.wednesday, for: ev.id),
                     "Dan asked for the stop, so it is not a failure to report")
        XCTAssertFalse(manager.isStoppingRedraw(ev.id))
        XCTAssertFalse(manager.stopRedraw(ev.id), "there is nothing left to stop")
        XCTAssertEqual(state.events.first?.previewMediaPaths, ev.previewMediaPaths,
                       "a stopped refresh keeps the graphics it never replaced")
    }

    @MainActor
    func testTwoRedrawsOfOneEventEachStayStoppable() async throws {
        // A refresh and a layout switch can redraw different days of the same
        // event at once. When one finishes, the other must still be stoppable,
        // or its Stop button does nothing for the rest of a long render.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-details-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ev = edit(broadwayUndressed(rendered: true), org: "")
        let state = AppState(events: [ev],
                             storeURL: root.appendingPathComponent("events.json"),
                             dataRoot: root)
        let manager = PreviewGraphicsManager()
        let started = Reached()
        manager.renderPreview = { rendering, days in
            await started.record(rendering)
            if days == ["sunday"] {
                return PythonBridge.PreviewGenerationResult(paths: [:], errors: [:])
            }
            try await Task.sleep(for: .seconds(600))
            return PythonBridge.PreviewGenerationResult(paths: [:], errors: [:])
        }

        XCTAssertTrue(manager.startRedraw([.wednesday], for: ev.id, appState: state,
                                          work: .detailsEdited))
        XCTAssertTrue(manager.startRedraw([.sunday], for: ev.id, appState: state,
                                          work: .layoutSwitch))
        await Self.waitUntil("the quick redraw never finished") {
            await MainActor.run { !manager.regeneratingDays(ev.id).contains(.sunday) }
        }

        XCTAssertTrue(manager.stopRedraw(ev.id),
                      "the long redraw is still running and must still be stoppable")
        await Self.waitUntil("the stopped redraw never let go of its day") {
            await MainActor.run { manager.regeneratingDays(ev.id).isEmpty }
        }
        XCTAssertNil(manager.dayFailure(.wednesday, for: ev.id))
    }
}

