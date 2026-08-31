import XCTest

/// #999 and #1000: what a post SAYS has to be about the photographs in it.
///
/// A day can carry more photos than its preset posts. `generate_media` renders
/// `photos[:count]` and the export copies that same slice into `carousel/`,
/// but everything that DESCRIBES the post read the full assigned list:
///
/// * the exported ALT TEXT block listed one entry per assigned photo, so a
///   Sunday with seven photos under Balanced, which posts four, shipped seven
///   alt texts. Alt text is the entire content of the post for a screen reader
///   user, and three of those describe photographs that are not in it. It is
///   the one defect class nobody sighted catches in review, because every
///   sentence in it is well written and true of some photograph.
/// * the PHOTO TAGS block did the same, so the file told Dan to tag people who
///   are not in the carousel.
/// * the collaborator suggestion drew its candidates from every assigned
///   photo, so it could offer an invite to somebody the post does not show.
/// * `CollageCell.usable` compared a hand dragged layout, which has one cell
///   per POSTED photo, against every ASSIGNED photo. The counts never matched,
///   it returned nil, and the override was silently discarded: the editor
///   showed the arrangement Dan dragged and the export rendered a different one
///   (#1000).
///
/// `PostingPreset.postedPhotos` is the one answer all four now read.
final class PostedPhotoScopeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_775_000_000)

    /// Sunday under Balanced: seven assigned, four posted. The state in the
    /// screenshot that prompted #1000, and the example #999 is written on.
    private let assigned = 7
    private let posted = 4

    private func photo(_ n: Int) -> URL {
        URL(fileURLWithPath: "/tmp/postroll-scope/shot-\(n).jpg")
    }

    private func event() -> Event {
        var event = Event(name: "Perpetual Light", org: "DCINY", venue: "Carnegie Hall",
                          date: now, shootType: .fullShow)
        var sun = PostingDay(day: .sunday)
        sun.photoPaths = (1...assigned).map(photo)
        // One tag per photo, so which of them reach the file says exactly how
        // far the scope reaches.
        sun.photoTags = Dictionary(uniqueKeysWithValues:
            (1...assigned).map { (photo($0).absoluteString, ["tagged\($0)"]) })
        event.days = [DayName.sunday.rawValue: sun]

        var caption = DayCaption()
        caption.caption = "Sunday opener"
        caption.altTexts = (1...assigned).map { "alt text for photo \($0)" }
        caption.altTextPhotoPaths = (1...assigned).map { photo($0).path }
        var result = WeekGenerationResult()
        result.sunday = caption
        event.weekResult = result
        return event
    }

    private func exportedCaptions(_ event: Event) throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("posted-scope-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let exported = try EventExporter.export(event: event, to: folder, preset: .balanced,
                                                collaboratorStats: { _ in nil }, asOf: now)
        return try String(contentsOf: exported.folder.appendingPathComponent("CAPTIONS.txt"),
                          encoding: .utf8)
    }

    // MARK: - The slice itself

    func testTheSliceIsTheSmallerOfAssignedAndTheTarget() {
        let photos = (1...assigned).map(photo)
        XCTAssertEqual(PostingPreset.balanced.postedPhotos(photos, on: .sunday).count, posted)
        XCTAssertEqual(PostingPreset.balanced.postedPhotos(Array(photos.prefix(3)), on: .sunday).count, 3)
        XCTAssertEqual(PostingPreset.balanced.postedPhotos([], on: .sunday), [])
    }

    func testADayNoPresetGovernsPostsWhatItHas() {
        // nil from `effectiveCount` means "this day's own handling decides",
        // not zero. Four different fallbacks for it used to be written across
        // the app: 0, 10, and the assigned count twice.
        let photos = (1...assigned).map(photo)
        XCTAssertEqual(PostingPreset.balanced.postedPhotos(photos, on: .thursday), photos)
    }

    func testTheSliceKeepsTheFirstPhotosInOrder() {
        // Which photos, not just how many. The carousel's first item is the one
        // that appears in the feed, so taking the wrong end would change the
        // post rather than shorten it.
        let photos = (1...assigned).map(photo)
        XCTAssertEqual(PostingPreset.balanced.postedPhotos(photos, on: .sunday),
                       Array(photos.prefix(posted)))
    }

    // MARK: - The exported file

    func testTheAltTextBlockCarriesOneEntryPerPOSTEDPhoto() throws {
        let captions = try exportedCaptions(event())
        for n in 1...posted {
            XCTAssertTrue(captions.contains("alt text for photo \(n)"), "photo \(n) is in the post")
        }
        for n in (posted + 1)...assigned {
            XCTAssertFalse(captions.contains("alt text for photo \(n)"),
                           "photo \(n) is not in the post, so its alt text describes nothing "
                           + "a reader will see")
        }
    }

    func testThePhotoTagsBlockNamesOnlyThePeopleInThePost() throws {
        let captions = try exportedCaptions(event())
        for n in 1...posted { XCTAssertTrue(captions.contains("tagged\(n)")) }
        for n in (posted + 1)...assigned {
            XCTAssertFalse(captions.contains("tagged\(n)"),
                           "tagged\(n) is not in the carousel and cannot be tagged in it")
        }
    }

    // MARK: - The collaborator suggestion

    func testACollaboratorCandidateHasToBeInThePost() {
        let candidates = CaptionBlocks.dayTagCandidates(event: event(), day: .sunday,
                                                        preset: .balanced)
        XCTAssertEqual(candidates.count, posted)
        XCTAssertFalse(candidates.contains("tagged7"),
                       "an invite to someone the post does not show is a wasted slot")
    }

    // MARK: - The dragged layout survives (#1000)

    func testADraggedLayoutOnAnOverfilledDayReachesTheManifest() {
        // One cell per POSTED photo, which is what the editor produces. Checked
        // against all seven it never matched, and the override was dropped with
        // nothing saying so.
        var live = event()
        var sun = live.days[DayName.sunday.rawValue]!
        sun.collageCellOverride = (1...posted).map {
            CollageCell(photoPath: photo($0).path, x: 0, y: ($0 - 1) * 200, w: 1080, h: 190)
        }
        live.days[DayName.sunday.rawValue] = sun

        let manifest = PythonBridge.shared.buildMediaManifest(event: live)
        let days = manifest["days"] as? [String: [String: Any]]
        let sunday = days?[DayName.sunday.rawValue]
        XCTAssertNotNil(sunday?["cell_layout"],
                        "the arrangement Dan dragged was discarded, so the export renders "
                        + "a different collage from the one the editor showed")
        XCTAssertEqual((sunday?["cell_layout"] as? [[String: Any]])?.count, posted)
    }

    func testALayoutThatDoesNotDescribeThePostedPhotosIsStillRefused() {
        // The positive control for the case above. `usable` exists to drop a
        // layout left over from a different photo set, and widening what it is
        // compared against must not turn it into a rule that accepts anything
        // (L159).
        var live = event()
        var sun = live.days[DayName.sunday.rawValue]!
        sun.collageCellOverride = [
            CollageCell(photoPath: "/tmp/postroll-scope/not-in-this-day.jpg",
                        x: 0, y: 0, w: 1080, h: 190)
        ]
        live.days[DayName.sunday.rawValue] = sun

        let manifest = PythonBridge.shared.buildMediaManifest(event: live)
        let days = manifest["days"] as? [String: [String: Any]]
        XCTAssertNil(days?[DayName.sunday.rawValue]?["cell_layout"])
    }
}
