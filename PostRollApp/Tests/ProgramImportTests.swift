import XCTest

/// #368: `ProgramPDFBuilder.rasterise` dropped a page it could not turn into an
/// image and handed back a shorter list with nothing saying one was absent.
/// Program OCR reads that list, so a program whose page 3 failed was OCR'd as
/// though it only ever had the other pages, and the performers and works
/// printed on it were missing from captions, the blog and the searchable PDF
/// with no error anywhere.
///
/// A short list and a genuinely short program are indistinguishable downstream,
/// which is why the failure has to travel back beside the pages, and why an
/// upload that did not come in whole contributes nothing until Dan chooses
/// otherwise.
final class ProgramImportTests: XCTestCase {

    private func page(_ name: String) -> URL {
        URL(fileURLWithPath: "/programs/\(name)")
    }

    // MARK: - What reaches the event

    func testACompleteUploadContributesItsPages() {
        let pages = [page("Dciny_p1.png"), page("Dciny_p2.png")]
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(source: page("Dciny.pdf"),
                                 result: ProgramImport.Rasterisation(pages: pages))
        ])

        XCTAssertEqual(plan.pagesToAdd, pages)
        XCTAssertTrue(plan.incomplete.isEmpty)
    }

    func testAnIncompleteUploadContributesNoPagesAtAll() {
        // Nine pages arrived, page 3 never did. Adding the nine is exactly the
        // defect: OCR reads them as the whole program.
        let arrived = (1...9).map { page("Gala_p\($0).png") }
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(
                source: page("Gala.pdf"),
                result: ProgramImport.Rasterisation(
                    pages: arrived,
                    failures: [.couldNotWritePage(3, reason: "No space left on device")]
                )
            )
        ])

        XCTAssertTrue(plan.pagesToAdd.isEmpty,
                      "a program missing a page must not reach OCR as though it were whole")
        XCTAssertEqual(plan.incomplete.count, 1)
        XCTAssertEqual(plan.incomplete.first?.fileName, "Gala.pdf")
        XCTAssertEqual(plan.incomplete.first?.pagesThatWorked, arrived,
                       "the pages that did arrive stay available, so Dan can take them knowingly")
    }

    func testAGoodUploadInTheSameBatchStillComesIn() {
        let good = [page("Cast_p1.png")]
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(source: page("Cast.pdf"),
                                 result: ProgramImport.Rasterisation(pages: good)),
            ProgramImport.Upload(
                source: page("Notes.pdf"),
                result: ProgramImport.Rasterisation(pages: [page("Notes_p1.png")],
                                                    failures: [.missingPage(2)])
            ),
        ])

        XCTAssertEqual(plan.pagesToAdd, good)
        XCTAssertEqual(plan.incomplete.map(\.fileName), ["Notes.pdf"])
    }

    func testTheSamePageIsNotAddedTwice() {
        let shared = page("Cast_p1.png")
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(source: page("Cast.pdf"),
                                 result: ProgramImport.Rasterisation(pages: [shared])),
            ProgramImport.Upload(source: page("Cast.pdf"),
                                 result: ProgramImport.Rasterisation(pages: [shared])),
        ])

        XCTAssertEqual(plan.pagesToAdd, [shared])
    }

    // MARK: - What Dan is told

    func testTheMessageNamesTheFileThePageAndTheReason() throws {
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(
                source: page("Carnegie.pdf"),
                result: ProgramImport.Rasterisation(
                    pages: [page("Carnegie_p1.png")],
                    failures: [.couldNotWritePage(3, reason: "Permission denied")]
                )
            )
        ])

        let message = try XCTUnwrap(plan.incomplete.first?.message)
        XCTAssertTrue(message.contains("Carnegie.pdf"), message)
        XCTAssertTrue(message.contains("3"), "the message has to name the page that is missing: \(message)")
        XCTAssertTrue(message.contains("Permission denied"),
                      "the reason is what tells Dan whether retrying can work: \(message)")
    }

    func testEachCauseReadsDifferently() {
        // Distinct causes get distinct messages (L11): "the file would not open"
        // and "page 4 would not save" call for different responses from Dan.
        let messages = [
            ProgramImport.Failure.unreadableDocument,
            .missingPage(4),
            .couldNotRenderPage(4),
            .couldNotWritePage(4, reason: "disk full"),
            .couldNotStoreFile(reason: "disk full"),
        ].map(\.message)

        XCTAssertEqual(Set(messages).count, messages.count,
                       "two causes share one message, so the message cannot say which happened")
        for message in messages {
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// #389: seen only once these were rendered. A reason from the operating
    /// system ("No space left on device") carries no full stop, and the message
    /// puts the next sentence straight after it, so the banner read
    /// "...No space left on device None of the 9 pages...". Every cause has to
    /// end as a sentence, whatever the system hands us.
    func testEveryCauseEndsAsASentence() {
        let causes: [ProgramImport.Failure] = [
            .unreadableDocument,
            .missingPage(3),
            .couldNotRenderPage(3),
            .couldNotWritePage(3, reason: "No space left on device"),
            .couldNotStoreFile(reason: "Permission denied"),
        ]

        for cause in causes {
            let last = cause.message.last
            XCTAssertTrue(last == "." || last == "?" || last == "!",
                          "\"\(cause.message)\" runs straight into whatever follows it")
        }
    }

    /// And the assembled banner must not collide two sentences, which is what
    /// the person actually reads.
    func testTheAssembledMessageDoesNotRunTwoSentencesTogether() {
        let incomplete = ProgramImport.Incomplete(
            fileName: "Gala.pdf",
            pagesThatWorked: [page("Gala_p1.png")],
            failures: [.couldNotWritePage(3, reason: "No space left on device")]
        )

        XCTAssertFalse(incomplete.message.contains("device None"),
                       "two sentences ran together: \(incomplete.message)")
        XCTAssertTrue(incomplete.message.contains("device."),
                      "the cause has to close before the next sentence: \(incomplete.message)")
    }

    func testAFileThatProducedNothingSaysSoRatherThanOfferingPages() throws {
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(
                source: page("Scan.pdf"),
                result: ProgramImport.Rasterisation(failures: [.unreadableDocument])
            )
        ])

        let incomplete = try XCTUnwrap(plan.incomplete.first)
        XCTAssertTrue(incomplete.pagesThatWorked.isEmpty)
        XCTAssertTrue(incomplete.message.contains("Scan.pdf"), incomplete.message)
    }

    // MARK: - Saying how many pages arrived against how many were expected

    /// #373: the page count shown after an import had nothing to compare
    /// against, so a short program was only visible if the app had detected the
    /// failure itself. The PDF's own declared count is a second, independent
    /// route to the same number, so a disagreement is visible by eye even when
    /// nothing failed.
    func testACompleteUploadSaysHowManyPagesArrivedOfHowManyExpected() throws {
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(
                source: page("Gala.pdf"),
                result: ProgramImport.Rasterisation(
                    pages: (1...12).map { page("Gala_p\($0).png") },
                    declaredPageCount: 12
                )
            )
        ])

        let note = try XCTUnwrap(plan.imported.first)
        XCTAssertEqual(note.fileName, "Gala.pdf")
        XCTAssertTrue(note.summary.contains("12 of 12"), note.summary)
    }

    func testAnImageSaysItsOnePageWithoutInventingAnExpectedCount() throws {
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(source: page("cover.jpg"),
                                 result: ProgramImport.Rasterisation(pages: [page("cover.jpg")]))
        ])

        let note = try XCTUnwrap(plan.imported.first)
        XCTAssertFalse(note.summary.contains(" of "),
                       "an uploaded image declares no page count, so there is nothing to compare "
                       + "it against: \(note.summary)")
    }

    /// A page the loop never accounted for, neither imported nor reported as a
    /// failure, is the one case the failure list alone cannot see. The declared
    /// count is what catches it (L70: two sides resolved by independent routes).
    func testPagesUnaccountedForAreThemselvesAFailure() {
        let result = ProgramImport.Rasterisation(
            pages: [page("Short_p1.png")],
            declaredPageCount: 4
        )

        XCTAssertFalse(result.isComplete,
                       "one page imported out of four declared, with nothing reported, has to "
                       + "count as an incomplete program")
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(source: page("Short.pdf"), result: result)
        ])
        XCTAssertTrue(plan.pagesToAdd.isEmpty)
        XCTAssertEqual(plan.incomplete.first?.fileName, "Short.pdf")
    }

    // MARK: - Taking an incomplete program on purpose (#378)

    /// The escape hatch from #368 is the one case where a short program does
    /// become the program. That makes it exactly the case that needs a record:
    /// without one, the OCR review, captions and blog are built from a program
    /// known to be incomplete and nothing says so, which is the defect #368
    /// closed arriving by Dan's own hand.
    func testAcceptingAnIncompleteProgramIsRecordedAgainstItsFile() throws {
        // Built through plan(), not by hand, so this also pins that the declared
        // count actually reaches the record rather than being dropped on the way.
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(
                source: page("Gala.pdf"),
                result: ProgramImport.Rasterisation(
                    pages: (1...9).map { page("Gala_p\($0).png") },
                    failures: [.couldNotWritePage(3, reason: "No space left on device")],
                    declaredPageCount: 12
                )
            )
        ])
        let incomplete = try XCTUnwrap(plan.incomplete.first)

        let note = ProgramShortfall.acceptanceNote(for: incomplete)

        XCTAssertTrue(note.contains("Gala.pdf"), note)
        XCTAssertTrue(note.contains("9"), "how much of the program was read: \(note)")
        XCTAssertTrue(note.contains("12"), "out of how much: \(note)")
        XCTAssertTrue(note.contains("3"), "which page is absent from it: \(note)")
    }

    func testANoteSurvivesUntilThatFileComesInWhole() {
        let existing = [
            "Gala.pdf": "old note",
            "Cast.pdf": "unrelated note",
        ]

        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(
                source: page("Gala.pdf"),
                result: ProgramImport.Rasterisation(
                    pages: (1...12).map { page("Gala_p\($0).png") },
                    declaredPageCount: 12
                )
            )
        ])

        let kept = ProgramShortfall.notes(existing, clearedBy: plan)

        XCTAssertNil(kept["Gala.pdf"],
                     "the file has since come in whole, so the program is no longer partial")
        XCTAssertEqual(kept["Cast.pdf"], "unrelated note",
                       "another file's shortfall is untouched by this one being fixed")
    }

    func testAnIncompleteReimportDoesNotClearTheNote() {
        let plan = ProgramImport.plan(for: [
            ProgramImport.Upload(
                source: page("Gala.pdf"),
                result: ProgramImport.Rasterisation(
                    pages: [page("Gala_p1.png")],
                    failures: [.missingPage(3)]
                )
            )
        ])

        let kept = ProgramShortfall.notes(["Gala.pdf": "old note"], clearedBy: plan)

        XCTAssertEqual(kept["Gala.pdf"], "old note",
                       "a re-import that failed the same way leaves the program just as partial")
    }

    /// The captions and blog are written long after the import, often in a
    /// later session, and by then nothing else can tell the program is short.
    /// A record that does not survive a relaunch is no record at all.
    func testAPartialProgramNoteSurvivesASaveAndReload() throws {
        var event = Event(name: "Spring Gala", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        event.partialProgramNotes = ["Gala.pdf": "9 of 12 pages were read."]

        let reloaded = try JSONDecoder().decode(
            Event.self, from: try JSONEncoder().encode(event))

        XCTAssertEqual(reloaded.partialProgramNotes, ["Gala.pdf": "9 of 12 pages were read."])
    }

    func testEventsSavedBeforeTheFieldExistedStillLoad() throws {
        let legacy = """
        {"id":"22222222-2222-2222-2222-222222222222","name":"Old Show","org":"Org",
         "venue":"Hall","date":0,"shootType":"Performance"}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(Event.self, from: legacy)

        XCTAssertEqual(event.partialProgramNotes, [:],
                       "a missing key must not wipe the rest of a saved event")
    }

    // MARK: - The program still being whole when OCR reads it

    /// #372: #368 closed this at the import end, so a partial program can no
    /// longer be stored. A page deleted or reclaimed between import and OCR
    /// opens the same hole from the read end: the pages that remain get read as
    /// the whole program, and nothing says one is gone.
    func testReadinessRefusesWhenAPageIsNoLongerOnDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let present = try [1, 2].map { try makeFile("Gala_p\($0).png", in: dir) }
        let gone = dir.appendingPathComponent("Gala_p3.png")

        let readiness = ProgramReadiness.of(present + [gone])

        XCTAssertEqual(readiness, .missingFiles([gone]))
        let refusal = try XCTUnwrap(readiness.refusal)
        XCTAssertTrue(refusal.contains("Gala_p3.png"),
                      "the refusal has to name the page that is gone: \(refusal)")
        // The check asks whether the file can be SEEN, and a file the app is
        // blocked from reading looks identical to one that was deleted, so the
        // message may not assert deletion (L11).
        XCTAssertTrue(refusal.contains("can't be read"),
                      "the refusal may claim only what the check measured: \(refusal)")
        XCTAssertFalse(refusal.lowercased().contains("went missing"), refusal)
    }

    /// #379: the check asked whether each page EXISTS, while the refusal it
    /// produces says the page cannot be read. A zero byte or unreadable file
    /// passes an existence check, reaches OCR, and contributes nothing, which
    /// puts the program back to being quietly short. A message may claim only
    /// what its check measured, so the check has to measure readability.
    func testReadinessRefusesAPageThatIsThereButCannotBeRead() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let good = try makeFile("Gala_p1.png", in: dir)
        let empty = dir.appendingPathComponent("Gala_p2.png")
        try Data().write(to: empty)
        let unreadable = try makeFile("Gala_p3.png", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: unreadable.path)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path),
                      "precondition: an empty page is still a file that exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path),
                      "precondition: an unreadable page is still a file that exists")

        let readiness = ProgramReadiness.of([good, empty, unreadable])

        XCTAssertEqual(readiness, .missingFiles([empty, unreadable]),
                       "a page that cannot yield its content is no use to OCR, however "
                       + "present the file is")
    }

    func testReadinessPassesWhenEveryPageIsThere() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pages = try [1, 2, 3].map { try makeFile("Recital_p\($0).png", in: dir) }

        XCTAssertEqual(ProgramReadiness.of(pages), .ready)
        XCTAssertNil(ProgramReadiness.of(pages).refusal,
                     "a whole program must not be refused")
    }

    /// #374: pressing Run OCR with no pages sent the event back to the upload
    /// screen with nothing on it saying why.
    func testReadinessRefusesAnEmptyProgramInItsOwnWords() throws {
        let empty = ProgramReadiness.of([])
        XCTAssertEqual(empty, .noPages)

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = ProgramReadiness.of([dir.appendingPathComponent("Only_p1.png")])

        let noPages = try XCTUnwrap(empty.refusal)
        let gone = try XCTUnwrap(missing.refusal)
        XCTAssertNotEqual(noPages, gone,
                          "nothing uploaded and a page that vanished call for different actions, "
                          + "so they cannot share one message (L11)")
        XCTAssertFalse(noPages.isEmpty)
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("program-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("page".utf8).write(to: url)
        return url
    }

    // MARK: - Taking the readable pages deliberately

    func testDanCanStillTakeThePagesThatWorked() {
        let arrived = [page("Gala_p1.png"), page("Gala_p2.png")]
        let incomplete = ProgramImport.Incomplete(
            fileName: "Gala.pdf",
            pagesThatWorked: arrived,
            failures: [.missingPage(3)]
        )

        // The refusal is a default, not a wall: a genuinely damaged page must
        // not make the rest of the program unusable (L54).
        XCTAssertEqual(incomplete.pagesThatWorked, arrived)
    }
}
