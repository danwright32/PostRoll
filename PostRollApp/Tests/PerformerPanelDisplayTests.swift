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

    func testNonCarouselDayShowsNoHint() {
        XCTAssertNil(PerformerPanelDisplay.hint(isCarouselDay: false),
                     "there is no per-photo tagging to contrast with on a single-photo day")
    }
}
