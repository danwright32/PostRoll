import XCTest

/// #664: say on the window when the code folder is not on a clean main.
///
/// PostRoll generates with the code in the checkout rather than with anything
/// bundled, so while a session is mid branch, or has left uncommitted edits, a
/// generation runs that code and looks entirely normal. #661 records which
/// commit ran, which answers the question afterwards; this says it before Dan
/// presses generate.
///
/// The copy is the feature. Every sentence here is read cold, in the state that
/// produces it (L21), and none of it may use a word from git's vocabulary that
/// Dan has no reason to know.
final class CheckoutNoticeTests: XCTestCase {

    func testACleanMainSaysNothingAtAll() {
        // Every ordinary day. A notice that appeared when nothing was wrong is
        // one that gets ignored when something is (L36).
        XCTAssertNil(CheckoutNotice.message(
            for: .known(commit: "1a2b3c4", branch: "main", dirty: false)))
    }

    func testABranchIsNamedSoItCanBeRecognised() {
        let message = try? XCTUnwrap(CheckoutNotice.message(
            for: .known(commit: "1a2b3c4", branch: "wip/pinned-text-shaper", dirty: false)))

        XCTAssertTrue(message?.contains("wip/pinned-text-shaper") == true, message ?? "nil")
        XCTAssertTrue(message?.contains("main") == true, message ?? "nil")
    }

    func testUncommittedWorkOnMainIsStillWorthSaying() {
        // The branch is right and the code still is not what shipped.
        let message = try? XCTUnwrap(CheckoutNotice.message(
            for: .known(commit: "1a2b3c4", branch: "main", dirty: true)))

        XCTAssertTrue(message?.contains("not been saved") == true
                      || message?.contains("not been committed") == true, message ?? "nil")
    }

    func testBothAtOnceSaysBoth() {
        // The commonest state during a working session, and a sentence naming
        // only one of them would leave the other unaccounted for.
        let message = try? XCTUnwrap(CheckoutNotice.message(
            for: .known(commit: "1a2b3c4", branch: "wip/fonts", dirty: true)))

        XCTAssertTrue(message?.contains("wip/fonts") == true, message ?? "nil")
        XCTAssertTrue(message?.contains("not been saved") == true
                      || message?.contains("not been committed") == true, message ?? "nil")
    }

    func testACheckoutOnNoBranchIsSaidInWordsRatherThanNamedAsOne() {
        // A detached checkout has no branch name, and phrasing it as one would
        // produce a sentence naming a branch that does not exist.
        let message = try? XCTUnwrap(CheckoutNotice.message(
            for: .known(commit: "1a2b3c4",
                        branch: CheckoutRevision.detachedBranch, dirty: false)))

        XCTAssertNotNil(message)
        XCTAssertFalse(message?.contains("called") == true, message ?? "nil")
        XCTAssertFalse(message?.contains("HEAD") == true,
                       "git's word for it means nothing to the person reading")
    }

    func testAnUnreadableCheckoutIsLoggedRatherThanPutOnTheWindow() {
        // Following the build freshness rule beside it: a notice that cannot
        // say anything actionable is one Dan learns to ignore, and the real
        // warning goes with it. The reason still reaches the log.
        XCTAssertNil(CheckoutNotice.message(
            for: .unknown(reason: "git could not name a branch")))
    }

    func testTheNoticeCarriesNoGitVocabulary() {
        // Read cold: Dan does not use a terminal. Words like commit, HEAD,
        // repository and dirty describe the state correctly and tell him
        // nothing.
        let states: [CheckoutRevision.Reading] = [
            .known(commit: "1a2b3c4", branch: "wip/fonts", dirty: true),
            .known(commit: "1a2b3c4", branch: "main", dirty: true),
            .known(commit: "1a2b3c4", branch: CheckoutRevision.detachedBranch, dirty: false),
        ]

        for state in states {
            let message = CheckoutNotice.message(for: state) ?? ""
            for word in ["HEAD", "repository", "dirty", "commit", "git"] {
                XCTAssertFalse(message.lowercased().contains(word.lowercased()),
                               "\(word) appears in: \(message)")
            }
        }
    }

    func testTheNoticeSaysWhatItMeansForWhatHeIsAboutToDo() {
        // A message that names a condition and stops leaves the person to work
        // out whether it matters (L80). What it costs him is the point: the
        // reels he makes in the next few minutes come out of that code.
        let message = CheckoutNotice.message(
            for: .known(commit: "1a2b3c4", branch: "wip/fonts", dirty: false)) ?? ""

        XCTAssertTrue(message.lowercased().contains("generate"), message)
    }

    // MARK: - Which half it is actually true of (#692)

    func testTheNoticeDoesNotClaimTheWholeOfGeneration() {
        // "Anything you generate now runs that code" is true of the pipeline
        // and false of the parts the app draws itself. The banner is read at
        // the exact moment its claim is being relied on: switching to a branch
        // to test a collage change and reading that sentence says the change is
        // under test when it is not, and the output then looks like the branch
        // failing to work.
        let message = CheckoutNotice.message(
            for: .known(commit: "1a2b3c4", branch: "wip/collage", dirty: false)) ?? ""

        XCTAssertFalse(message.lowercased().contains("anything you generate"),
                       "the banner still speaks for all of generation: \(message)")
    }

    func testTheNoticeNamesBothHalvesAndWhatToDoAboutTheFrozenOne() {
        // Naming only the live half would be just as misleading in the other
        // direction: the reader has to know a Swift side change still needs a
        // rebuild, which is the actionable part (L80).
        let message = CheckoutNotice.message(
            for: .known(commit: "1a2b3c4", branch: "wip/collage", dirty: false)) ?? ""

        XCTAssertTrue(message.lowercased().contains("captions"),
                      "the live half is not named: \(message)")
        XCTAssertTrue(message.lowercased().contains("collage"),
                      "the frozen half is not named: \(message)")
        XCTAssertTrue(message.lowercased().contains("rebuild"),
                      "nothing says what makes the frozen half current: \(message)")
    }
}
