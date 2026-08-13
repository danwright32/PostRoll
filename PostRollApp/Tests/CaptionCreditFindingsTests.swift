import XCTest

/// #475: the caption's two handle rules are checked in Python and have to
/// reach Dan's screen, or the check may as well not have shipped.
///
/// That is the same failure BlogFindingsDecodeTests exists for: generate_blog
/// wrote `findings` for months while `BlogOutput` decoded no such key, so the
/// whole enforcement pass was invisible in the app (L46). The caption checks
/// are worse to lose, because one of the two says an @ handle in the caption
/// points at an account nobody offered, which posts a credit to a stranger.
///
/// Findings describe the caption as CHECKED. Dan edits captions constantly, so
/// a finding that keeps asserting itself after he has fixed it trains him to
/// ignore the panel; `findingsCaption` is what stops it outliving the fix.
final class CaptionCreditFindingsTests: XCTestCase {

    private let foreign = QualityFinding(
        code: "caption_foreign_handle",
        message: "This caption tags a handle that was not on the tag list.",
        detail: "@strangerhandle")
    private let missing = QualityFinding(
        code: "caption_missing_credit",
        message: "A credit that was asked for is not in this caption.",
        detail: "@dciny")

    // MARK: - decoding what Python sends

    func testFindingsDecodeFromThePythonPayload() throws {
        let json = Data("""
        {"caption": "At @lincolncenter with @strangerhandle.",
         "hashtags": [], "alt_texts": ["a"], "scene_labels": [null],
         "findings": [
           {"code": "caption_foreign_handle",
            "message": "This caption tags a handle that was not on the tag list.",
            "detail": "@strangerhandle"}
         ],
         "findings_caption": "At @lincolncenter with @strangerhandle."}
        """.utf8)

        let day = try JSONDecoder().decode(DayCaption.self, from: json)

        XCTAssertEqual(day.findings.count, 1)
        XCTAssertEqual(day.findings[0].code, "caption_foreign_handle")
        XCTAssertEqual(day.findings[0].detail, "@strangerhandle")
        XCTAssertEqual(day.findingsCaption, day.caption)
    }

    func testACaptionSavedBeforeFindingsExistedStillDecodes() throws {
        let json = Data(#"{"caption": "C", "hashtags": []}"#.utf8)

        let day = try JSONDecoder().decode(DayCaption.self, from: json)

        XCTAssertTrue(day.findings.isEmpty)
        XCTAssertEqual(day.findingsCaption, "")
    }

    func testFindingsSurviveASaveAndReload() throws {
        // They are stored on the event, so a finding has to still be on screen
        // after a relaunch, not only in the run that produced it.
        var day = DayCaption(caption: "C")
        day.applyFindings([foreign], checkedCaption: "C")

        let round = try JSONDecoder().decode(
            DayCaption.self, from: try JSONEncoder().encode(day))

        XCTAssertEqual(round.findings.first?.detail, "@strangerhandle")
        XCTAssertEqual(round.findingsCaption, "C")
    }

    // MARK: - what the panel says

    func testNoFindingsShowsNothing() {
        XCTAssertNil(DayCaption(caption: "C").findingsSummary)
    }

    func testOneFindingIsCountedInTheSingular() {
        var day = DayCaption(caption: "C")
        day.applyFindings([foreign], checkedCaption: "C")

        XCTAssertEqual(day.findingsSummary, "1 check to fix")
    }

    func testSeveralFindingsAreCounted() {
        var day = DayCaption(caption: "C")
        day.applyFindings([foreign, missing], checkedCaption: "C")

        XCTAssertEqual(day.findingsSummary, "2 checks to fix")
    }

    // MARK: - staleness once Dan edits the caption

    func testFindingsAreCurrentWhileTheCaptionIsUntouched() {
        var day = DayCaption(caption: "C")
        day.applyFindings([foreign], checkedCaption: "C")

        XCTAssertFalse(day.findingsAreStale)
    }

    func testFindingsGoStaleOnceTheCaptionIsEdited() {
        var day = DayCaption(caption: "C")
        day.applyFindings([foreign], checkedCaption: "C")
        day.caption = "Dan removed the wrong handle"

        XCTAssertTrue(day.findingsAreStale,
                      "the checks ran against the generated caption, not this text")
        XCTAssertEqual(day.findingsSummary, "1 check against the original caption")
    }

    func testACaptionSavedBeforeTheCheckedTextWasRecordedIsNotTreatedAsStale() {
        // No record of what was checked is not evidence Dan changed anything,
        // and greying out every older event's findings would be worse.
        var day = DayCaption(caption: "C")
        day.findings = [foreign]

        XCTAssertFalse(day.findingsAreStale)
    }

    // MARK: - the grouping both panels share

    func testRepeatsOfOneCheckCollapseUnderOneHeading() {
        let second = QualityFinding(code: "caption_missing_credit",
                                    message: "A credit that was asked for is not in this caption.",
                                    detail: "Jordan Langworthy")
        let groups = FindingsDisplay.grouped(findings: [missing, foreign, second])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].details, ["@dciny", "Jordan Langworthy"])
        XCTAssertEqual(groups.map(\.code),
                       ["caption_missing_credit", "caption_foreign_handle"])
    }
}
