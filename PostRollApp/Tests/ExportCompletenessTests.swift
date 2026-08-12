import XCTest

/// An export that quietly drops a photo produces a folder Dan uploads with
/// content missing, and the event still reads "Exported" (#79). Every copy the
/// export intended to make is now accounted for.
final class ExportCompletenessTests: XCTestCase {

    private var root: URL!
    private var assets: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-completeness-\(UUID().uuidString)")
        assets = root.appendingPathComponent("_assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String) -> URL {
        let url = assets.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("img".utf8))
        return url
    }

    private func event(wednesdayPhotos: [URL], blogPhotos: [URL]) -> Event {
        var event = Event(name: "Music From Inside", org: "Decoda", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000), shootType: .fullShow)
        var wed = PostingDay(day: .wednesday)
        wed.photoPaths = wednesdayPhotos
        event.days = [DayName.wednesday.rawValue: wed]
        event.blogPhotoPaths = blogPhotos
        var result = WeekGenerationResult()
        var cap = DayCaption(); cap.caption = "Carousel day"
        result.wednesday = cap
        result.blog = BlogOutput(title: "Inside the Music", body: "Body.")
        event.weekResult = result
        return event
    }

    func testACleanExportReportsNothingDropped() throws {
        let ev = event(wednesdayPhotos: [makeFile("a.jpg"), makeFile("b.jpg")],
                       blogPhotos: [makeFile("blog1.jpg")])

        let outcome = try EventExporter.export(event: ev, to: root)

        XCTAssertTrue(outcome.dropped.isEmpty)
        XCTAssertTrue(outcome.isComplete)
        XCTAssertNil(outcome.warning)
    }

    func testAMissingCarouselPhotoIsReportedNotSkipped() throws {
        let present = makeFile("a.jpg")
        let gone = assets.appendingPathComponent("gone.jpg")   // never created
        let ev = event(wednesdayPhotos: [present, gone], blogPhotos: [])

        let outcome = try EventExporter.export(event: ev, to: root)

        XCTAssertFalse(outcome.isComplete, "the folder is short a photo")
        XCTAssertEqual(outcome.dropped.map(\.source), [gone])
        let warning = try XCTUnwrap(outcome.warning)
        XCTAssertTrue(warning.contains("gone.jpg"), warning)
        XCTAssertTrue(warning.lowercased().contains("wednesday"), warning)
    }

    func testAMissingBlogPhotoIsReported() throws {
        let gone = assets.appendingPathComponent("blogX.jpg")
        let ev = event(wednesdayPhotos: [makeFile("a.jpg")], blogPhotos: [gone])

        let outcome = try EventExporter.export(event: ev, to: root)

        XCTAssertEqual(outcome.dropped.map(\.source), [gone])
        XCTAssertTrue(try XCTUnwrap(outcome.warning).lowercased().contains("blog"))
    }

    func testTheFilesThatDidCopyStillLand() throws {
        let present = makeFile("a.jpg")
        let gone = assets.appendingPathComponent("gone.jpg")
        let ev = event(wednesdayPhotos: [present, gone], blogPhotos: [])

        let outcome = try EventExporter.export(event: ev, to: root)

        let carousel = outcome.folder
            .appendingPathComponent(DayName.wednesday.folderName)
            .appendingPathComponent("carousel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: carousel.appendingPathComponent("01.jpg").path),
                      "one bad photo must not cost the good ones")
    }
}
