import XCTest

/// Changing a show's shoot type in Edit Details, while nothing depends on it.
///
/// #1448 kept shoot type out of Edit Details because it decides which templates
/// a show's posts use, so changing it after the week was built would leave the
/// posts made for the wrong type. Shoot type is only read when captions, the
/// blog and the graphics are made, so before any photos are assigned there is
/// nothing it could leave wrong. Dan, 2026-10-20: editable until photos are
/// assigned, then shown but fixed.
final class ShootTypeEditTests: XCTestCase {

    private func alaria() -> Event {
        Event(name: "Alaria Class Rehearsals", org: "Alaria Chamber Ensemble",
              venue: "Piano Piano", date: Date(timeIntervalSince1970: 1_789_000_000),
              shootType: .fullShow)
    }

    private func edit(_ ev: Event, to type: ShootType) -> Event {
        NewEventForm.edited(ev, name: ev.name, org: ev.org, venue: ev.venue,
                            venueContext: ev.venueContext,
                            orgOffGraphics: ev.orgOffGraphics, shootType: type)
    }

    // MARK: - When it is fixed

    func testAShowWithOnlyItsProgramCanChangeType() {
        var ev = alaria()
        ev.stage = .ocrDone
        ev.ocrReviewDone = true

        XCTAssertFalse(ev.shootTypeIsFixed)
    }

    func testAPhotoOnAnyDayFixesTheType() {
        var ev = alaria()
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [URL(fileURLWithPath: "/photos/a.jpg")]
        ev.days["wednesday"] = day

        XCTAssertTrue(ev.shootTypeIsFixed)
    }

    func testAStandaloneMediaSlotFixesTheType() {
        // A screen recording or raw photo is assigned without being in
        // photoPaths, and is as much a choice made for this type as a photo.
        var ev = alaria()
        var day = PostingDay(day: .tuesday)
        day.screenRecordingPath = URL(fileURLWithPath: "/clips/screen.mov")
        ev.days["tuesday"] = day

        XCTAssertTrue(ev.shootTypeIsFixed)
    }

    func testAnEmptyDayDoesNotFixTheType() {
        var ev = alaria()
        ev.days["sunday"] = PostingDay(day: .sunday)

        XCTAssertFalse(ev.shootTypeIsFixed)
    }

    func testBlogPhotosFixTheType() {
        var ev = alaria()
        ev.blogPhotoPaths = [URL(fileURLWithPath: "/photos/b.jpg")]

        XCTAssertTrue(ev.shootTypeIsFixed)
    }

    func testAnythingMadeFixesTheType() {
        var rendered = alaria()
        rendered.previewMediaPaths = ["sunday": ["story": "/s.png"]]
        var exported = alaria()
        exported.exportPath = URL(fileURLWithPath: "/tmp/socials/x")

        XCTAssertTrue(rendered.shootTypeIsFixed)
        XCTAssertTrue(exported.shootTypeIsFixed)
    }

    // MARK: - Saving

    func testAnEditChangesTheTypeWhileItIsFree() {
        let before = alaria()

        let after = edit(before, to: .rehearsal)

        XCTAssertEqual(after.shootType, .rehearsal)
        XCTAssertNil(NewEventForm.shootTypeRefusal(before: before, asked: .rehearsal))
        XCTAssertTrue(EventDetailsSave(before: before, after: after).changed)
        XCTAssertEqual(EventDetailsSave(before: before, after: after).refreshDays, [])
    }

    func testAFixedTypeIsRefusedAndKept() {
        // Photos assigned while the sheet was open: the save must say so rather
        // than quietly keep or quietly change the type.
        var before = alaria()
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [URL(fileURLWithPath: "/photos/a.jpg")]
        before.days["wednesday"] = day

        XCTAssertEqual(NewEventForm.shootTypeRefusal(before: before, asked: .rehearsal),
                       NewEventForm.shootTypeFixedReason)
        XCTAssertEqual(edit(before, to: .rehearsal).shootType, .fullShow)
    }

    func testAFixedTypeSavedUnchangedIsNotRefused() {
        var before = alaria()
        before.previewMediaPaths = ["sunday": ["story": "/s.png"]]

        XCTAssertNil(NewEventForm.shootTypeRefusal(before: before, asked: .fullShow))
    }
}
