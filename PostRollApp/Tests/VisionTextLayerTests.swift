import XCTest

/// #209: when the Vision text layer cannot be trusted, say which way it failed.
///
/// The spelling cross-check is only as good as the layer it reads. A layer that
/// is missing, stale, or still baking must be reported rather than quietly
/// treated as a program with nothing wrong in it, because that silence is
/// indistinguishable from a clean result and would switch the check off the
/// first time a bake had not finished.
final class VisionTextLayerTests: XCTestCase {

    private let pages = [URL(fileURLWithPath: "/tmp/p1.png"),
                         URL(fileURLWithPath: "/tmp/p2.png")]

    private var currentFingerprint: String { ProgramPDFBuilder.fingerprint(of: pages) }

    func testAReadableCurrentLayerIsUsed() {
        let result = VisionTextLayer.availability(
            pdfPath: URL(fileURLWithPath: "/tmp/program.pdf"),
            pdfExists: true,
            currentPages: pages,
            bakedFingerprint: currentFingerprint,
            extractedText: "BLUDLINE Safa @safa.wav vocals Marguerite Dubois violin Presented by Greenwich House Yefim Kolodkin conductor")

        XCTAssertEqual(result, .ready("BLUDLINE Safa @safa.wav vocals Marguerite Dubois violin Presented by Greenwich House Yefim Kolodkin conductor"))
    }

    func testNoPdfYetIsItsOwnAnswer() {
        XCTAssertEqual(
            VisionTextLayer.availability(
                pdfPath: nil, pdfExists: false, currentPages: pages,
                bakedFingerprint: nil, extractedText: nil),
            .unavailable(.notBuiltYet))
    }

    func testAPathPointingAtNothingIsNotTheSameAsNoPath() {
        // Different causes get different messages: one is "you have not uploaded
        // the program", the other is "the file you had has gone".
        XCTAssertEqual(
            VisionTextLayer.availability(
                pdfPath: URL(fileURLWithPath: "/tmp/program.pdf"), pdfExists: false,
                currentPages: pages, bakedFingerprint: currentFingerprint,
                extractedText: nil),
            .unavailable(.missingOnDisk))
    }

    func testPagesChangedAfterTheBakeMakesTheLayerStale() {
        // The text would be a correct reading of a DIFFERENT program, which is
        // worse than no text: every name in the current one would flag.
        XCTAssertEqual(
            VisionTextLayer.availability(
                pdfPath: URL(fileURLWithPath: "/tmp/program.pdf"), pdfExists: true,
                currentPages: pages + [URL(fileURLWithPath: "/tmp/p3.png")],
                bakedFingerprint: currentFingerprint,
                extractedText: "BLUDLINE Safa @safa.wav vocals Marguerite Dubois violin Presented by Greenwich House Yefim Kolodkin conductor"),
            .unavailable(.stale))
    }

    func testAStaleLayerIsRefusedEvenThoughItReadsPerfectlyWell() {
        // Guarding the ORDER of the checks. Text present and a fingerprint
        // mismatch must resolve to stale, never to ready, or a reordered page
        // set silently keeps checking against the old program.
        let result = VisionTextLayer.availability(
            pdfPath: URL(fileURLWithPath: "/tmp/program.pdf"), pdfExists: true,
            currentPages: pages.reversed(),
            bakedFingerprint: currentFingerprint,
            extractedText: "a full page of perfectly good text")

        XCTAssertNotEqual(result, .ready("a full page of perfectly good text"))
    }

    func testAnEmptyOrWhitespaceLayerCountsAsNoTextAtAll() {
        for text in ["", "   \n\t ", nil] {
            XCTAssertEqual(
                VisionTextLayer.availability(
                    pdfPath: URL(fileURLWithPath: "/tmp/program.pdf"), pdfExists: true,
                    currentPages: pages, bakedFingerprint: currentFingerprint,
                    extractedText: text),
                .unavailable(.noTextRecognised),
                "text \(String(describing: text)) should not be treated as an authority")
        }
    }

    func testAProgramTooThinToCheckAgainstIsItsOwnAnswer() {
        // A poster or a one-page flyer has a real text layer holding a handful
        // of words. Treating that as an authority would flag every correct name.
        XCTAssertEqual(
            VisionTextLayer.availability(
                pdfPath: URL(fileURLWithPath: "/tmp/program.pdf"), pdfExists: true,
                currentPages: pages, bakedFingerprint: currentFingerprint,
                extractedText: "BLUDLINE Greenwich House"),
            .unavailable(.tooThinToBeAProgram))
    }

    func testARealProgramPageIsNotMistakenForATooThinOne() {
        let page = (1...12).map { "word\($0)" }.joined(separator: " ")
        guard case .ready = VisionTextLayer.availability(
            pdfPath: URL(fileURLWithPath: "/tmp/program.pdf"), pdfExists: true,
            currentPages: pages, bakedFingerprint: currentFingerprint,
            extractedText: page) else {
            return XCTFail("a real page was refused, so no program would ever be checked")
        }
    }

    func testTheThinProgramMessageSaysTheRestWasStillReviewed() {
        // The whole point of the fix: the spelling check stands down alone. A
        // message that only says it did not run reads as though nothing ran.
        XCTAssertTrue(VisionTextLayer.Unavailable.tooThinToBeAProgram
            .explanation.lowercased().contains("still reviewed"))
    }

    func testEveryFailureSaysWhatItMeansForTheSpellingCheck() {
        // A message naming only a state ("PDF stale") leaves Dan to work out
        // whether it mattered. Each has to say the check did not run.
        let all: [VisionTextLayer.Unavailable] = [
            .notBuiltYet, .missingOnDisk, .stale, .noTextRecognised,
            .tooThinToBeAProgram,
        ]
        var seen = Set<String>()
        for reason in all {
            let text = reason.explanation
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.lowercased().contains("check") || text.lowercased().contains("used"),
                          "\(reason) does not say what it means for the check: \(text)")
            XCTAssertTrue(seen.insert(text).inserted,
                          "\(reason) repeats another reason's wording, so the two are "
                          + "indistinguishable to the person reading it")
        }
    }
}
