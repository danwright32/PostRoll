import XCTest

/// #405: every message that stitches an outside reason into our own prose,
/// checked against the punctuation that reason really carries.
///
/// A sweep of `Sources` examined 335 candidate sites and found eight of this
/// shape beyond the four already routed through `Sentence`. These pin the five
/// that reach Dan, using the two shapes the producers actually emit rather than
/// a convenient one:
///
///   ends in a stop      Cocoa file-system errors, Foundation decoding errors,
///                       and Python's own sentence-shaped messages
///   ends in nothing     a bare `str(e)`, a library error, and every message from
///                       postroll/media/missing_media.py
///
/// The rule under test is the same everywhere: exactly one stop between the
/// reason and whatever we say next, and never a stop appended to an ellipsis.
final class InterpolatedReasonTests: XCTestCase {

    /// No sentence may run into the next, and none may stutter.
    private func assertReadsCleanly(_ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(message.contains(".."), "double stop in: \(message)",
                       file: file, line: line)
        XCTAssertFalse(message.contains("\u{2026}."), "stop after an ellipsis in: \(message)",
                       file: file, line: line)
        XCTAssertFalse(message.contains(" ."), "orphaned stop in: \(message)",
                       file: file, line: line)
    }

    // MARK: - The halt banner on caption review

    /// `stoppedReason` has two producers in generate_week.py that punctuate
    /// differently: the cap path writes a finished sentence, the two fatal paths
    /// write a bare `str(e)`.
    func testTheHaltBannerReadsCleanlyForBothProducers() {
        let finished = HaltedWeek(
            reason: "Claude usage limit reached, resets at 3pm. Everything generated so far "
                  + "is saved.",
            finishedDays: [.sunday, .tuesday])
        assertReadsCleanly(finished.reviewBanner)

        // The shape the fatal paths write, which is where the words used to
        // collide: "connection reset by peer Sunday, Tuesday are saved."
        let bare = HaltedWeek(reason: "connection reset by peer",
                              finishedDays: [.sunday, .tuesday])
        assertReadsCleanly(bare.reviewBanner)
        XCTAssertTrue(bare.reviewBanner.contains("peer. Sunday"),
                      bare.reviewBanner)
    }

    func testTheHaltBannerReadsCleanlyWhenNothingFinished() {
        assertReadsCleanly(HaltedWeek(reason: "exit 1", finishedDays: []).reviewBanner)
    }

    // MARK: - The generation failure banner

    /// The one that fired every time: a stderr line over 120 characters is
    /// truncated with an ellipsis, and a stop was then appended to it.
    func testALongStderrLineDoesNotGetAStopAfterItsEllipsis() {
        let long = "RuntimeError: " + String(repeating: "something went wrong ", count: 12)
        let message = PythonBridgeError.scriptFailed(exitCode: 1, stderr: long)
            .errorDescription ?? ""

        XCTAssertTrue(message.contains("\u{2026}"), "the preview should still be truncated")
        assertReadsCleanly(message)
    }

    func testAnUnrecognisedStderrSentenceKeepsExactlyOneStop() {
        let message = PythonBridgeError.scriptFailed(
            exitCode: 1, stderr: "ValueError: the photo list was empty.")
            .errorDescription ?? ""
        assertReadsCleanly(message)
        XCTAssertTrue(message.contains("empty. Check"), message)
    }

    func testABareExceptionReprGetsTheStopItLacks() {
        let message = PythonBridgeError.scriptFailed(
            exitCode: 1, stderr: "KeyError: 'performers'")
            .errorDescription ?? ""
        assertReadsCleanly(message)
        XCTAssertTrue(message.contains("'performers'. Check"), message)
    }

    // MARK: - The import failure notice

    /// A Cocoa copy error is a whole sentence ending in a stop, which is the shape
    /// the existing test's fixture did not have.
    func testAnImportFailureReadsCleanlyWithARealCocoaMessage() {
        let failure = AppPaths.ImportCopyFailure(
            fileName: "DSC_4417.jpg",
            message: "\u{201C}DSC_4417.jpg\u{201D} couldn't be copied to \u{201C}photos\u{201D} "
                   + "because an item with the same name already exists.")
        let message = ImportFailureText.message([failure])

        assertReadsCleanly(message)
        XCTAssertTrue(message.contains("already exists. Linking"), message)
    }

    func testAnImportFailureReadsCleanlyWithAnUnterminatedMessage() {
        let failure = AppPaths.ImportCopyFailure(fileName: "DSC_4417.jpg",
                                                 message: "no such file")
        assertReadsCleanly(ImportFailureText.message([failure]))
    }

    // MARK: - The export warning

    /// Confirmed at postroll/media/missing_media.py: these carry no terminator.
    func testTheExportWarningClosesEachReasonBeforeItsClosingSentence() throws {
        let message = try XCTUnwrap(MediaErrorSummary.warningSentence([
            "thursday": "Thursday black and white photo not found: /photos/bw.jpg",
        ]))
        assertReadsCleanly(message)
        XCTAssertTrue(message.contains("bw.jpg."), message)
    }

    func testTheExportWarningReadsCleanlyForSeveralDays() throws {
        let message = try XCTUnwrap(MediaErrorSummary.warningSentence([
            "thursday": "Thursday reel audio not found: /audio/a.mp3",
            "tuesday": "Tuesday black and white photo not found: /photos/bw.jpg",
        ]))
        assertReadsCleanly(message)
    }

    // MARK: - The unreadable store notice

    func testTheUnreadableStoreNoticeReadsCleanly() {
        struct Stopped: LocalizedError {
            var errorDescription: String? { "The file isn\u{2019}t in the correct format." }
        }
        struct Unstopped: LocalizedError {
            var errorDescription: String? { "unexpected end of file" }
        }
        for error in [Stopped() as Error, Unstopped() as Error] {
            let message = EventStore.unreadableMessage(error)
            assertReadsCleanly(message)
            XCTAssertTrue(message.contains("Nothing was changed or deleted"), message)
        }
    }

    // MARK: - The one helper, not four

    /// The two bespoke copies of this rule are gone. Both had holes `Sentence`
    /// does not, and a rule with four implementations has four behaviours.
    func testNoScreenKeepsItsOwnCopyOfTheRule() throws {
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Services")

        var offenders: [String] = []
        for url in try FileManager.default.contentsOfDirectory(
            at: services, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "swift" && $0.lastPathComponent != "Sentence.swift" }) {
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") }
                .joined(separator: "\n")
            // The tell of a hand-rolled copy: deciding whether to append a stop by
            // looking at the last character.
            if code.contains("\".?!\".contains") || code.contains("charactersIn: \".\"") {
                offenders.append(url.lastPathComponent)
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            These files still decide sentence punctuation themselves instead of going \
            through Sentence, so the rule has more than one behaviour:

            \(offenders.joined(separator: "\n"))
            """)
    }
}
