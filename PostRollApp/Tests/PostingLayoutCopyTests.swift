import XCTest
import Foundation

/// The sentence under the per-event posting layout picker (#1007).
///
/// It was written as a two-way ternary over THREE presets
/// (`ExportView.swift:347`), so selecting Opening printed Classic's sentence:
/// "Sunday and Monday post a single photo; Wednesday posts a 10 photo
/// carousel". `PostingPreset.explanation` has existed since #900 for exactly
/// this reason and `SettingsView` already reads it, so the Settings copy stayed
/// correct while the Export copy went wrong. A list that must mirror another
/// source is derived from it, never maintained beside it (L41).
///
/// These assert the RULE (the sentence carries the preset's own explanation)
/// rather than the exact rendering, so a legitimate rewording of an explanation
/// does not fail them (L103). The one exception is
/// `testOpeningIsNotDescribedAsClassic`, which names the specific wrong words
/// that shipped, because that is the defect this file exists to hold closed.
final class PostingLayoutCopyTests: XCTestCase {

    func testEveryPresetsSentenceCarriesItsOwnExplanation() {
        for preset in PostingPreset.allCases {
            let sentence = PostingLayoutCopy.thisEvent(preset)
            XCTAssertTrue(sentence.contains(preset.explanation),
                          "\(preset.rawValue) is described by a sentence that does not "
                          + "carry its own explanation: \(sentence)")
        }
    }

    /// The shipped defect, named exactly.
    func testOpeningIsNotDescribedAsClassic() {
        let opening = PostingLayoutCopy.thisEvent(.opening)
        XCTAssertFalse(opening.contains("single photo"),
                       "Opening posts a 7 photo carousel on Sunday, so a sentence "
                       + "saying it posts a single photo is Classic's: \(opening)")
        XCTAssertFalse(opening.contains("10 photo"),
                       "no Opening day posts 10 photos: \(opening)")
        XCTAssertTrue(opening.contains("7"),
                      "the count that makes Opening worth choosing has to be in "
                      + "the sentence: \(opening)")
    }

    /// A ternary can only produce two answers for three inputs, so the failure
    /// shape is two presets sharing one sentence. Asserted directly, because a
    /// future rewrite could reintroduce it without reintroducing the same words.
    func testNoTwoPresetsShareASentence() {
        let sentences = PostingPreset.allCases.map { PostingLayoutCopy.thisEvent($0) }
        XCTAssertEqual(Set(sentences).count, PostingPreset.allCases.count,
                       "two layouts are described by the same sentence: \(sentences)")
    }

    /// The sentence is about THIS event, not about the app wide default, which
    /// is what the Settings copy describes. Both are shown, and a reader has to
    /// be able to tell which one they are looking at.
    func testTheSentenceSaysItIsAboutThisEvent() {
        for preset in PostingPreset.allCases {
            XCTAssertTrue(PostingLayoutCopy.thisEvent(preset).hasPrefix("This event:"),
                          "\(preset.rawValue) does not say whose layout it is describing")
        }
    }

    // MARK: - The screen actually reads it

    /// A derived sentence nothing calls leaves the hand written one on screen,
    /// so the tests above would pass while the defect shipped unchanged.
    ///
    /// Checked in BOTH directions. The positive half alone is satisfied by a
    /// call added beside the ternary rather than in place of it; the negative
    /// half alone is satisfied by deleting the sentence altogether and showing
    /// nothing (L178, L283). Together they say the old copy is gone and the
    /// derived one took its place.
    func testExportViewReadsTheDerivedSentenceAndNoLongerCarriesTheOldOne() throws {
        let source = try String(contentsOf: exportView, encoding: .utf8)

        XCTAssertTrue(source.contains("PostingLayoutCopy.thisEvent("),
                      "ExportView does not call the derived sentence, so whatever it "
                      + "draws under the picker is maintained beside the presets")

        // The exact words that shipped for Opening. Named rather than described,
        // because this half exists to hold one specific defect closed.
        XCTAssertFalse(source.contains("Wednesday posts a 10 photo carousel"),
                       "ExportView still carries Classic's hand written sentence, which "
                       + "is what Opening was printing")
        XCTAssertFalse(source.contains("each post a 4 photo carousel with a collage story"),
                       "ExportView still carries Balanced's hand written sentence")
    }

    private var exportView: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/ExportView.swift")
    }
}
