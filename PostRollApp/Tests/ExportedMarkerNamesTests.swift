import XCTest

/// #1142: the exported draft names the files that are actually in the export.
///
/// `EventExporter` writes the blog photographs out renumbered as `photo_01.jpg`,
/// `photo_02.jpg` and so on, in `blogPhotoPaths` order, and writes `draft.md`
/// from the body unchanged. So every `[PHOTO:]` marker in the exported draft
/// named a file that is not in the export, and every file in the export was
/// named by nothing.
///
/// The export folder is the deliverable: it is what gets uploaded. Somebody
/// pasting the draft into a blog editor had to work out which photograph each
/// marker meant by opening them in order and hoping the order matched, with
/// nothing in the folder saying it did.
///
/// The renaming is a pure function so it can be tested without staging a whole
/// export, and so the exporter's copy loop and the draft can be produced from
/// ONE mapping rather than each walking `blogPhotoPaths` separately, which is
/// how the two came to disagree.
final class ExportedMarkerNamesTests: XCTestCase {

    func testAMarkerIsRenamedToTheExportedFile() {
        let body = "It ran late.\n\n[PHOTO: DSC4821.jpg | Dancers mid turn]"
        let renamed = BlogDraftText.renamingPhotos(
            in: body, to: ["DSC4821.jpg": "photo_01.jpg"])

        XCTAssertEqual(renamed,
                       "It ran late.\n\n[PHOTO: photo_01.jpg | Dancers mid turn]")
    }

    func testTheAltTextIsUntouched() {
        // The alt text is what a screen reader announces and it is judged
        // against the photograph. Only the FILENAME is an export detail.
        let body = "[PHOTO: a.jpg | A dancer, mid turn, under a blue wash]"
        let renamed = BlogDraftText.renamingPhotos(in: body, to: ["a.jpg": "photo_01.jpg"])

        XCTAssertTrue(renamed.contains("| A dancer, mid turn, under a blue wash]"),
                      "the alt text changed: \(renamed)")
    }

    func testProseIsPreservedVerbatim() {
        // A filename that also appears in the prose must not be rewritten
        // there: the prose is Dan's writing and the export is not entitled to
        // edit it.
        let body = "I called it a.jpg at the time.\n\n[PHOTO: a.jpg | Alt]"
        let renamed = BlogDraftText.renamingPhotos(in: body, to: ["a.jpg": "photo_01.jpg"])

        XCTAssertTrue(renamed.hasPrefix("I called it a.jpg at the time."),
                      "the prose was rewritten: \(renamed)")
        XCTAssertTrue(renamed.contains("[PHOTO: photo_01.jpg |"), renamed)
    }

    func testAMarkerWithNoMappingIsLeftAlone() {
        // Not renamed to a guess. A marker naming a photograph that is not in
        // the export is a fault the blog checks already report, and inventing
        // a name for it would hide that (L98).
        let body = "[PHOTO: missing.jpg | Alt]"

        XCTAssertEqual(BlogDraftText.renamingPhotos(in: body, to: ["a.jpg": "photo_01.jpg"]),
                       body)
    }

    func testEveryMarkerIsRenamedNotJustTheFirst() {
        let body = "[PHOTO: a.jpg | One]\n\nText.\n\n[PHOTO: b.jpg | Two]"
        let renamed = BlogDraftText.renamingPhotos(
            in: body, to: ["a.jpg": "photo_01.jpg", "b.jpg": "photo_02.jpg"])

        XCTAssertTrue(renamed.contains("[PHOTO: photo_01.jpg | One]"), renamed)
        XCTAssertTrue(renamed.contains("[PHOTO: photo_02.jpg | Two]"), renamed)
    }

    func testAFilenameWithSpacesAndPunctuationIsMatched() {
        // Dan's real filenames carry the show title, the venue in brackets and
        // his handle. A matcher that assumed a simple token would rename none
        // of them, and would do it silently.
        let name = "DiGangi With A \"G\" (The Green Room 42) @dwphotony-141.jpg"
        let body = "[PHOTO: \(name) | Alt]"

        XCTAssertEqual(BlogDraftText.renamingPhotos(in: body, to: [name: "photo_01.jpg"]),
                       "[PHOTO: photo_01.jpg | Alt]")
    }

    func testAnEmptyMappingChangesNothing() {
        let body = "[PHOTO: a.jpg | Alt]"
        XCTAssertEqual(BlogDraftText.renamingPhotos(in: body, to: [:]), body)
    }

    // MARK: - the export actually uses it

    /// The test #1142 asks for, and the one that matters: built is not wired
    /// (L3). Every `[PHOTO:]` filename in the exported draft must name a file
    /// that is in the exported folder. It failed before the exporter was
    /// changed, with all seven unit tests above already passing.
    func testEveryMarkerInTheExportedDraftNamesAFileInTheFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("exported-markers-\(UUID().uuidString)")
        let assets = root.appendingPathComponent("_assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeFile(_ name: String) -> URL {
            let url = assets.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data("img".utf8))
            return url
        }
        let photos = [makeFile("DSC4821.jpg"), makeFile("DSC4822.jpg"),
                      makeFile("DSC4823.jpg")]

        var event = Event(name: "Music From Inside", org: "Decoda", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        event.blogPhotoPaths = photos
        var result = WeekGenerationResult()
        result.blog = BlogOutput(
            title: "Inside the Music",
            body: photos.map { "Prose.\n\n[PHOTO: \($0.lastPathComponent) | Alt text]" }
                .joined(separator: "\n\n"))
        event.weekResult = result

        // Committed, because `export` stages and the staged copy is not the
        // deliverable. Reading the staged path is how this first failed.
        let folder = try EventExporter.export(event: event, to: root).staging.commit()

        let blogDir = folder.appendingPathComponent("0. Blog")
        let draft = try String(contentsOf: blogDir.appendingPathComponent("draft.md"),
                               encoding: .utf8)
        let names = try FileManager.default
            .contentsOfDirectory(atPath: blogDir.path)

        let re = try NSRegularExpression(pattern: #"\[PHOTO:\s*([^|\]]+?)\s*\|"#)
        let text = draft as NSString
        let matches = re.matches(in: draft,
                                 range: NSRange(location: 0, length: text.length))
        XCTAssertEqual(matches.count, photos.count,
                       "the exported draft holds \(matches.count) markers, not \(photos.count)")
        for match in matches {
            let named = text.substring(with: match.range(at: 1))
            XCTAssertTrue(names.contains(named),
                          "the exported draft names \(named), which is not in the "
                          + "exported folder: \(names.sorted())")
        }
    }
}
