import XCTest

/// #1025: changing the default layout says which events it would rebuild.
///
/// An event with no override follows the Settings default, so it changed layout
/// the moment that default moved, and nothing computed what changed, warned, or
/// rebuilt anything. Those events carried images and captions built for the
/// previous layout with nothing saying so, while the per event control has
/// confirmed and named what it replaces since #1007. Two controls writing one
/// effective value, with entirely different consequences.
final class SettingsLayoutSwitchTests: XCTestCase {

    private func event(_ name: String, _ counts: [DayName: Int],
                       override: PostingPreset? = nil) -> Event {
        var event = Event(name: name, org: "Decoda", venue: "Merkin Hall",
                          date: Date(timeIntervalSince1970: 1_775_000_000),
                          shootType: .fullShow)
        event.postingPresetOverride = override
        for (day, n) in counts {
            var posting = PostingDay(day: day)
            posting.photoPaths = (0..<n).map {
                URL(fileURLWithPath: "/\(name)-\(day.rawValue)-\($0).jpg")
            }
            event.days[day.rawValue] = posting
        }
        return event
    }

    // MARK: - Who it touches

    func testAnEventWithItsOwnLayoutIsNotTouchedByTheDefault() {
        let impact = SettingsLayoutSwitch.impact(
            from: .balanced, to: .opening,
            events: [event("Follows", [.sunday: 8]),
                     event("Its own", [.sunday: 8], override: .balanced)])

        XCTAssertEqual(impact.affected.map(\.name), ["Follows"])
        XCTAssertEqual(impact.overridden, ["Its own"])
    }

    /// The count has to add up. A report naming three events out of twelve
    /// leaves the reader working out what happened to the other nine (L287).
    func testAnEventNothingChangesIsNamedAsUnaffectedRatherThanOmitted() {
        // Balanced to Opening moves Sunday from 4 photos to 7 and leaves
        // Monday alone, so an event with only a Monday changes nothing.
        let impact = SettingsLayoutSwitch.impact(
            from: .balanced, to: .opening,
            events: [event("Sunday only", [.sunday: 8]),
                     event("Monday only", [.monday: 8])])

        XCTAssertEqual(impact.affected.map(\.name), ["Sunday only"])
        XCTAssertEqual(impact.unaffected, ["Monday only"])
    }

    func testAnEventWithNoPhotosChangesNothing() {
        let impact = SettingsLayoutSwitch.impact(
            from: .balanced, to: .classic, events: [event("Empty", [:])])

        XCTAssertTrue(impact.affected.isEmpty)
        XCTAssertEqual(impact.unaffected, ["Empty"])
    }

    func testTheWorkCarriedIsTheSameDecisionThePerEventControlMakes() {
        let one = event("Spring Gala", [.sunday: 8, .monday: 8, .wednesday: 8])
        let impact = SettingsLayoutSwitch.impact(from: .balanced, to: .classic,
                                                 events: [one])

        XCTAssertEqual(impact.affected.first?.work,
                       PostingLayoutSwitch.work(
                        PostingLayoutSwitch.plan(from: .balanced, to: .classic,
                                                 in: one)))
    }

    // MARK: - What it says before applying

    func testASwitchThatChangesNoEventAsksNothing() {
        // A dialog that appears with nothing to say teaches him to dismiss the
        // one that matters.
        let impact = SettingsLayoutSwitch.impact(
            from: .balanced, to: .opening, events: [event("Monday only", [.monday: 8])])

        XCTAssertNil(SettingsLayoutSwitch.confirmation(impact))
    }

    func testARedrawIsDescribedAsCostingNoCaption() {
        let impact = SettingsLayoutSwitch.impact(
            from: .balanced, to: .opening, events: [event("Spring Gala", [.sunday: 8])])

        let said = try? XCTUnwrap(SettingsLayoutSwitch.confirmation(impact))
        XCTAssertEqual(said?.contains("redraws images on Spring Gala"), true, said ?? "nil")
        XCTAssertEqual(said?.contains("caption you have edited"), false,
                       "a redraw keeps its caption, so the warning about losing "
                       + "one does not belong on it")
    }

    func testARebuildSaysTheEditedCaptionsGo() {
        let impact = SettingsLayoutSwitch.impact(
            from: .balanced, to: .classic, events: [event("Spring Gala", [.sunday: 8])])

        let said = SettingsLayoutSwitch.confirmation(impact)
        XCTAssertEqual(said?.contains("rebuilds captions and images"), true, said ?? "nil")
        XCTAssertEqual(said?.contains("replaced"), true, said ?? "nil")
    }

    func testTheSentenceAccountsForTheEventsItIsNotTouching() {
        let impact = SettingsLayoutSwitch.impact(
            from: .balanced, to: .opening,
            events: [event("Spring Gala", [.sunday: 8]),
                     event("Monday only", [.monday: 8]),
                     event("Its own", [.sunday: 8], override: .classic)])

        let said = SettingsLayoutSwitch.confirmation(impact)
        XCTAssertEqual(said?.contains("1 event changes nothing"), true, said ?? "nil")
        XCTAssertEqual(said?.contains("1 event has its own layout"), true, said ?? "nil")
    }

    func testASwitchWithNothingLeftOverSaysSoRatherThanTrailingOff() {
        let impact = SettingsLayoutSwitch.impact(
            from: .balanced, to: .opening, events: [event("Spring Gala", [.sunday: 8])])

        XCTAssertEqual(SettingsLayoutSwitch.confirmation(impact)?
                        .contains("Every event that follows the default is listed"),
                       true)
    }
}
