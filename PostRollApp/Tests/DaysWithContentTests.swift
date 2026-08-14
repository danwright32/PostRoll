import XCTest

/// #458: which days a week has, answered in one place.
///
/// There were three answers. Two byte-identical hand copies, in the review
/// screen and the export screen, each carrying the Friday exception; and a
/// third on the model, without it, that nothing called. The two screens agreed
/// by convention only, the next change to what counts as content had to find
/// both copies, and the one wearing the shared name was the wrong one (L16).
final class DaysWithContentTests: XCTestCase {

    private func event(friday: PostingDay? = nil) -> Event {
        var event = Event(name: "Vocal Colors", org: "DCINY", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        if let friday { event.days[DayName.friday.rawValue] = friday }
        return event
    }

    private func week(_ days: [DayName]) -> WeekGenerationResult {
        var result = WeekGenerationResult()
        for day in days {
            result[day] = DayCaption(caption: "A caption for \(day.rawValue).")
        }
        return result
    }

    func testADayWithACaptionCounts() {
        XCTAssertEqual(week([.sunday]).daysWithContent(in: event()), [.sunday])
    }

    func testAWeekWithNothingHasNoDays() {
        XCTAssertEqual(week([]).daysWithContent(in: event()), [])
    }

    func testTheDaysComeBackInWeekOrder() {
        // The screens render this list directly, so the order is what Dan
        // reads down.
        XCTAssertEqual(week([.friday, .sunday, .wednesday]).daysWithContent(in: event()),
                       [.sunday, .wednesday, .friday])
    }

    // MARK: - The Friday exception, which is the whole reason this is shared

    /// Friday's before-and-after reel is built from photos on the day rather
    /// than from a caption, so a Friday carrying photos has content even with
    /// no caption written for it.
    func testAFridayWithARawPhotoCountsWithNoCaption() {
        var friday = PostingDay(day: .friday)
        friday.rawPhotoPath = URL(fileURLWithPath: "/tmp/raw.jpg")

        XCTAssertEqual(week([]).daysWithContent(in: event(friday: friday)), [.friday])
    }

    func testAFridayWithAnEditedPhotoCounts() {
        var friday = PostingDay(day: .friday)
        friday.editedPhotoPath = URL(fileURLWithPath: "/tmp/edited.jpg")

        XCTAssertEqual(week([]).daysWithContent(in: event(friday: friday)), [.friday])
    }

    func testAFridayWithDayPhotosCounts() {
        var friday = PostingDay(day: .friday)
        friday.photoPaths = [URL(fileURLWithPath: "/tmp/a.jpg")]

        XCTAssertEqual(week([]).daysWithContent(in: event(friday: friday)), [.friday])
    }

    func testAFridayWithNoPhotosAndNoCaptionDoesNotCount() {
        XCTAssertEqual(week([]).daysWithContent(in: event(friday: PostingDay(day: .friday))), [])
    }

    /// The exception is Friday's alone. Another day carrying photos but no
    /// caption has nothing to post yet.
    func testAnotherDayWithPhotosAndNoCaptionDoesNotCount() {
        var event = self.event()
        var sunday = PostingDay(day: .sunday)
        sunday.photoPaths = [URL(fileURLWithPath: "/tmp/a.jpg")]
        event.days[DayName.sunday.rawValue] = sunday

        XCTAssertEqual(week([]).daysWithContent(in: event), [])
    }

    func testAFridayWithBothACaptionAndPhotosIsListedOnce() {
        var friday = PostingDay(day: .friday)
        friday.photoPaths = [URL(fileURLWithPath: "/tmp/a.jpg")]

        XCTAssertEqual(week([.friday]).daysWithContent(in: event(friday: friday)), [.friday])
    }
}
