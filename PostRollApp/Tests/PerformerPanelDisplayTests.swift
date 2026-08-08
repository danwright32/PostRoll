import XCTest

/// Issue #171: on a carousel day, tagging people belongs on the individual
/// photos, so the day-level performer panel steps back to a fallback for
/// anyone who can't be pinned to one frame. It must step back without
/// hiding picks that are already there, or a past event's day-level
/// selections would silently vanish behind a collapsed header.
final class PerformerPanelDisplayTests: XCTestCase {

    // MARK: - Starting state

    func testCollapsedOnACarouselDayWithNothingPickedYet() {
        XCTAssertFalse(
            PerformerPanelDisplay.startsExpanded(isCarouselDay: true, hasContent: false),
            "per-photo tagging is the primary control on carousel days, so the panel starts out of the way")
    }

    func testExpandedOnACarouselDayThatAlreadyHasPicks() {
        XCTAssertTrue(
            PerformerPanelDisplay.startsExpanded(isCarouselDay: true, hasContent: true),
            "existing day-level picks must stay visible, never hidden behind a collapsed header")
    }

    func testExpandedOnANonCarouselDayRegardless() {
        XCTAssertTrue(
            PerformerPanelDisplay.startsExpanded(isCarouselDay: false, hasContent: false),
            "single-photo days have no per-photo tagging, so the panel is still the only control")
        XCTAssertTrue(
            PerformerPanelDisplay.startsExpanded(isCarouselDay: false, hasContent: true))
    }

    // MARK: - Labelling

    func testCarouselDayTitleSaysItIsForTheWholePost() {
        XCTAssertEqual(PerformerPanelDisplay.title(isCarouselDay: true),
                       "PEOPLE ACROSS THE WHOLE POST")
    }

    func testNonCarouselDayKeepsTheOriginalTitle() {
        XCTAssertEqual(PerformerPanelDisplay.title(isCarouselDay: false),
                       "ASSIGN PERFORMERS")
    }

    func testCarouselDayExplainsWhenToUseThePanelInsteadOfPhotoTags() {
        let hint = PerformerPanelDisplay.hint(isCarouselDay: true)
        XCTAssertNotNil(hint, "the panel must say why it exists next to per-photo tagging")
        XCTAssertTrue(hint?.lowercased().contains("photo") ?? false,
                      "the hint has to point back at per-photo tagging to be worth showing")
    }

    // MARK: - Showing who the photos already credit

    /// People tagged on individual photos are credited by the caption
    /// automatically, but the panel showed only its own checkboxes, so there
    /// was no way to tell they had been counted. Silence there reads as "not
    /// tagged" and invites ticking everyone a second time.
    func testListsWhoThePhotosAlreadyCreditInPhotoOrder() {
        let tags = ["p2": ["Pete White"], "p1": ["Fermin Suero, Jr.", "@safa.wav"]]
        XCTAssertEqual(
            PerformerPanelDisplay.creditedFromPhotos(tags, photoOrder: ["p1", "p2", "p3"]),
            ["Fermin Suero, Jr.", "@safa.wav", "Pete White"],
            "reads in carousel order, not dictionary order")
    }

    func testSomeoneTaggedOnSeveralPhotosIsListedOnce() {
        let tags = ["p1": ["Ana Ruiz"], "p2": ["ana ruiz"], "p3": ["Ana Ruiz"]]
        XCTAssertEqual(
            PerformerPanelDisplay.creditedFromPhotos(tags, photoOrder: ["p1", "p2", "p3"]),
            ["Ana Ruiz"])
    }

    func testNothingTaggedOnAnyPhotoListsNobody() {
        XCTAssertTrue(
            PerformerPanelDisplay.creditedFromPhotos([:], photoOrder: ["p1"]).isEmpty)
        XCTAssertTrue(
            PerformerPanelDisplay.creditedFromPhotos(["p1": []], photoOrder: ["p1"]).isEmpty)
    }

    func testABlankTagIsNotListedAsACredit() {
        let tags = ["p1": ["  ", "Real Person"]]
        XCTAssertEqual(
            PerformerPanelDisplay.creditedFromPhotos(tags, photoOrder: ["p1"]),
            ["Real Person"])
    }

    func testTagsLeftOnARemovedPhotoAreNotListed() {
        let tags = ["gone": ["Ghost"], "p1": ["Real Person"]]
        XCTAssertEqual(
            PerformerPanelDisplay.creditedFromPhotos(tags, photoOrder: ["p1"]),
            ["Real Person"],
            "a stale entry must not claim someone is credited when their photo is gone")
    }

    func testNonCarouselDayShowsNoHint() {
        XCTAssertNil(PerformerPanelDisplay.hint(isCarouselDay: false),
                     "there is no per-photo tagging to contrast with on a single-photo day")
    }
}
