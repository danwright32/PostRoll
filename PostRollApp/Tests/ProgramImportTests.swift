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

        let readiness = ProgramImport.readiness(of: present + [gone])

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

        let readiness = ProgramImport.readiness(of: [good, empty, unreadable])

        XCTAssertEqual(readiness, .missingFiles([empty, unreadable]),
                       "a page that cannot yield its content is no use to OCR, however "
                       + "present the file is")
    }

    func testReadinessPassesWhenEveryPageIsThere() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pages = try [1, 2, 3].map { try makeFile("Recital_p\($0).png", in: dir) }

        XCTAssertEqual(ProgramImport.readiness(of: pages), .ready)
        XCTAssertNil(ProgramImport.readiness(of: pages).refusal,
                     "a whole program must not be refused")
    }

    /// #374: pressing Run OCR with no pages sent the event back to the upload
    /// screen with nothing on it saying why.
    func testReadinessRefusesAnEmptyProgramInItsOwnWords() throws {
        let empty = ProgramImport.readiness(of: [])
        XCTAssertEqual(empty, .noPages)

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = ProgramImport.readiness(
            of: [dir.appendingPathComponent("Only_p1.png")]
        )

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
