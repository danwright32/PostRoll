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
