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

    // MARK: - Promoting a stronger photo to the front (#983)
    //
    // On a collage carousel only the FIRST photo appears in the feed, and the
    // ranking treats that order as fixed: it biases hard toward whoever is in
    // the visible image, because somebody who is not in it usually declines and
    // a declined invite wastes one of five slots. What nothing ever questioned
    // is the order itself. If the strongest accounts are tagged in photo 3, the
    // app ranks around that fact rather than pointing out that photo 3 could be
    // first.

    /// A carousel whose strength sits in photo 3 rather than photo 1.
    private func lopsidedEvent() -> Event {
        var event = carouselEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        let photos = wed.photoPaths
        wed.photoTags = [
            photos[0].absoluteString: ["weakone"],
            photos[1].absoluteString: ["middling"],
            photos[2].absoluteString: ["strongest", "alsostrong"],
            photos[3].absoluteString: ["another"],
        ]
        event.days[DayName.wednesday.rawValue] = wed
        return event
    }

    private func lopsidedStats() -> (String) -> AccountStats? {
        let table = [
            "weakone":    stats(500, 10, 1),
            "middling":   stats(4_120, 120, 20),
            "strongest":  stats(12_400, 500, 90),
            "alsostrong": stats(9_000, 300, 50),
            "another":    stats(600, 12, 2),
        ]
        return { table[AccountBook.key($0)] }
    }

    private func promotion(_ event: Event,
                           _ stats: @escaping (String) -> AccountStats?,
                           day: DayName = .wednesday,
                           preset: PostingPreset = .balanced)
        -> CollaboratorPick.PhotoPromotion? {
        CollaboratorPick.photoToPromote(event: event, day: day, preset: preset,
                                        stats: stats, asOf: now)
    }

    func testAStrongerAccountInALaterPhotoIsWorthMovingToTheFront() {
        let found = promotion(lopsidedEvent(), lopsidedStats())

        XCTAssertEqual(found?.index, 2, "the wrong photo was named, or none was")
        XCTAssertEqual(found?.best.handle, "strongest")
        XCTAssertEqual(found?.current?.handle, "weakone",
                       "the sentence cannot say what the first photo offers today")
    }

    func testAFirstPhotoThatAlreadyLeadsIsLeftAlone() {
        // Fires on any improvement at all, so the only quiet case is a first
        // photo that is genuinely best. Anything looser and the suggestion
        // appears on posts where there is nothing to gain, and a notice that
        // fires on most posts stops being read (L36).
        var event = lopsidedEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        let photos = wed.photoPaths
        wed.photoTags = [
            photos[0].absoluteString: ["strongest"],
            photos[1].absoluteString: ["middling"],
            photos[2].absoluteString: ["weakone"],
        ]
        event.days[DayName.wednesday.rawValue] = wed

        XCTAssertNil(promotion(event, lopsidedStats()))
    }

    func testThePhotoNamedIsTheBestOfThemAllNotTheFirstThatBeatsTheLead() {
        // Photo 2 beats photo 1, and photo 3 beats photo 2. Naming photo 2
        // would spend the one suggestion on the smaller of two improvements.
        var event = lopsidedEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        let photos = wed.photoPaths
        wed.photoTags = [
            photos[0].absoluteString: ["weakone"],
            photos[1].absoluteString: ["alsostrong"],
            photos[2].absoluteString: ["strongest"],
        ]
        event.days[DayName.wednesday.rawValue] = wed

        XCTAssertEqual(promotion(event, lopsidedStats())?.index, 2)
    }

    func testAReelDayIsNeverAskedToReorder() {
        // A reel has no first photo distinction, so there is no lead to
        // improve and nothing to say.
        XCTAssertNil(promotion(lopsidedEvent(), lopsidedStats(), day: .thursday))
    }

    func testADayWhoseAccountsCannotBeRankedSaysNothing() {
        // Not an empty suggestion. With no figures anywhere there is no basis
        // for claiming one photo leads better than another, and inventing one
        // would put a reorder in front of Dan on no evidence.
        XCTAssertNil(promotion(lopsidedEvent(), { _ in nil }))
    }

    func testAFirstPhotoTaggingOnlyAPrivateAccountIsBeatenByAPublicOne() {
        // The case this came from. The lead photo credits an account whose
        // invite reaches only its own approved followers, while a later photo
        // carries a public one, and the two rules compose without either
        // knowing about the other (#982).
        var marked = stats(50_000, 5_000, 1_000)
        marked.isPrivate = true
        let table = ["weakone": marked, "middling": stats(4_120, 120, 20)]
        var event = lopsidedEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        let photos = wed.photoPaths
        wed.photoTags = [photos[0].absoluteString: ["weakone"],
                         photos[1].absoluteString: ["middling"]]
        event.days[DayName.wednesday.rawValue] = wed

        let found = promotion(event, { table[AccountBook.key($0)] })

        XCTAssertEqual(found?.index, 1)
        XCTAssertEqual(found?.best.handle, "middling")
    }

    func testTheControlSaysWhatTheReorderCosts() {
        // Derived from the day's own state, never printed on every post. A
        // warning shown whatever the situation carries no information, and
        // reads identically whether it is throwing away nothing or throwing
        // away every crop Dan set by hand (L180).
        let plain = CollaboratorPick.promotionCostLine(dropsLayout: false)
        let costly = CollaboratorPick.promotionCostLine(dropsLayout: true)

        XCTAssertNotEqual(plain, costly,
                          "the control says the same thing whether or not there "
                          + "is anything to lose")
        XCTAssertFalse(plain.lowercased().contains("crop"),
                       "a day with no crops is warned about losing them: \(plain)")
        XCTAssertTrue(costly.lowercased().contains("crop"),
                      "the crops are dropped and the control does not say so: \(costly)")
    }

    func testTheNameOfThePhotoCountsFromOne() {
        // The index is zero based and the sentence is not. Named once, here,
        // rather than each surface adding one and one of them forgetting.
        let found = promotion(lopsidedEvent(), lopsidedStats())

        XCTAssertEqual(found?.index, 2)
        XCTAssertEqual(CollaboratorPick.promotionControlLabel(for: found!), "Make photo 3 first")
    }

    // MARK: - The control exists on the screen

    private func source(_ path: String) throws -> String {
        SwiftSourceText.withoutComments(
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/\(path)"), encoding: .utf8))
    }

    func testThePanelOffersTheReorderRatherThanOnlyDescribingIt() throws {
        // A suggestion Dan cannot act on where he reads it is work handed back
        // to him, and it would sit there every week saying the same thing
        // (L272). The reorder is one press.
        let code = try source("Views/CollaboratorPanel.swift")

        XCTAssertTrue(code.contains("CollaboratorPick.promotionControlLabel"),
                      "the panel names the control itself, so the sentence and "
                      + "the button can come to disagree about which photo")
        XCTAssertTrue(code.contains("CollaboratorPick.promotionReason"),
                      "the panel says why in its own words")
        XCTAssertTrue(code.contains("CollaboratorPick.promotionCostLine"),
                      "the panel does not say what pressing it costs, or says it "
                      + "in wording of its own")
    }

    func testTheScreenTellsThePanelWhetherThereIsAnythingToLose() throws {
        // The cost line is only honest if the flag behind it is read off the
        // day. Passed as a constant it becomes the boilerplate warning it
        // exists not to be.
        let code = try source("Views/CaptionReviewView.swift")

        XCTAssertTrue(code.contains("collageCellOverride") && code.contains("collageCropOffsets"),
                      "nothing on this screen reads the state the warning claims")
        XCTAssertTrue(code.contains("CollaboratorPick.photoToPromote"),
                      "the screen never asks whether a stronger photo exists")
    }

    func testPromotingAPhotoClearsTheLayoutItInvalidates() throws {
        // The collage is filled positionally and its row heights come from the
        // photo aspect ratios in order, so a per-cell layout and the crops
        // keyed to it cannot survive a reorder. Left behind they are applied to
        // the wrong pictures.
        let code = try source("Views/CaptionReviewView.swift")
        let handler = try XCTUnwrap(
            code.range(of: "func promotePhoto").map { start in
                let rest = code[start.upperBound...]
                return String(rest[..<(rest.range(of: "\n    }")?.upperBound ?? rest.endIndex)])
            }, "the screen has no promote action at all")

        XCTAssertTrue(handler.contains("collageCellOverride = nil"),
                      "the cell layout survives a reorder it was keyed to")
        XCTAssertTrue(handler.contains("collageCropOffsets"),
                      "the crops survive a reorder they were keyed to")
        XCTAssertFalse(handler.contains("regenerate"),
                       "the reorder triggers a regen of its own rather than "
                       + "batching with the other edits until Apply changes")
    }

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
        XCTAssertEqual(result.suggested.prefix(2).map(\.handle), ["first1", "first2"])
        XCTAssertEqual(result.fallbacks.count, 3)
    }

    func testAReelDayAppliesNoFirstPhotoBias() {
        var event = carouselEvent()
        var thu = PostingDay(day: .thursday)
        thu.tagHandles = ["@reelonly"]
        event.days[DayName.thursday.rawValue] = thu
        event.weekResult?.thursday = DayCaption()

        let result = CollaboratorPick.suggest(event: event, day: .thursday, preset: .balanced,
                                              stats: lookup(everyone + ["reelonly"]), asOf: now)
        XCTAssertTrue(result.fallbacks.isEmpty, "nothing fell through anything")
        XCTAssertNil(result.strongestExcluded)
        XCTAssertTrue(result.suggested.allSatisfy { !$0.inFirstPhoto })
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
        XCTAssertEqual(result.notes, [CollaboratorPick.firstPhotoUnresolvedNote])
        XCTAssertTrue(result.suggested.allSatisfy { !$0.inFirstPhoto })
        XCTAssertTrue(result.fallbacks.isEmpty,
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

    // MARK: - Which answer a real day gets (#964)

    func testFiveTaggedPeopleOnADayAreAllInvitedRatherThanRanked() {
        // The case this was found on. Five people fit the five slots, so the
        // answer is "invite all of them", and the app used to say nothing at
        // all, which reads as a day that needed no invites.
        var event = carouselEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        wed.photoTags[wed.photoPaths[3].absoluteString] = []
        event.days[DayName.wednesday.rawValue] = wed

        XCTAssertEqual(CaptionBlocks.dayTagCandidates(event: event, day: .wednesday,
                                                      preset: .balanced).count, 5)
        let result = CollaboratorPick.suggest(event: event, day: .wednesday, preset: .balanced,
                                              stats: lookup(everyone), asOf: now)
        XCTAssertEqual(result.coverage, .allFit)
        XCTAssertEqual(result.suggested.count, 5)
    }

    func testADayWhoseTagsAreAllUnusableSaysNobodyIsTaggedRatherThanNothing() {
        // Friday today, and any day whose tags have not been filled in. The
        // silence this replaces is indistinguishable from a considered day.
        var event = carouselEvent()
        var wed = event.days[DayName.wednesday.rawValue]!
        wed.photoTags = [:]
        event.days[DayName.wednesday.rawValue] = wed

        let result = CollaboratorPick.suggest(event: event, day: .wednesday, preset: .balanced,
                                              stats: lookup(everyone), asOf: now)
        XCTAssertEqual(result.coverage, .nothingTagged)
        XCTAssertTrue(CollaboratorPick.captionBlock(result)
                        .contains(CollaboratorPick.nobodyTaggedLine))
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
