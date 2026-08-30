import XCTest

/// Coverage for the posting preset spec (`PostingPreset`) that decides each
/// day's shape, and the persistence in `PostingPresetStore`. The mapping here
/// must mirror `postroll/posting_preset.py` exactly.
final class PostingPresetTests: XCTestCase {

    func testBalancedMakesSunMonWedCollageCarousels() {
        for day in [DayName.sunday, .monday, .wednesday] {
            let fmt = PostingPreset.balanced.format(for: day)
            XCTAssertEqual(fmt?.format, .collageCarousel, "\(day) should be a carousel under balanced")
            XCTAssertEqual(fmt?.count, 4, "\(day) should use 4 photos under balanced")
            XCTAssertTrue(PostingPreset.balanced.isCollageCarousel(day))
        }
    }

    func testClassicMatchesOriginalOneOneTen() {
        XCTAssertEqual(PostingPreset.classic.format(for: .sunday)?.format, .single)
        XCTAssertEqual(PostingPreset.classic.format(for: .sunday)?.count, 1)
        XCTAssertEqual(PostingPreset.classic.format(for: .monday)?.format, .single)
        XCTAssertEqual(PostingPreset.classic.format(for: .wednesday)?.format, .collageCarousel)
        XCTAssertEqual(PostingPreset.classic.format(for: .wednesday)?.count, 10)
        XCTAssertFalse(PostingPreset.classic.isCollageCarousel(.sunday))
    }

    func testNonGovernedDaysReturnNilInEveryPreset() {
        for preset in PostingPreset.allCases {
            for day in [DayName.tuesday, .thursday, .friday] {
                XCTAssertNil(preset.format(for: day), "\(day) is not governed by \(preset)")
            }
        }
    }

    func testRawValuesMatchPythonContract() {
        // These strings travel in the manifest to Python — they must not drift.
        XCTAssertEqual(PostingPreset.balanced.rawValue, "balanced")
        XCTAssertEqual(PostingPreset.classic.rawValue, "classic")
        XCTAssertEqual(PostingPreset.opening.rawValue, "opening")
    }

    // MARK: - #900, seven on Sunday

    func testOpeningGivesSundaySevenAndLeavesTheOthersAlone() {
        XCTAssertEqual(PostingPreset.opening.format(for: .sunday)?.count, 7)
        XCTAssertEqual(PostingPreset.opening.format(for: .monday)?.count, 4)
        XCTAssertEqual(PostingPreset.opening.format(for: .wednesday)?.count, 4)
        for day in [DayName.sunday, .monday, .wednesday] {
            XCTAssertTrue(PostingPreset.opening.isCollageCarousel(day))
        }
    }

    /// The default is untouched. This preset is additive: every existing event
    /// renders exactly what it rendered before.
    func testTheDefaultIsStillBalancedAndStillFour() {
        XCTAssertEqual(PostingPreset.current(in: UserDefaults(
            suiteName: "posting-preset-\(UUID().uuidString)")!), .balanced)
        XCTAssertEqual(PostingPreset.balanced.format(for: .sunday)?.count, 4)
    }

    /// Confirmed rather than assumed (#900). Both of these already read the
    /// preset's target rather than a literal, which is what #195 and #119
    /// fixed, so raising Sunday to 7 should carry them with it for free. That
    /// is a claim about code nobody touched, and a claim nobody checks is the
    /// kind that turns out to be wrong.
    func testTheExtraPhotosNoticeFollowsTheNewTargetRatherThanFour() {
        XCTAssertNil(CollagePhotoSelection.extraPhotosNote(
            photoCount: 7, preset: .opening, day: .sunday),
                     "the notice fired at exactly the count the preset asks for")

        let note = CollagePhotoSelection.extraPhotosNote(
            photoCount: 8, preset: .opening, day: .sunday)
        XCTAssertEqual(note?.contains("first 7 photos"), true, note ?? "nil")
    }

    func testSevenIsInsideTheRangeThatOffersOtherLayouts() {
        XCTAssertTrue(CollagePhotoSelection.offersAlternativeLayouts(photoCount: 7))
    }

    func testTheTargetForAnOpeningSundayIsSeven() {
        XCTAssertEqual(CollagePhotoSelection.target(preset: .opening, day: .sunday), 7)
        XCTAssertEqual(CollagePhotoSelection.target(preset: .opening, day: .monday), 4)
    }

    // MARK: - Collage photo selection floor (#63)

    func testCollageTargetMatchesPreset() {
        XCTAssertEqual(CollagePhotoSelection.target(preset: .balanced, day: .sunday), 4)
        XCTAssertEqual(CollagePhotoSelection.target(preset: .classic, day: .wednesday), 10)
    }

    func testCollageSelectionAllowsFewerThanTarget() {
        // A balanced day targets 4, but picking 3 must be allowed — the
        // generator adapts. Only below the 2-photo floor is rejected.
        XCTAssertNil(CollagePhotoSelection.validationError(selectedCount: 3, dayDisplayName: "Sunday"))
        XCTAssertNil(CollagePhotoSelection.validationError(selectedCount: 2, dayDisplayName: "Sunday"))
    }

    func testCollageSelectionRejectsBelowFloor() {
        let message = CollagePhotoSelection.validationError(selectedCount: 1, dayDisplayName: "Sunday")
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("at least 2") ?? false)
        XCTAssertTrue(message?.contains("Sunday") ?? false)
    }

    // MARK: - What a switch actually has to rebuild (#1010)

    private func eventWith(_ counts: [DayName: Int]) -> Event {
        var event = Event(name: "Show", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        for (day, n) in counts {
            var pd = PostingDay(day: day)
            pd.photoPaths = (0..<n).map { URL(fileURLWithPath: "/\(day.rawValue)-\($0).jpg") }
            event.days[day.rawValue] = pd
        }
        return event
    }

    /// Dan's own case, and the whole reason for #1010.
    ///
    /// Balanced to Opening moves Sunday from 4 photos to 7 and leaves Monday
    /// and Wednesday exactly as they were. Today every governed day with photos
    /// is rebuilt, so two days are caption regenerated for nothing: paid API
    /// calls, and any caption edits on those days destroyed.
    func testBalancedToOpeningTouchesSundayAlone() {
        let event = eventWith([.sunday: 8, .monday: 8, .wednesday: 8])
        let plan = PostingLayoutSwitch.plan(from: .balanced, to: .opening, in: event)

        XCTAssertEqual(plan[.sunday], .redrawImages,
                       "Sunday goes from 4 photos to 7, so its images change")
        XCTAssertNil(plan[.monday], "Monday posts 4 either way, so nothing about it changes")
        XCTAssertNil(plan[.wednesday], "Wednesday posts 4 either way")
    }

    /// A day whose post TYPE changes is the only kind that costs a caption call.
    func testBalancedToClassicRebuildsTheDaysThatBecomeADifferentPost() {
        let event = eventWith([.sunday: 8, .monday: 8, .wednesday: 8])
        let plan = PostingLayoutSwitch.plan(from: .balanced, to: .classic, in: event)

        XCTAssertEqual(plan[.sunday], .rebuildPost,
                       "a 4 photo carousel becoming a single photo post is a different post")
        XCTAssertEqual(plan[.monday], .rebuildPost)
        XCTAssertEqual(plan[.wednesday], .redrawImages,
                       "Wednesday stays a carousel and only its count moves, 4 to 10")
    }

    /// The case the plan for this originally got wrong.
    ///
    /// A collage day with ONE assigned photo is a feed_photo under Python's own
    /// rule, exactly like a single day with one. So Balanced to Classic changes
    /// the FORMAT and does not change the post, and keying the paid half on
    /// format alone would pay for a caption rebuild that changes nothing.
    func testADayWithOnePhotoNeedsNoCaptionRebuildWhenTheFormatChanges() {
        let event = eventWith([.sunday: 1])
        let plan = PostingLayoutSwitch.plan(from: .balanced, to: .classic, in: event)

        XCTAssertNotEqual(plan[.sunday], .rebuildPost,
                          "one photo posts the same way under both layouts, so a paid "
                          + "caption call here buys nothing")
    }

    /// Effective counts, not preset targets.
    ///
    /// A Sunday with three photos posts three under Balanced and three under
    /// Opening, because the renderer takes photos[:count] and there are only
    /// three. Nothing about that day changes, so nothing about it rebuilds.
    func testADayWithFewerPhotosThanEitherTargetIsUntouched() {
        let event = eventWith([.sunday: 3])
        XCTAssertTrue(PostingLayoutSwitch.plan(from: .balanced, to: .opening, in: event).isEmpty,
                      "both layouts post all three photos, so the switch changes nothing")
    }

    func testADayWithNoPhotosIsNeverInThePlan() {
        let event = eventWith([.sunday: 0, .monday: 5])
        let plan = PostingLayoutSwitch.plan(from: .balanced, to: .classic, in: event)
        XCTAssertNil(plan[.sunday], "there is nothing to draw or write for a day with no photos")
    }

    /// Days no preset governs are never in the plan, whatever is assigned.
    func testUngovernedDaysAreNeverInThePlan() {
        let event = eventWith([.tuesday: 6, .thursday: 40, .friday: 3])
        let plan = PostingLayoutSwitch.plan(from: .balanced, to: .classic, in: event)
        XCTAssertTrue(plan.isEmpty, "Tuesday, Thursday and Friday have fixed formats")
    }

    /// Switching back is symmetric, and just as narrow.
    func testOpeningBackToBalancedAlsoTouchesSundayAlone() {
        let event = eventWith([.sunday: 8, .monday: 8, .wednesday: 8])
        let plan = PostingLayoutSwitch.plan(from: .opening, to: .balanced, in: event)
        XCTAssertEqual(plan[.sunday], .redrawImages)
        XCTAssertNil(plan[.monday])
        XCTAssertNil(plan[.wednesday])
    }

    /// A switch to the layout already in force is not a switch.
    func testSwitchingToTheSameLayoutPlansNothing() {
        let event = eventWith([.sunday: 8, .monday: 8, .wednesday: 8])
        XCTAssertTrue(PostingLayoutSwitch.plan(from: .opening, to: .opening, in: event).isEmpty)
    }

    /// What licenses giving a layout switch its own narrow redraw route.
    ///
    /// The review screen's render driver is tangled up with Thursday's
    /// speculative reel adoption and Friday's clip plan. None of that can ever
    /// apply to a layout switch, because no preset governs those days: whatever
    /// the two layouts are, a switch between them can only ever name Sunday,
    /// Monday or Wednesday.
    ///
    /// Asserted rather than assumed, over EVERY ordered pair of layouts, because
    /// the narrow route is only safe for as long as it stays true. A fourth
    /// preset that governed Thursday would make it false silently.
    func testNoSwitchBetweenAnyTwoLayoutsCanEverNameThursdayOrFriday() {
        let event = eventWith([.sunday: 9, .monday: 9, .wednesday: 9,
                               .tuesday: 9, .thursday: 40, .friday: 9])
        for old in PostingPreset.allCases {
            for new in PostingPreset.allCases {
                let days = Set(PostingLayoutSwitch.plan(from: old, to: new, in: event).keys)
                XCTAssertTrue(days.isSubset(of: [.sunday, .monday, .wednesday]),
                              "\(old.rawValue) to \(new.rawValue) names \(days), and a "
                              + "switch that can reach Thursday or Friday cannot use the "
                              + "narrow redraw route")
            }
        }
    }

    // MARK: - Splitting the plan into the two kinds of work (#1010)

    /// The whole point of #1010, stated as a value.
    ///
    /// Only days whose POST changes cost a caption call. Everything else is
    /// images, which are free. Today every governed day with photos went to the
    /// caption generator, so this is the assertion that the money stops.
    func testBalancedToOpeningAsksForNoCaptionWorkAtAll() {
        let event = eventWith([.sunday: 8, .monday: 8, .wednesday: 8])
        let work = PostingLayoutSwitch.work(
            PostingLayoutSwitch.plan(from: .balanced, to: .opening, in: event))

        XCTAssertTrue(work.rebuildDays.isEmpty,
                      "no day becomes a different post, so no caption call is needed: "
                      + "\(work.rebuildDays)")
        XCTAssertEqual(work.redrawDays, [.sunday],
                       "Sunday's images change and nothing else does")
    }

    func testBalancedToClassicSplitsTheTwoKindsOfWork() {
        let event = eventWith([.sunday: 8, .monday: 8, .wednesday: 8])
        let work = PostingLayoutSwitch.work(
            PostingLayoutSwitch.plan(from: .balanced, to: .classic, in: event))

        XCTAssertEqual(work.rebuildDays, ["sunday", "monday"],
                       "both become single photo posts, which are written differently")
        XCTAssertEqual(work.redrawDays, [.wednesday],
                       "Wednesday stays a carousel and only its count moves")
    }

    func testAnEmptyPlanAsksForNothing() {
        let work = PostingLayoutSwitch.work([:])
        XCTAssertTrue(work.rebuildDays.isEmpty)
        XCTAssertTrue(work.redrawDays.isEmpty)
    }

    /// A day is in exactly one of the two, never both.
    ///
    /// Both halves write that day's media, so a day in both would be two
    /// writers on one file, which is what #1009's exclusion exists to stop.
    func testNoDayIsInBothKindsOfWork() {
        let event = eventWith([.sunday: 8, .monday: 8, .wednesday: 8])
        for old in PostingPreset.allCases {
            for new in PostingPreset.allCases {
                let work = PostingLayoutSwitch.work(
                    PostingLayoutSwitch.plan(from: old, to: new, in: event))
                let overlap = work.rebuildDays.intersection(
                    Set(work.redrawDays.map(\.rawValue)))
                XCTAssertTrue(overlap.isEmpty,
                              "\(old.rawValue) to \(new.rawValue) would run two writers "
                              + "on \(overlap)")
            }
        }
    }

    // MARK: - Per-event override (#66)

    private func makeEvent() -> Event {
        Event(name: "Show", org: "Org", venue: "Hall",
              date: Date(timeIntervalSince1970: 1_700_000_000), shootType: .fullShow)
    }

    /// A scratch defaults store holding this preset, handed to the code under
    /// test.
    ///
    /// The real preference is never read or written. Saving and restoring it
    /// around the test was careful but not safe: a crash between the two left
    /// Dan's actual posting layout changed, and two suites running at once
    /// clobbered each other (#116).
    private func scratchDefaults(_ preset: PostingPreset) -> UserDefaults {
        let suite = "postroll.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(preset.rawValue, forKey: PostingPreset.storageKey)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func withGlobalPreset(_ preset: PostingPreset,
                                  _ body: (UserDefaults) -> Void) {
        body(scratchDefaults(preset))
    }

    func testEffectivePresetUsesOverrideWhenSet() {
        var event = makeEvent()
        event.postingPresetOverride = .classic
        // The override wins regardless of the global default.
        withGlobalPreset(.balanced) { defaults in
            XCTAssertEqual(event.effectivePostingPreset(in: defaults), .classic)
        }
    }

    func testEffectivePresetFallsBackToGlobalWhenNoOverride() {
        var event = makeEvent()
        event.postingPresetOverride = nil
        withGlobalPreset(.classic) { defaults in
            XCTAssertEqual(event.effectivePostingPreset(in: defaults), .classic)
        }
        withGlobalPreset(.balanced) { defaults in
            XCTAssertEqual(event.effectivePostingPreset(in: defaults), .balanced)
        }
    }

    func testOverrideSurvivesCodableRoundTrip() throws {
        var event = makeEvent()
        event.postingPresetOverride = .classic
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(Event.self, from: data)
        XCTAssertEqual(decoded.postingPresetOverride, .classic)
    }

    func testMissingOverrideDecodesAsNil() throws {
        // An event saved before this field existed must decode with no override.
        var event = makeEvent()
        event.postingPresetOverride = nil
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(Event.self, from: data)
        XCTAssertNil(decoded.postingPresetOverride)
    }

    @MainActor
    func testStoreDefaultsToBalancedAndPersists() {
        // Its own scratch suite, so the real preference is neither read nor
        // written and two suites running at once cannot collide (#116).
        let suite = "postroll.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }

        XCTAssertEqual(PostingPresetStore(defaults: defaults).selected, .balanced,
                       "a fresh store defaults to balanced")

        let store = PostingPresetStore(defaults: defaults)
        store.selected = .classic
        store.save()
        XCTAssertEqual(PostingPreset.current(in: defaults), .classic)
        XCTAssertEqual(PostingPresetStore(defaults: defaults).selected, .classic,
                       "a new store reads back the persisted preset")
    }
}
