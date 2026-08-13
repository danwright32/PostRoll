import XCTest

/// #284: the post metadata is reachable from the surface Dan actually copies
/// from, and cannot leak into the body.
///
/// The repo has already paid for this lesson once. The comment above the
/// existing copy button reads: "One thing to copy, title included (#205). The
/// title was generated, stored and shown, and Dan still typed it by hand every
/// time because the surface he copies from carried the body alone." Writing the
/// SEO description and details block only into `0. Blog/draft.md` would repeat
/// #205 with a new field name.
///
/// The other half is the opposite risk: pasting the metadata INTO the body is a
/// new way to ship the wrong thing, because a fact block inside `body` reaches
/// the AI round trip and the deterministic checks (#283). So the body's own
/// copy text is asserted to carry title and body and nothing else.
final class BlogMetaCopyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blogmeta-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEvent() -> Event {
        var event = Event(name: "Perpetual Light", org: "DCINY",
                          venue: "Carnegie Hall",
                          date: Date(timeIntervalSince1970: 1_775_000_000),
                          shootType: .fullShow)
        event.venueContext = "Stern Auditorium"
        event.eventURL = "https://dciny.org/perpetual-light"
        var result = WeekGenerationResult()
        result.blog = BlogOutput(title: "Inside the Music", body: "A long blog body.")
        event.weekResult = result
        event.blogPhotoPaths = []
        return event
    }

    // MARK: - Each field copies exactly itself

    func testEachCopyFieldPutsExactlyThatFieldOnThePasteboard() {
        let event = makeEvent()
        let fields = BlogMeta.copyFields(event: event)
        XCTAssertEqual(fields.count, 2, "one control per string")

        // Proved by comparing against the generators, not by looking at it.
        XCTAssertEqual(fields[0].text, BlogMeta.seoDescription(event: event))
        XCTAssertEqual(fields[1].text, BlogMeta.detailsBlock(event: event))
    }

    func testNoCopyFieldCarriesTheOther() {
        // A control labelled "SEO description" that also copies the details
        // block would paste a block of facts into a 300 character field.
        let fields = BlogMeta.copyFields(event: makeEvent())
        XCTAssertFalse(fields[0].text.contains("Photographer:"))
        XCTAssertFalse(fields[1].text.contains(BlogMeta.brandTail))
    }

    func testEveryFieldIsLabelledAndNonEmpty() {
        for field in BlogMeta.copyFields(event: makeEvent()) {
            XCTAssertFalse(field.label.isEmpty)
            XCTAssertFalse(field.text.isEmpty)
        }
    }

    // MARK: - The body stays clean

    func testTheBodyCopyCarriesOnlyTitleAndBody() {
        let event = makeEvent()
        guard let blog = event.weekResult?.blog else { return XCTFail("no blog") }
        let copied = BlogDraftText.copyText(title: blog.title, body: blog.body)

        XCTAssertFalse(copied.contains(BlogMeta.seoDescription(event: event)))
        XCTAssertFalse(copied.contains(BlogMeta.detailsBlock(event: event)))
        XCTAssertFalse(copied.contains("Photographer:"))
        XCTAssertEqual(copied, "# Inside the Music\n\nA long blog body.")
    }

    // MARK: - The export folder carries them, outside the draft

    func testTheExportWritesTheMetadataBesideTheDraftNotInsideIt() throws {
        let event = makeEvent()
        let folder = try EventExporter.export(event: event, to: root).folder
        let blogDir = folder.appendingPathComponent("0. Blog")

        let meta = try String(contentsOf: blogDir.appendingPathComponent(BlogMeta.exportFileName),
                              encoding: .utf8)
        XCTAssertTrue(meta.contains(BlogMeta.seoDescription(event: event)))
        XCTAssertTrue(meta.contains(BlogMeta.detailsBlock(event: event)))

        let draft = try String(contentsOf: blogDir.appendingPathComponent("draft.md"),
                               encoding: .utf8)
        XCTAssertFalse(draft.contains(BlogMeta.seoDescription(event: event)),
                       "metadata leaked into the draft, which is the #283 hazard")
        XCTAssertFalse(draft.contains("Photographer:"))
    }

    func testTheMetadataFileSaysItIsNotPartOfTheDraft() throws {
        // A second file in the blog folder that looks like more post reads as
        // something to paste into the post. It has to say what it is for.
        let text = BlogMeta.exportFileText(event: makeEvent())
        XCTAssertTrue(text.lowercased().contains("not part of the post"), text)
        for field in BlogMeta.copyFields(event: makeEvent()) {
            XCTAssertTrue(text.contains(field.label), "\(field.label) is unlabelled in the file")
        }
    }

    func testASingleDayExportLeavesTheMetadataAlone() throws {
        // Same rule the draft and CAPTIONS.txt already follow: a single-day
        // export must not rewrite files that describe the whole week.
        let event = makeEvent()
        // Committed, because a scoped re-export starts from the export that is
        // actually on disk and an uncommitted one is not there yet (#442).
        try EventExporter.export(event: event, to: root).staging.commit()
        let blogDir = try EventExporter.export(event: event, to: root, days: [.sunday])
            .folder.appendingPathComponent("0. Blog")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: blogDir.appendingPathComponent(BlogMeta.exportFileName).path))
    }

    // MARK: - Failure path

    func testAnEventWithNoBlogWritesNoMetadataFile() throws {
        // No post means nothing to describe. A metadata file beside no draft
        // would read as a post that failed to write.
        var event = makeEvent()
        event.weekResult = WeekGenerationResult()
        let folder = try EventExporter.export(event: event, to: root).folder
        let path = folder.appendingPathComponent("0. Blog")
            .appendingPathComponent(BlogMeta.exportFileName).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
