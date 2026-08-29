import XCTest

/// Integration coverage for the export file-writing core (`EventExporter`),
/// which was relocated out of ExportView and into ExportManager during the
/// background-task refactor. Exercises the deterministic, no-Python parts: the
/// folder layout, CAPTIONS.txt, blog draft, Wednesday carousel copy, full-export
/// rebuild (orphan removal), and single-day scoping. Media/reels still come from
/// Python and aren't covered here.
final class EventExporterTests: XCTestCase {

    private var root: URL!
    private var assets: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("exporter-test-\(UUID().uuidString)")
        assets = root.appendingPathComponent("_assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeFile(_ name: String) -> URL {
        let url = assets.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("img".utf8))
        return url
    }

    private func caption(_ text: String, hashtags: [String] = [], alt: [String] = []) -> DayCaption {
        var c = DayCaption()
        c.caption = text
        c.hashtags = hashtags
        c.altTexts = alt
        return c
    }

    private func makeEvent(wednesdayPhotos: [URL]) -> Event {
        var event = Event(name: "Music From Inside", org: "Decoda",
                          venue: "Hall", date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        var wed = PostingDay(day: .wednesday)
        wed.photoPaths = wednesdayPhotos
        if wednesdayPhotos.count >= 2 {
            wed.photoTags = [wednesdayPhotos[1].absoluteString: ["Jane Cellist"]]
        }
        event.days = [DayName.wednesday.rawValue: wed]
        event.blogPhotoPaths = [makeFile("blog1.jpg")]

        var result = WeekGenerationResult()
        result.sunday = caption("Sunday opener", hashtags: ["#concert"], alt: ["wide shot of the stage"])
        result.wednesday = caption("Carousel day", alt: ["first frame", "second frame"])
        result.blog = BlogOutput(title: "Inside the Music", body: "A long blog body.")
        event.weekResult = result
        return event
    }

    // MARK: - Alt text stays with its own photo (#1008)

    /// Reordering a day's photos must not move the alt texts onto each other.
    ///
    /// `altTexts` is positional against `photoPaths`, and nothing permutes it
    /// when the photos move. `PhotoAssignmentView` offers a drag to reorder and
    /// `removingPhotos` re-keys every OTHER per-photo map (crops, tags, collage
    /// cells) while being unable to reach the alt texts at all, because they
    /// live on `Event.weekResult`. So position measures whatever later occupies
    /// it (L237), and the export labels each alt text with a filename that is
    /// not its subject.
    ///
    /// The failure is quiet in the worst way: alt texts from one shoot resemble
    /// each other, so a swapped pair reads as plausible.
    func testAltTextFollowsItsPhotoWhenTheDayIsReordered() throws {
        let first  = makeFile("shot-100.jpg")
        let second = makeFile("shot-277.jpg")
        var event = makeEvent(wednesdayPhotos: [first, second])

        // Written against the photos in their original order, and anchored to
        // them, which is what the caption run now reports.
        var wed = DayCaption()
        wed.caption = "Carousel day"
        wed.altTexts = ["a cellist alone on the apron", "the full ensemble in silhouette"]
        wed.altTextPhotoPaths = [first.path, second.path]
        event.weekResult?.wednesday = wed

        // Dan drags the second photo in front of the first.
        event.days[DayName.wednesday.rawValue]?.photoPaths = [second, first]

        let folder = try EventExporter.export(event: event, to: root).folder
        let captions = try String(
            contentsOf: folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)

        XCTAssertTrue(captions.contains("277: the full ensemble in silhouette"),
                      "shot-277 is now first and its own alt text has to come with it:\n\(captions)")
        XCTAssertTrue(captions.contains("100: a cellist alone on the apron"),
                      "shot-100 is now second and keeps its own alt text:\n\(captions)")
        XCTAssertFalse(captions.contains("277: a cellist alone on the apron"),
                       "the alt texts were paired by position, so each photo is "
                       + "described by the other one:\n\(captions)")
    }

    /// Data written before the anchors existed has none, and must keep working.
    ///
    /// Every event already on disk is in this state, so a reader that requires
    /// the anchor silently empties the alt text block for all of them. Falling
    /// back to position is exactly as correct as today for those, which is the
    /// most that can be recovered from a list that never recorded its subjects.
    func testAnAltTextListWithNoAnchorsStillExportsInOrder() throws {
        let first  = makeFile("shot-100.jpg")
        let second = makeFile("shot-277.jpg")
        var event = makeEvent(wednesdayPhotos: [first, second])

        var wed = DayCaption()
        wed.caption = "Carousel day"
        wed.altTexts = ["first frame", "second frame"]
        wed.altTextPhotoPaths = []   // an older save
        event.weekResult?.wednesday = wed

        let folder = try EventExporter.export(event: event, to: root).folder
        let captions = try String(
            contentsOf: folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)

        XCTAssertTrue(captions.contains("100: first frame"), captions)
        XCTAssertTrue(captions.contains("277: second frame"), captions)
    }

    // MARK: - Tests

    func testFullExportWritesExpectedLayout() throws {
        let p1 = makeFile("shot-100.jpg")
        let p2 = makeFile("shot-277.jpg")
        let event = makeEvent(wednesdayPhotos: [p1, p2])

        let folder = try EventExporter.export(event: event, to: root).folder
        let fm = FileManager.default

        XCTAssertEqual(folder.lastPathComponent,
                       "decoda_music_from_inside_\(event.isoDate)",
                       "folder name is slug(org)_slug(name)_isoDate")

        // Blog draft
        let blog = folder.appendingPathComponent("0. Blog/draft.md")
        XCTAssertTrue(fm.fileExists(atPath: blog.path))
        let blogText = try String(contentsOf: blog, encoding: .utf8)
        XCTAssertTrue(blogText.contains("# Inside the Music"))
        XCTAssertTrue(blogText.contains("A long blog body."))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("0. Blog/photo_01.jpg").path))

        // Wednesday carousel copied in order, zero-padded
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("4. Wednesday/carousel/01.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("4. Wednesday/carousel/02.jpg").path))

        // Sunday has a caption → its folder exists, but no carousel (not Wednesday)
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("1. Sunday").path))

        // Master CAPTIONS.txt content
        let captions = try String(contentsOf: folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)
        XCTAssertTrue(captions.contains("=== SUNDAY ==="))
        XCTAssertTrue(captions.contains("Sunday opener"))
        XCTAssertTrue(captions.contains("#concert"))
        XCTAssertTrue(captions.contains("=== WEDNESDAY ==="))
        // Per-photo alt text labelled by trailing filename number
        XCTAssertTrue(captions.contains("100: first frame"))
        XCTAssertTrue(captions.contains("277: second frame"))
        // Per-photo people tag on the second photo
        XCTAssertTrue(captions.contains("277: Jane Cellist"))
    }

    func testFullReexportRebuildsAndRemovesOrphans() throws {
        let p1 = makeFile("shot-100.jpg")
        let p2 = makeFile("shot-277.jpg")
        // Committed, both of them: an export is only a previous export once it
        // is in place, and comparing two uncommitted staging folders would pass
        // this test without either re-export rule being exercised (#442).
        let first = try EventExporter.export(event: makeEvent(wednesdayPhotos: [p1, p2]), to: root)
            .staging.commit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("4. Wednesday/carousel/02.jpg").path))

        // Re-export with Wednesday trimmed to one photo: the stale 02.jpg must
        // not survive (full export rebuilds the folder from scratch).
        let second = try EventExporter.export(event: makeEvent(wednesdayPhotos: [p1]), to: root)
            .staging.commit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("4. Wednesday/carousel/01.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("4. Wednesday/carousel/02.jpg").path),
                       "orphaned carousel photo from the previous export must be gone")
    }

    func testANewExportDoesNotTouchThePreviousOneUntilItIsFinished() throws {
        // The failure #442 is about: the previous export used to be deleted
        // before a single replacement file existed, so a text write that threw,
        // a Python step that died or a full disk left Dan with nothing to
        // upload. This is the state any of those leaves behind, and the last
        // complete export has to still be sitting in it.
        let p1 = makeFile("shot-100.jpg")
        let p2 = makeFile("shot-277.jpg")
        let complete = try EventExporter.export(event: makeEvent(wednesdayPhotos: [p1, p2]), to: root)
            .staging.commit()
        let captions = complete.appendingPathComponent("CAPTIONS.txt")
        let before = try String(contentsOf: captions, encoding: .utf8)
        XCTAssertFalse(before.isEmpty, "setup: the previous export must be real")

        // A second export, mid run: written, not yet committed.
        let inFlight = try EventExporter.export(event: makeEvent(wednesdayPhotos: [p1]), to: root)

        XCTAssertEqual(try String(contentsOf: captions, encoding: .utf8), before,
                       "the previous export was overwritten before the new one finished")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: complete.appendingPathComponent("4. Wednesday/carousel/02.jpg").path),
            "the previous export was already being taken apart")

        // And a run that never commits leaves nothing behind in Dan's folder.
        inFlight.staging.abandon()
        let stray = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".postroll-export-") }
        XCTAssertTrue(stray.isEmpty, "a staging folder nobody committed was left behind: \(stray)")
    }

    func testSingleDayExportLeavesMasterFilesUntouched() throws {
        let event = makeEvent(wednesdayPhotos: [makeFile("shot-100.jpg")])
        let folder = try EventExporter.export(event: event, to: root).staging.commit()

        let captionsURL = folder.appendingPathComponent("CAPTIONS.txt")
        let before = try String(contentsOf: captionsURL, encoding: .utf8)

        // Scoped re-export of just Sunday must not rewrite CAPTIONS.txt or the blog.
        try EventExporter.export(event: event, to: root, days: [.sunday]).staging.commit()
        let after = try String(contentsOf: captionsURL, encoding: .utf8)
        XCTAssertEqual(before, after, "single-day export must leave the master CAPTIONS.txt as-is")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("0. Blog/draft.md").path))
    }

    // MARK: - Posting preset

    /// Build an event whose Sunday carries four assigned photos plus a caption
    /// with one alt text per photo (what a carousel day produces).
    private func makeSundayCarouselEvent() -> (Event, [URL]) {
        let photos = [makeFile("sun-11.jpg"), makeFile("sun-22.jpg"),
                      makeFile("sun-33.jpg"), makeFile("sun-44.jpg")]
        var event = Event(name: "Music From Inside", org: "Decoda",
                          venue: "Hall", date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        var sun = PostingDay(day: .sunday)
        sun.photoPaths = photos
        event.days = [DayName.sunday.rawValue: sun]

        var result = WeekGenerationResult()
        result.sunday = caption("Sunday carousel", hashtags: ["#concert"],
                                alt: ["frame a", "frame b", "frame c", "frame d"])
        event.weekResult = result
        return (event, photos)
    }

    func testBalancedPresetExportsSundayAsCarouselWithNumberedAltText() throws {
        let (event, _) = makeSundayCarouselEvent()
        let folder = try EventExporter.export(event: event, to: root, preset: .balanced).folder
        let fm = FileManager.default

        // Sunday gets a carousel/ of its four assigned photos, zero-padded.
        for i in 1...4 {
            XCTAssertTrue(
                fm.fileExists(atPath: folder.appendingPathComponent("1. Sunday/carousel/0\(i).jpg").path),
                "balanced Sunday should copy carousel photo 0\(i)")
        }

        // Alt texts are numbered per photo (by trailing filename number).
        let captions = try String(contentsOf: folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)
        XCTAssertTrue(captions.contains("11: frame a"))
        XCTAssertTrue(captions.contains("44: frame d"))
    }

    /// #281: the handles Instagram will not accept are named in the file.
    ///
    /// The cap and the dropped list are unit tested on both sides. This is the
    /// half that matters to Dan: that the block actually reaches CAPTIONS.txt,
    /// which is the file he pastes from. Built is not wired, and the two
    /// defects this closes (#221, #222) were both a correct rule that never
    /// made it into the deliverable.
    func testCaptionsNamesTheTagsThatDidNotFit() throws {
        var event = Event(name: "Music From Inside", org: "Decoda",
                          venue: "Hall", date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        // More taggable accounts than one post can carry.
        let overflow = CaptionBlocks.maxTagsPerPost + 3
        var sunday = PostingDay(day: .sunday)
        sunday.tagHandles = (0..<overflow).map { String(format: "handle%03d", $0) }
        event.days = [DayName.sunday.rawValue: sunday,
                      DayName.thursday.rawValue: PostingDay(day: .thursday)]

        var result = WeekGenerationResult()
        result.sunday = caption("Sunday opener")
        // The tag list rides on the reel days, so Thursday is the block to read.
        result.thursday = caption("Thursday reel")
        event.weekResult = result

        let folder = try EventExporter.export(event: event, to: root, preset: .classic).folder
        let captions = try String(contentsOf: folder.appendingPathComponent("CAPTIONS.txt"),
                                  encoding: .utf8)

        XCTAssertTrue(captions.contains(CaptionBlocks.tagsDroppedHeader), captions)
        // The three past the limit are named, and the ones that fit are not in
        // the dropped block.
        // Just this section, not everything to the end of the file: the day's
        // block carries further sections after it (the collaborator suggestion,
        // #278), and a slice that ran to the end would read their names as
        // dropped handles.
        let dropped = captions.components(separatedBy: CaptionBlocks.tagsDroppedHeader)[1]
            .components(separatedBy: "\n\n")[0]
        for index in CaptionBlocks.maxTagsPerPost..<overflow {
            XCTAssertTrue(dropped.contains(String(format: "handle%03d", index)),
                          "handle \(index) fell off and was not named")
        }
        XCTAssertFalse(dropped.contains("handle000"),
                       "a handle that fits must not be reported as dropped")
    }

    func testCaptionsSaysNothingAboutDroppedTagsWhenTheyAllFit() throws {
        // A heading on every export is how a real one stops being read.
        var event = Event(name: "Music From Inside", org: "Decoda",
                          venue: "Hall", date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        var sunday = PostingDay(day: .sunday)
        sunday.tagHandles = ["decoda", "thehall"]
        event.days = [DayName.sunday.rawValue: sunday,
                      DayName.thursday.rawValue: PostingDay(day: .thursday)]
        var result = WeekGenerationResult()
        result.sunday = caption("Sunday opener")
        result.thursday = caption("Thursday reel")
        event.weekResult = result

        let folder = try EventExporter.export(event: event, to: root, preset: .classic).folder
        let captions = try String(contentsOf: folder.appendingPathComponent("CAPTIONS.txt"),
                                  encoding: .utf8)

        XCTAssertTrue(captions.contains("TAG LIST:"), captions)
        XCTAssertFalse(captions.contains(CaptionBlocks.tagsDroppedHeader), captions)
    }

    func testBalancedSundayCarouselEmitsPerPhotoTags() throws {
        let photos = [makeFile("sun-11.jpg"), makeFile("sun-22.jpg"),
                      makeFile("sun-33.jpg"), makeFile("sun-44.jpg")]
        var event = Event(name: "Music From Inside", org: "Decoda",
                          venue: "Hall", date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        var sun = PostingDay(day: .sunday)
        sun.photoPaths = photos
        // Tag people on the second and fourth photos only.
        sun.photoTags = [
            photos[1].absoluteString: ["Mike Bono", "@mikebonomusic"],
            photos[3].absoluteString: ["Catherine Gregory"],
        ]
        event.days = [DayName.sunday.rawValue: sun]
        var result = WeekGenerationResult()
        result.sunday = caption("Sunday carousel", alt: ["a", "b", "c", "d"])
        event.weekResult = result

        let folder = try EventExporter.export(event: event, to: root, preset: .balanced).folder
        let captions = try String(contentsOf: folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)
        XCTAssertTrue(captions.contains("PHOTO TAGS:"))
        // Bare usernames, no @ (#221): Instagram's tag field takes a username.
        // A plain name that is not a handle is left as written.
        XCTAssertTrue(captions.contains("22: Mike Bono, mikebonomusic"), captions)
        XCTAssertFalse(captions.contains("@mikebonomusic"), captions)
        XCTAssertTrue(captions.contains("44: Catherine Gregory"))
        // Untagged photos don't appear in the tags block.
        let tagsBlock = captions.components(separatedBy: "PHOTO TAGS:")[1]
        XCTAssertFalse(tagsBlock.contains("11:"))
    }

    func testPerEventOverrideDrivesExportLayout() throws {
        // An event whose override is classic must export Sunday as a single photo
        // even when the app wide default is balanced (#66). Passing the event's
        // effectivePostingPreset is exactly what ExportManager does.
        // A scratch suite, so the real preference is neither read nor written
        // (#116).
        let suite = "postroll.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(PostingPreset.balanced.rawValue, forKey: PostingPreset.storageKey)

        var (event, _) = makeSundayCarouselEvent()
        event.postingPresetOverride = .classic
        XCTAssertEqual(event.effectivePostingPreset(in: defaults), .classic)

        let folder = try EventExporter.export(event: event, to: root,
                                              preset: event.effectivePostingPreset).folder
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("1. Sunday/carousel").path),
            "a classic override exports Sunday as a single photo, not a carousel, despite a balanced default")
    }

    func testClassicPresetKeepsSundaySinglePhoto() throws {
        let (event, _) = makeSundayCarouselEvent()
        let folder = try EventExporter.export(event: event, to: root, preset: .classic).folder
        let fm = FileManager.default

        // No carousel subfolder under classic — Sunday is a single feed photo.
        XCTAssertFalse(
            fm.fileExists(atPath: folder.appendingPathComponent("1. Sunday/carousel").path),
            "classic Sunday must not produce a carousel folder")

        // Only the first alt text is written, un-numbered.
        let captions = try String(contentsOf: folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)
        XCTAssertTrue(captions.contains("frame a"))
        XCTAssertFalse(captions.contains("11: frame a"),
                       "classic single-photo day must not number alt texts")
    }

    // Phase 4 (#135): Friday's clip_reel caption reaches CAPTIONS.txt via the
    // same generic per-day loop every other day already uses - no Friday
    // exclusion exists in EventExporter, so this is a regression pin, not
    // new production logic. (The rendered reel MP4 itself is copied by
    // ExportManager's day-copy loop, confirmed equally generic over
    // previewMediaPaths with no Friday exclusion; that async, AppState-backed
    // path isn't practical to exercise from this synchronous unit test.)
    func testFridayClipReelCaptionReachesExportedCaptionsFile() throws {
        var event = Event(name: "Music From Inside", org: "Decoda",
                          venue: "Hall", date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        var fri = PostingDay(day: .friday)
        fri.clipPaths = [makeFile("clip1.mov")]
        fri.fridayClipPlan = FridayClipPlan(
            selections: [FridayClipSelection(clipPath: "/clips/clip1.mov", trimIn: 0, trimOut: 4, transition: .cut)],
            rationale: "opens strong"
        )
        event.days = [DayName.friday.rawValue: fri]

        var result = WeekGenerationResult()
        result.friday = caption("A night of highlights, cut together.", hashtags: ["#dwphotony"])
        event.weekResult = result

        let folder = try EventExporter.export(event: event, to: root).folder
        let captions = try String(contentsOf: folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)

        XCTAssertTrue(captions.contains("=== FRIDAY ==="))
        XCTAssertTrue(captions.contains("A night of highlights, cut together."))
        XCTAssertTrue(captions.contains("#dwphotony"))
    }

    func testSlug() {
        XCTAssertEqual(EventExporter.slug("Decoda"), "decoda")
        XCTAssertEqual(EventExporter.slug("Music From Inside"), "music_from_inside")
        XCTAssertEqual(EventExporter.slug("Reverence & Resistance"), "reverence_resistance")
        XCTAssertEqual(EventExporter.slug("  Trailing!!  "), "trailing")
    }
}
