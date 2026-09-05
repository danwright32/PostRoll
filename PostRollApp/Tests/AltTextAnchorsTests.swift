import XCTest

/// #1035: the alt texts generated before anything recorded which photo they
/// describe.
///
/// #1008 added the anchors and `altText(for:at:)` resolves by path when they
/// are there. Everything saved before that falls back to matching by POSITION,
/// which is the fragility #1008 removed: reordering a day's photos, or deleting
/// one from the middle, silently moves every alt text onto a different
/// photograph, and a mismatched alt text reads as plausible because alt text
/// from one shoot resembles its neighbours.
final class AltTextAnchorsTests: XCTestCase {

    private func photos(_ n: Int) -> [URL] {
        (0..<n).map { URL(fileURLWithPath: "/photos/p\($0).jpg") }
    }

    private func event(day: DayName, photos count: Int, alts: Int) -> Event {
        var event = Event(name: "Spring Gala", org: "Decoda", venue: "Merkin Hall",
                          date: Date(timeIntervalSince1970: 1_775_000_000),
                          shootType: .fullShow)
        var posting = PostingDay(day: day)
        posting.photoPaths = photos(count)
        event.days[day.rawValue] = posting
        var caption = DayCaption(caption: "c")
        caption.altTexts = (0..<alts).map { "alt \($0)" }
        var week = WeekGenerationResult()
        week[day] = caption
        event.weekResult = week
        return event
    }

    private func anchors(_ event: Event, _ day: DayName) -> [String] {
        event.weekResult?[day]?.altTextPhotoPaths ?? []
    }

    // MARK: - What can be recovered

    func testADayWhoseCountsStillAgreeIsAnchoredByPosition() {
        // One alt text per photograph is what the generator wrote, so a day
        // with as many photographs as descriptions has had nothing added or
        // removed and position is exactly what it was.
        let stamped = AltTextAnchors.backfill([event(day: .wednesday, photos: 3, alts: 3)])

        XCTAssertEqual(anchors(stamped[0], .wednesday),
                       ["/photos/p0.jpg", "/photos/p1.jpg", "/photos/p2.jpg"])
    }

    func testADayWhosePhotosHaveMovedIsLeftUnanchored() {
        // The positions are no longer the ones the alt texts were written
        // against, so stamping anchors from them writes a guess down as a fact
        // (L192). Unanchored is the honest answer, and the review screen says
        // so rather than presenting the order as known.
        let stamped = AltTextAnchors.backfill([event(day: .wednesday, photos: 5, alts: 3)])

        XCTAssertTrue(anchors(stamped[0], .wednesday).isEmpty)
    }

    func testAReelIsNeverAnchoredToAPhotograph() {
        // Its one alt text describes the whole video rather than one frame, so
        // matching counts here are a coincidence and an anchor would be a fact
        // nobody stated (#1069).
        let stamped = AltTextAnchors.backfill([event(day: .thursday, photos: 1, alts: 1)])

        XCTAssertTrue(anchors(stamped[0], .thursday).isEmpty)
    }

    func testADayWithNoAltTextIsNotAnchored() {
        let stamped = AltTextAnchors.backfill([event(day: .wednesday, photos: 3, alts: 0)])

        XCTAssertTrue(anchors(stamped[0], .wednesday).isEmpty)
    }

    /// A backfill, not a re-derivation. Re-deriving would overwrite the anchors
    /// Python wrote with ones inferred from wherever the photos sit now.
    func testADayThatAlreadyHasAnchorsIsUntouched() {
        var one = event(day: .wednesday, photos: 3, alts: 3)
        var caption = one.weekResult![.wednesday]!
        caption.altTextPhotoPaths = ["/elsewhere/a.jpg", "/elsewhere/b.jpg",
                                     "/elsewhere/c.jpg"]
        one.weekResult![.wednesday] = caption

        let stamped = AltTextAnchors.backfill([one])

        XCTAssertEqual(anchors(stamped[0], .wednesday).first, "/elsewhere/a.jpg")
    }

    func testAnEventWithNoWeekResultIsReturnedAsItIs() {
        var bare = Event(name: "Nothing yet", org: "O", venue: "V",
                         date: Date(timeIntervalSince1970: 1_775_000_000),
                         shootType: .fullShow)
        bare.weekResult = nil

        XCTAssertEqual(AltTextAnchors.backfill([bare]).count, 1)
        XCTAssertNil(AltTextAnchors.backfill([bare])[0].weekResult)
    }

    // MARK: - What it is for

    func testAnAnchoredDayResolvesByPathAfterThePhotosAreReordered() {
        // The whole point, asserted through the reader rather than the field:
        // this is what the position fallback gets wrong.
        let stamped = AltTextAnchors.backfill([event(day: .wednesday, photos: 3, alts: 3)])
        let caption = stamped[0].weekResult![.wednesday]!

        XCTAssertEqual(caption.altText(for: URL(fileURLWithPath: "/photos/p2.jpg"),
                                       at: 0),
                       "alt 2",
                       "the anchor decides, not the position it was asked at")
    }
}
