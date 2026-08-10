import XCTest

/// #278: turning a day of the week into the candidate set and the first photo.
///
/// The ranking itself is covered by `CollaboratorPickTests`. This is the half
/// that reads the event: which accounts a given day actually tags, and who is
/// in the photo that appears in the feed.
///
/// The trap here is that getting the first photo wrong does not fail loudly. It
/// silently credits the wrong person, and the suggestion looks entirely
/// reasonable, so every path that cannot establish membership says so instead
/// of quietly ranking as though nobody were in it.
final class CollaboratorPickForDayTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_775_000_000)

    private func photo(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/postroll-test/\(name)")
    }

    private func stats(_ followers: Int, _ likes: Int, _ comments: Int) -> AccountStats {
        AccountStats(followers: followers, likes: likes, comments: comments, recordedOn: now)
    }

    private func lookup(_ handles: [String]) -> (String) -> AccountStats? {
        let table = Dictionary(uniqueKeysWithValues:
            handles.map { (AccountBook.key($0), stats(1_000, 50, 5)) })
        return { table[AccountBook.key($0)] }
    }

    /// A Wednesday carousel: six people across four photos, two of them in the
    /// first photo.
    private func carouselEvent() -> Event {
        var event = Event(name: "Perpetual Light", org: "DCINY", venue: "Carnegie Hall",
                          date: now, shootType: .fullShow)
        var wed = PostingDay(day: .wednesday)
        let photos = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"].map(photo)
        wed.photoPaths = photos
        wed.photoTags = [
            photos[0].absoluteString: ["first1", "first2"],
            photos[1].absoluteString: ["other1", "other2"],
            photos[2].absoluteString: ["other3"],
            photos[3].absoluteString: ["other4"],
        ]
        event.days = [DayName.wednesday.rawValue: wed]
        var result = WeekGenerationResult()
        result.wednesday = DayCaption()
        event.weekResult = result
        return event
    }

    private let everyone = ["first1", "first2", "other1", "other2", "other3", "other4"]

    // MARK: - Which accounts a day actually tags

    func testACarouselDayTagsThePeopleInItsPhotos() {
        XCTAssertEqual(
            CaptionBlocks.dayTagCandidates(event: carouselEvent(), day: .wednesday,
                                           preset: .balanced),
            everyone)
    }

    func testAReelDayCarriesTheWholeWeeksList() {
        // Dan, 2026-08-10: reel days still have tags, they are the tags from
        // the caption, so those are what rank. The reel has no per-photo data,
        // so no first-photo bias applies to it.
        var event = carouselEvent()
        var thu = PostingDay(day: .thursday)
        thu.tagHandles = ["@reelonly"]
        event.days[DayName.thursday.rawValue] = thu
        event.weekResult?.thursday = DayCaption()

        let candidates = CaptionBlocks.dayTagCandidates(event: event, day: .thursday,
                                                        preset: .balanced)
        XCTAssertEqual(candidates, CaptionBlocks.weekTagList(event: event))
        XCTAssertTrue(candidates.contains("reelonly"))
        XCTAssertTrue(candidates.contains("first1"), "everyone taggable that week")
    }

    func testADayThatTagsNobodyOnThePostHasNoCandidates() {
        // Under the classic preset Sunday is a single feed photo, which prints
        // no tag block at all, so there is nothing to suggest collaborators
        // from.
        var event = carouselEvent()
        var sun = PostingDay(day: .sunday)
        sun.photoPaths = [photo("s.jpg")]
        event.days[DayName.sunday.rawValue] = sun
        event.weekResult?.sunday = DayCaption()
        XCTAssertTrue(CaptionBlocks.dayTagCandidates(event: event, day: .sunday,
                                                     preset: .classic).isEmpty)
    }

    // MARK: - The first photo

    func testTheFirstPhotoIsTheFirstCarouselItemNotTheCollage() {
        // The collage is this day's STORY, not a carousel item: the carousel is
        // the assigned photos in order (`EventExporter` copies them as 01..N,
        // and generate_media documents "a 4 photo carousel whose collage
        // doubles as the story"). So the image that appears in the feed is
        // photoPaths[0], and its own tags are the membership.
        let membership = CollaboratorPick.firstPhotoHandles(
            event: carouselEvent(), day: .wednesday, preset: .balanced)
        XCTAssertEqual(membership.handles, ["first1", "first2"])
        XCTAssertTrue(membership.notes.isEmpty)
    }

    func testTheFirstPhotoBiasBeatsEngagementOnARealDay() {
        let result = CollaboratorPick.suggest(
            event: carouselEvent(), day: .wednesday, preset: .balanced,
            stats: lookup(everyone), asOf: now)
        XCTAssertEqual(result?.suggested.prefix(2).map(\.handle), ["first1", "first2"])
        XCTAssertEqual(result?.fallbacks.count, 3)
    }

    func testAReelDayAppliesNoFirstPhotoBias() {
        var event = carouselEvent()
        var thu = PostingDay(day: .thursday)
        thu.tagHandles = ["@reelonly"]
        event.days[DayName.thursday.rawValue] = thu
        event.weekResult?.thursday = DayCaption()

        let result = CollaboratorPick.suggest(event: event, day: .thursday, preset: .balanced,
                                              stats: lookup(everyone + ["reelonly"]), asOf: now)
        XCTAssertTrue(result?.fallbacks.isEmpty ?? false, "nothing fell through anything")
        XCTAssertNil(result?.strongestExcluded)
        XCTAssertTrue(result?.suggested.allSatisfy { !$0.inFirstPhoto } ?? false)
    }

    // MARK: - Identity by filename, not by position

    func testTagsRecordedAgainstAnOlderPathStillResolveByFilename() {
        // MediaReclaim copies an original into app storage and rewrites the
        // day's photoPaths. Tags keyed on the pre-move path would otherwise
        // silently stop describing the first photo, and the suggestion would
        // look entirely reasonable while crediting nobody.
        var event = carouselEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        let moved = URL(fileURLWithPath: "/tmp/postroll-test/photos/a.jpg")
        wed.photoPaths[0] = moved
        event.days[DayName.wednesday.rawValue] = wed

        let membership = CollaboratorPick.firstPhotoHandles(event: event, day: .wednesday,
                                                            preset: .balanced)
        XCTAssertEqual(membership.handles, ["first1", "first2"])
    }

    func testTagDataThatDescribesADifferentPhotoSetIsRefusedAndSaidOutLoud() {
        // Not read anyway: a stale key set means the app cannot tell who is in
        // the first photo, and guessing credits the wrong person.
        var event = carouselEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        wed.photoPaths = ["x.jpg", "y.jpg", "z.jpg", "w.jpg"].map(photo)
        event.days[DayName.wednesday.rawValue] = wed

        let membership = CollaboratorPick.firstPhotoHandles(event: event, day: .wednesday,
                                                            preset: .balanced)
        XCTAssertNil(membership.handles, "guessed rather than refused")
        XCTAssertEqual(membership.notes, [CollaboratorPick.firstPhotoUnresolvedNote])
    }

    func testARefusedFirstPhotoRanksOnEngagementAndCarriesTheNote() {
        // Only the first photo was swapped out, so the other three still tag
        // six people between them and there is a real suggestion to make. The
        // first photo's own people may be sitting in the orphaned tags, so the
        // bias is refused rather than applied to an empty set.
        var event = carouselEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        wed.photoTags[wed.photoPaths[1].absoluteString] = ["other1", "other2", "other5"]
        wed.photoTags[wed.photoPaths[2].absoluteString] = ["other3", "other6"]
        wed.photoPaths[0] = photo("replaced.jpg")
        event.days[DayName.wednesday.rawValue] = wed

        XCTAssertEqual(CaptionBlocks.dayTagCandidates(event: event, day: .wednesday,
                                                      preset: .balanced).count, 6)
        let result = CollaboratorPick.suggest(
            event: event, day: .wednesday, preset: .balanced,
            stats: lookup(["other1", "other2", "other3", "other4", "other5", "other6"]),
            asOf: now)
        XCTAssertEqual(result?.notes, [CollaboratorPick.firstPhotoUnresolvedNote])
        XCTAssertTrue(result?.suggested.allSatisfy { !$0.inFirstPhoto } ?? false)
        XCTAssertTrue(result?.fallbacks.isEmpty ?? false,
                      "nothing fell through a rule that was not applied")
    }

    func testAFirstPhotoWithNobodyTaggedIsAnAnswerNotAFailure() {
        // Different from being unable to tell: here the app knows the first
        // photo tags nobody, so everyone is honestly a fallback.
        var event = carouselEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        wed.photoTags[wed.photoPaths[0].absoluteString] = []
        event.days[DayName.wednesday.rawValue] = wed

        let membership = CollaboratorPick.firstPhotoHandles(event: event, day: .wednesday,
                                                            preset: .balanced)
        XCTAssertEqual(membership.handles, [])
        XCTAssertTrue(membership.notes.isEmpty)
    }

    func testADayWithNoPhotosAtAllHasNoFirstPhotoAndSaysNothingMisleading() {
        var event = carouselEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        wed.photoPaths = []
        event.days[DayName.wednesday.rawValue] = wed

        let membership = CollaboratorPick.firstPhotoHandles(event: event, day: .wednesday,
                                                            preset: .balanced)
        XCTAssertNil(membership.handles)
        XCTAssertTrue(membership.notes.isEmpty, "no photos is not a resolution failure")
    }

    // MARK: - The threshold, on a real day

    func testFiveTaggedPeopleOnADayProduceNoSuggestion() {
        var event = carouselEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        wed.photoTags[wed.photoPaths[3].absoluteString] = []
        event.days[DayName.wednesday.rawValue] = wed

        XCTAssertEqual(CaptionBlocks.dayTagCandidates(event: event, day: .wednesday,
                                                      preset: .balanced).count, 5)
        XCTAssertNil(CollaboratorPick.suggest(event: event, day: .wednesday, preset: .balanced,
                                              stats: lookup(everyone), asOf: now))
    }

    // MARK: - One shared predicate with the export

    func testTheCandidatesAreExactlyWhatTheDaysCaptionBlockTags() {
        // A count and the rows it promises come from one predicate. If these
        // ever diverge, the panel would rank people the post does not tag, or
        // miss people it does.
        let event = carouselEvent()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("collab-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let candidates = CaptionBlocks.dayTagCandidates(event: event, day: .wednesday,
                                                        preset: .balanced)
        let captions = try? String(
            contentsOf: EventExporter.export(event: event, to: folder, preset: .balanced)
                .folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)
        for handle in candidates {
            XCTAssertTrue(captions?.contains(handle) ?? false,
                          "\(handle) is ranked but the post does not tag them")
        }
    }
}
