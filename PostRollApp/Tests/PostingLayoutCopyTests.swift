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
    func testTheScreensReadTheDerivedSentenceAndNoneCarriesTheOldOne() throws {
        // The control owns the sentence since #1007 moved the picker out of
        // ExportView. The positive half is asserted against the control; the
        // absence is asserted against EVERY screen that shows the layout,
        // because the defect this holds closed is a hand written sentence
        // anywhere near the picker, not in one file.
        let control = try String(contentsOf: viewFile("PostingLayoutControl.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(control.contains("PostingLayoutCopy.thisEvent("),
                      "the layout control does not call the derived sentence, so "
                      + "whatever it draws under the picker is maintained beside "
                      + "the presets")

        // The exact words that shipped for Opening. Named rather than described,
        // because this half exists to hold one specific defect closed.
        for name in Self.layoutScreens + ["PostingLayoutControl.swift"] {
            let source = try String(contentsOf: viewFile(name), encoding: .utf8)
            XCTAssertFalse(source.contains("Wednesday posts a 10 photo carousel"),
                           "\(name) carries Classic's hand written sentence, which is "
                           + "what Opening was printing")
            XCTAssertFalse(source.contains("each post a 4 photo carousel with a collage story"),
                           "\(name) carries Balanced's hand written sentence")
        }
    }

    /// Every screen that shows the layout's effect can change it (#1007).
    ///
    /// Asserted as a CONSTRUCTION, which a comment or an import cannot satisfy
    /// (L135, L103), and paired with the absence of the inline picker it
    /// replaced so a screen cannot end up carrying both.
    func testEveryScreenThatShowsTheLayoutUsesTheOneControl() throws {
        for name in Self.layoutScreens {
            let source = try String(contentsOf: viewFile(name), encoding: .utf8)
            XCTAssertTrue(source.contains("PostingLayoutControl("),
                          "\(name) shows what the posting layout produced and offers "
                          + "no way to change it")
            XCTAssertFalse(source.contains("Picker(\"Posting layout\""),
                           "\(name) builds its own layout picker beside the shared control")
        }
    }

    /// The control draws no progress indicator of its own (#1007).
    ///
    /// Every screen it sits on already draws the rebuild's progress, with
    /// elapsed time and an estimate. A spinner here stacks a second indicator
    /// directly above that one, for the same piece of work, carrying less
    /// information than the one below it. Two indistinguishable indicators for
    /// one job is the display #135 exists to prevent.
    ///
    /// Checked in both directions: no spinner, AND the reason still shown, so
    /// the fix cannot be satisfied by deleting the busy state altogether and
    /// leaving a dead control with nothing saying why (L178, L148).
    ///
    /// A whole file scan is honest here in a way it usually is not: this file
    /// is one control, and the rule is that it contains no progress indicator
    /// anywhere, not that one region of it does not.
    func testTheControlDrawsNoProgressIndicatorOfItsOwn() throws {
        let source = try String(contentsOf: viewFile("PostingLayoutControl.swift"),
                                encoding: .utf8)
        XCTAssertFalse(source.contains("ProgressView("),
                       "the layout control draws its own spinner above the screen's "
                       + "own progress line, which already carries elapsed time and "
                       + "an estimate this one does not")
        XCTAssertTrue(source.contains("cannot change yet"),
                      "the control is disabled while a rebuild runs and has to say "
                      + "why, or it is a dead control with no reason")
    }

    /// Named rather than derived, deliberately: what belongs here is a judgement
    /// about which screens SHOW the layout's effect, which no scan can make. It
    /// is three today, and a fourth is a decision somebody has to take.
    private static let layoutScreens = [
        "ExportView.swift", "CaptionReviewView.swift", "PhotoAssignmentView.swift",
    ]

    private func viewFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/\(name)")
    }

    // MARK: - What a switch will replace (#1007)

    private func scratchDefaults(_ preset: PostingPreset) -> UserDefaults {
        let d = UserDefaults(suiteName: "layout-control-\(UUID().uuidString)")!
        d.set(preset.rawValue, forKey: PostingPreset.storageKey)
        return d
    }

    private func eventWithPhotos(on days: [DayName], each: Int = 1) -> Event {
        var event = Event(name: "Show", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        for day in days {
            var pd = PostingDay(day: day)
            pd.photoPaths = (0..<each).map {
                URL(fileURLWithPath: "/\(day.rawValue)-\($0).jpg")
            }
            event.days[day.rawValue] = pd
        }
        return event
    }

    /// A switch that changes nothing is not a confirmation.
    ///
    /// A dialog that appears with nothing to say trains Dan to dismiss the one
    /// that matters, and a switch that moves no day takes nothing away.
    func testASwitchThatChangesNothingNeedsNoConfirmation() {
        XCTAssertNil(PostingLayoutSwitch.confirmation(
            from: .balanced, to: .opening, in: eventWithPhotos(on: [])))
    }

    /// The defect this replaced.
    ///
    /// The confirmation used to name every governed day with photos, so
    /// Balanced to Opening warned that Monday and Wednesday would be rebuilt
    /// when neither was going to move. A warning has to describe what will
    /// actually happen or it teaches the reader to stop reading it (L180, L36).
    func testTheConfirmationNamesOnlyTheDaysThatActuallyChange() throws {
        let event = eventWithPhotos(on: [.sunday, .monday, .wednesday], each: 8)
        let text = try XCTUnwrap(PostingLayoutSwitch.confirmation(
            from: .balanced, to: .opening, in: event))

        XCTAssertTrue(text.contains("Sunday"), text)
        XCTAssertFalse(text.contains("Monday"),
                       "Monday posts 4 photos under both layouts, so nothing about it "
                       + "changes: \(text)")
        XCTAssertFalse(text.contains("Wednesday"), text)
    }

    /// The two kinds of change cost different things, so they say different
    /// things (L11).
    func testARedrawSaysTheCaptionsAreUntouched() throws {
        let text = try XCTUnwrap(PostingLayoutSwitch.confirmation(
            from: .balanced, to: .opening, in: eventWithPhotos(on: [.sunday], each: 8)))
        XCTAssertTrue(text.contains("untouched"),
                      "a redraw leaves the caption alone and has to say so: \(text)")
    }

    func testARebuildSaysWhyTheCaptionHasToChange() throws {
        let text = try XCTUnwrap(PostingLayoutSwitch.confirmation(
            from: .balanced, to: .classic, in: eventWithPhotos(on: [.sunday], each: 8)))
        XCTAssertTrue(text.contains("different kind of post"),
                      "a rebuild costs a caption, and the reason is what makes that "
                      + "worth accepting: \(text)")
    }

    /// A day whose caption was typed over has real work in it.
    func testAnEditedCaptionOnARebuiltDayIsNamed() throws {
        var event = eventWithPhotos(on: [.sunday, .monday], each: 8)
        var sun = DayCaption()
        sun.generatedCaption = "what the model wrote"
        sun.caption = "what Dan wrote instead"
        var result = WeekGenerationResult()
        result.sunday = sun
        event.weekResult = result

        let text = try XCTUnwrap(PostingLayoutSwitch.confirmation(
            from: .balanced, to: .classic, in: event))
        XCTAssertTrue(text.contains("edits"), "the edited day has to be called out: \(text)")
        XCTAssertTrue(text.contains("Sunday"), text)
    }

    /// An older save has no record of what was generated, which is NOT evidence
    /// that Dan edited it.
    ///
    /// `generatedCaption` is empty until `stampOriginals` runs, so a raw
    /// comparison reads every unstamped day as edited and warns about work
    /// nobody did.
    func testAnUnstampedCaptionIsNotReportedAsEdited() throws {
        var event = eventWithPhotos(on: [.sunday], each: 8)
        var sun = DayCaption()
        sun.generatedCaption = ""              // never stamped
        sun.caption = "a caption from before the stamp existed"
        var result = WeekGenerationResult()
        result.sunday = sun
        event.weekResult = result

        let text = try XCTUnwrap(PostingLayoutSwitch.confirmation(
            from: .balanced, to: .classic, in: event))
        XCTAssertFalse(text.contains("edits"),
                       "an unstamped caption is unknown, not edited, and warning about "
                       + "edits nobody made is how a real warning stops being read: \(text)")
    }
}
