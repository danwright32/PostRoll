import XCTest

/// #1142: the exported draft names the files that are actually in the export.
///
/// `EventExporter` wrote the blog photographs out under export names and wrote
/// `draft.md` from the body unchanged. So every `[PHOTO:]` marker in the
/// exported draft named a file that is not in the export, and every file in
/// the export was named by nothing. The export names are the photographs' own
/// since #1477, made distinct only where two of them clash.
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

    /// Two photographs from different folders sharing a basename is an
    /// ordinary way to shoot: `day 1/DSC4821.jpg` and `day 2/DSC4821.jpg`.
    /// `blog_quality.refuse_colliding_filenames` exists for exactly that case.
    ///
    /// The first version of the export mapping keyed on the basename with
    /// `Dictionary(uniqueKeysWithValues:)`, which TRAPS on a duplicate key, so
    /// this would have crashed the export outright. Keeping only one of the
    /// two would have been worse in a quieter way: the copy loop looked the
    /// name up by basename, so both photographs would have been written to the
    /// same file and one would be gone.
    func testTwoPhotosSharingABasenameStillBothExport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("colliding-basenames-\(UUID().uuidString)")
        let one = root.appendingPathComponent("day 1")
        let two = root.appendingPathComponent("day 2")
        for dir in [one, two] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        var photos: [URL] = []
        for dir in [one, two] {
            let url = dir.appendingPathComponent("DSC4821.jpg")
            FileManager.default.createFile(atPath: url.path, contents: Data("img".utf8))
            photos.append(url)
        }

        var event = Event(name: "Two Days", org: "Decoda", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        event.blogPhotoPaths = photos
        var result = WeekGenerationResult()
        result.blog = BlogOutput(title: "T",
                                 body: "Prose.\n\n[PHOTO: DSC4821.jpg | Alt text]")
        event.weekResult = result

        let folder = try EventExporter.export(event: event, to: root).staging.commit()
        let blogDir = folder.appendingPathComponent("0. Blog")
        let names = try FileManager.default.contentsOfDirectory(atPath: blogDir.path)

        XCTAssertTrue(names.contains("DSC4821.jpg"), names.sorted().description)
        XCTAssertTrue(names.contains("DSC4821-2.jpg"),
                      "the second photograph did not reach the export, so one "
                      + "overwrote the other: \(names.sorted())")
    }

    // MARK: - the exported names (#1477)

    /// Dan uploads from his own library, where the photographs carry their real
    /// filenames. A `photo_11` in the draft named nothing he could find there,
    /// so each marker had to be matched to a picture by eye.

    func testDistinctNamesAreKeptAsTheyAre() {
        let photos = [URL(fileURLWithPath: "/a/DSC4821.jpg"),
                      URL(fileURLWithPath: "/a/DSC4822.JPG")]
        XCTAssertEqual(BlogDraftText.exportNames(for: photos),
                       ["DSC4821.jpg", "DSC4822.JPG"])
    }

    func testOnlyTheSecondOfTwoSharingANameIsSuffixed() {
        let photos = [URL(fileURLWithPath: "/day 1/DSC4821.jpg"),
                      URL(fileURLWithPath: "/day 2/DSC4821.jpg"),
                      URL(fileURLWithPath: "/day 3/DSC4821.jpg")]
        XCTAssertEqual(BlogDraftText.exportNames(for: photos),
                       ["DSC4821.jpg", "DSC4821-2.jpg", "DSC4821-3.jpg"])
    }

    func testNamesDifferingOnlyInCaseAreTreatedAsTheSameFile() {
        // The Mac's disk ignores case, so these are one file there, and the
        // second copy would quietly replace the first.
        let photos = [URL(fileURLWithPath: "/a/DSC4821.jpg"),
                      URL(fileURLWithPath: "/b/dsc4821.JPG")]
        XCTAssertEqual(BlogDraftText.exportNames(for: photos),
                       ["DSC4821.jpg", "dsc4821-2.JPG"])
    }

    func testAnAccentTypedTwoWaysIsTheSameFile() {
        let precomposed = "Caf\u{00E9}.jpg"
        let combining = "Cafe\u{0301}.jpg"
        let photos = [URL(fileURLWithPath: "/a/\(precomposed)"),
                      URL(fileURLWithPath: "/b/\(combining)")]
        let names = BlogDraftText.exportNames(for: photos)
        XCTAssertEqual(names.count, 2)
        XCTAssertNotEqual(names[0].precomposedStringWithCanonicalMapping,
                          names[1].precomposedStringWithCanonicalMapping,
                          "both export to one file on the Mac's disk: \(names)")
    }

    func testASuffixNeverLandsOnARealName() {
        // A real photograph already called DSC4821-2.jpg keeps that name, and
        // the clashing DSC4821.jpg moves on to the next free number.
        let photos = [URL(fileURLWithPath: "/a/DSC4821.jpg"),
                      URL(fileURLWithPath: "/a/DSC4821-2.jpg"),
                      URL(fileURLWithPath: "/b/DSC4821.jpg")]
        XCTAssertEqual(BlogDraftText.exportNames(for: photos),
                       ["DSC4821.jpg", "DSC4821-2.jpg", "DSC4821-3.jpg"])
    }

    func testANameTheMarkerCannotHoldHasThoseCharactersReplaced() {
        // A marker is `[PHOTO: name | alt]`: a pipe ends the name and a closing
        // bracket ends the marker, so a file named with either would export a
        // draft whose marker names a file that is not there. Both are legal in
        // a macOS filename.
        let photos = [URL(fileURLWithPath: "/a/Act 1 | Scene [2].jpg")]
        XCTAssertEqual(BlogDraftText.exportNames(for: photos), ["Act 1 _ Scene _2_.jpg"])
    }

    func testARenamedClashIsMarkerSafeInItsExtensionToo() {
        let photos = [URL(fileURLWithPath: "/a/shot.j|g"), URL(fileURLWithPath: "/b/shot.j|g")]
        XCTAssertEqual(BlogDraftText.exportNames(for: photos), ["shot.j_g", "shot-2.j_g"])
    }

    func testAnOrdinaryExportKeepsTheRealNamesInTheDraftAndTheFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-names-\(UUID().uuidString)")
        let assets = root.appendingPathComponent("_assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let name = "Broadway Undressed (54 Below) @dwphotony-130.jpg"
        let photo = assets.appendingPathComponent(name)
        FileManager.default.createFile(atPath: photo.path, contents: Data("img".utf8))

        var event = Event(name: "Broadway Undressed", org: "Tom Guthrie", venue: "54 Below",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        event.blogPhotoPaths = [photo]
        var result = WeekGenerationResult()
        result.blog = BlogOutput(title: "T", body: "Prose.\n\n[PHOTO: \(name) | Alt text]")
        event.weekResult = result

        let folder = try EventExporter.export(event: event, to: root).staging.commit()
        let blogDir = folder.appendingPathComponent("0. Blog")
        let draft = try String(contentsOf: blogDir.appendingPathComponent("draft.md"),
                               encoding: .utf8)

        let listing = try FileManager.default.contentsOfDirectory(atPath: blogDir.path)
        XCTAssertTrue(listing.contains(name), listing.sorted().description)
        XCTAssertTrue(draft.contains("[PHOTO: \(name) | Alt text]"), draft)
    }

    // MARK: - the export actually uses it

    /// The test #1142 asks for, and the one that matters: built is not wired
    /// (L3). Every `[PHOTO:]` filename in the exported draft must name a file
    /// that is in the exported folder. It failed before the exporter was
    /// changed, with every unit test above it already passing.
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
