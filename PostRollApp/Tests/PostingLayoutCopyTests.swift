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

    // ── the source-scanning half has moved off the app build (#1089) ────
    //
    // Six rules here read nothing but Swift source, five of them carrying a
    // registry entry at about 29 seconds of rebuilding each: which screens
    // carry the one control, whether they still read the derived sentence,
    // whether the control draws a spinner of its own, whether it asks the plan
    // what to rebuild, whether a refused redraw claim stops the switch, and
    // whether the stale days are shown with a way to act on them. They live in
    // tests/test_the_layout_control_is_the_one_way_to_switch.py now, and every
    // registered one was re-proved KILLED against the Python rule before it was
    // deleted.
    //
    // The sixth carried no entry and moved anyway, because it reads the same
    // file the same way: leaving it would have kept this class and its helper
    // paying a build to re-prove nothing.
    //
    // What stays is what a text scan cannot do: these tests call
    // PostingLayoutCopy and PostingLayoutSwitch and check what they actually
    // produce. Making no drawing call is not the same as being text-only,
    // which is the correction #1089's own measurement needed.

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

    // MARK: - What a switch will replace (#1007)

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

    // MARK: - The control actually applies the plan (#1010)

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

    // MARK: - A day the switch did not finish (#1010)

    /// A failed redraw leaves the event on the new layout with one day still
    /// drawn for the old one. The control that made the switch is where that
    /// has to be said, because it is the only screen showing the layout the day
    /// disagrees with.
    func testTheStaleSentenceNamesTheDayAndReadsAsOneThingLeftOver() {
        XCTAssertEqual(PostingLayoutCopy.stale([.sunday]),
                       "Sunday still shows the previous layout.")
        XCTAssertEqual(PostingLayoutCopy.stale([.sunday, .monday]),
                       "Sunday and Monday still show the previous layout.")
    }

    /// Nothing left over, nothing said. A notice that appears when there is no
    /// problem teaches Dan to stop reading the one that matters (L36).
    func testNothingStaleSaysNothing() {
        XCTAssertNil(PostingLayoutCopy.stale([]))
        XCTAssertNil(PostingLayoutCopy.redrawAction([]))
    }

    /// The way out, named as the action it performs.
    ///
    /// It has to be a control of its own: the export refuses a stale day, and
    /// picking the layout that is already selected fires nothing at all, so
    /// without this the only route back is switching to a third layout and
    /// returning, which nothing on screen suggests (L109, L126).
    func testTheRemedyIsOfferedAsAnAction() {
        XCTAssertEqual(PostingLayoutCopy.redrawAction([.sunday]), "Redraw Sunday")
        XCTAssertEqual(PostingLayoutCopy.redrawAction([.sunday, .monday]),
                       "Redraw Sunday and Monday")
    }

}
