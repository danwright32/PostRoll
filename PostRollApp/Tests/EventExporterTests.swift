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

    // MARK: - Tests

    func testFullExportWritesExpectedLayout() throws {
        let p1 = makeFile("shot-100.jpg")
        let p2 = makeFile("shot-277.jpg")
        let event = makeEvent(wednesdayPhotos: [p1, p2])

        let folder = try EventExporter.export(event: event, to: root)
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
        let first = try EventExporter.export(event: makeEvent(wednesdayPhotos: [p1, p2]), to: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("4. Wednesday/carousel/02.jpg").path))

        // Re-export with Wednesday trimmed to one photo: the stale 02.jpg must
        // not survive (full export rebuilds the folder from scratch).
        let second = try EventExporter.export(event: makeEvent(wednesdayPhotos: [p1]), to: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("4. Wednesday/carousel/01.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("4. Wednesday/carousel/02.jpg").path),
                       "orphaned carousel photo from the previous export must be gone")
    }

    func testSingleDayExportLeavesMasterFilesUntouched() throws {
        let event = makeEvent(wednesdayPhotos: [makeFile("shot-100.jpg")])
        let folder = try EventExporter.export(event: event, to: root)

        let captionsURL = folder.appendingPathComponent("CAPTIONS.txt")
        let before = try String(contentsOf: captionsURL, encoding: .utf8)

        // Scoped re-export of just Sunday must not rewrite CAPTIONS.txt or the blog.
        _ = try EventExporter.export(event: event, to: root, days: [.sunday])
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
        let folder = try EventExporter.export(event: event, to: root, preset: .balanced)
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

        let folder = try EventExporter.export(event: event, to: root, preset: .balanced)
        let captions = try String(contentsOf: folder.appendingPathComponent("CAPTIONS.txt"), encoding: .utf8)
        XCTAssertTrue(captions.contains("PHOTO TAGS:"))
        XCTAssertTrue(captions.contains("22: Mike Bono, @mikebonomusic"))
        XCTAssertTrue(captions.contains("44: Catherine Gregory"))
        // Untagged photos don't appear in the tags block.
        let tagsBlock = captions.components(separatedBy: "PHOTO TAGS:")[1]
        XCTAssertFalse(tagsBlock.contains("11:"))
    }

    func testPerEventOverrideDrivesExportLayout() throws {
        // An event whose override is classic must export Sunday as a single photo
        // even when the app wide default is balanced (#66). Passing the event's
        // effectivePostingPreset is exactly what ExportManager does.
        let key = PostingPreset.storageKey
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(PostingPreset.balanced.rawValue, forKey: key)

        var (event, _) = makeSundayCarouselEvent()
        event.postingPresetOverride = .classic
        XCTAssertEqual(event.effectivePostingPreset, .classic)

        let folder = try EventExporter.export(event: event, to: root,
                                              preset: event.effectivePostingPreset)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("1. Sunday/carousel").path),
            "a classic override exports Sunday as a single photo, not a carousel, despite a balanced default")
    }

    func testClassicPresetKeepsSundaySinglePhoto() throws {
        let (event, _) = makeSundayCarouselEvent()
        let folder = try EventExporter.export(event: event, to: root, preset: .classic)
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

    func testSlug() {
        XCTAssertEqual(EventExporter.slug("Decoda"), "decoda")
        XCTAssertEqual(EventExporter.slug("Music From Inside"), "music_from_inside")
        XCTAssertEqual(EventExporter.slug("Reverence & Resistance"), "reverence_resistance")
        XCTAssertEqual(EventExporter.slug("  Trailing!!  "), "trailing")
    }
}
