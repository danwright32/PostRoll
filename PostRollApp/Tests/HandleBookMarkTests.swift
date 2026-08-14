import XCTest

/// #459: a handle guessed from a name match is not a handle read off the
/// programme.
///
/// The handle book is keyed on a normalised NAME and is global across every org
/// and every event, so the next performer who happens to share a name inherits
/// the last one's Instagram. That value landed in the field looking exactly
/// like one this programme printed, which is the silent substitution L75 is
/// about: when identifying WHO something refers to is a guess, it must not be
/// presented as a fact. The web lookup in the same screen already presents its
/// finds as suggestions, with a confidence, a verify link and an Accept.
@MainActor
final class HandleBookMarkTests: XCTestCase {

    // MARK: - What the book reports back

    private func performer(_ name: String, handle: String = "") -> Performer {
        Performer(name: name, role: "Soloist", handle: handle)
    }

    /// A scratch book, never the shared one: writing that would edit the
    /// handles Dan has built up for real (L2).
    private func book() -> HandleBook {
        HandleBook(defaults: UserDefaults(suiteName: "handle-book-\(UUID().uuidString)")!)
    }

    func testItSaysWhichHandlesItFilledIn() {
        let book = book()
        book.record(performer: "Sarah Chen", handle: "@sarahchen")
        var performers = [performer("Sarah Chen")]

        let supplied = book.autoFill(performers: &performers)

        XCTAssertEqual(performers[0].handle, "@sarahchen")
        XCTAssertEqual(supplied[performers[0].id], "@sarahchen")
    }

    /// A handle the programme itself carried is not a guess and must not be
    /// marked as one.
    func testAHandleAlreadyOnThePerformerIsNotReportedAsAGuess() {
        let book = book()
        book.record(performer: "Sarah Chen", handle: "@sarahchen")
        var performers = [performer("Sarah Chen", handle: "@therealsarah")]

        let supplied = book.autoFill(performers: &performers)

        XCTAssertEqual(performers[0].handle, "@therealsarah", "the book overwrote the programme")
        XCTAssertTrue(supplied.isEmpty)
    }

    func testAPerformerTheBookHasNeverSeenIsNotReported() {
        var performers = [performer("Someone New")]

        XCTAssertTrue(book().autoFill(performers: &performers).isEmpty)
    }

    // MARK: - How long the mark stands

    func testAHandleStillAsTheBookLeftItIsMarked() {
        XCTAssertTrue(HandleBookMark.isFromTheBook(supplied: "@sarahchen",
                                                   current: "@sarahchen"))
    }

    /// Once Dan has typed over it, it is his answer rather than a guess, and a
    /// marker still saying otherwise would be telling him something untrue.
    func testEditingItClearsTheMark() {
        XCTAssertFalse(HandleBookMark.isFromTheBook(supplied: "@sarahchen",
                                                    current: "@therealsarahchen"))
    }

    func testClearingItClearsTheMark() {
        XCTAssertFalse(HandleBookMark.isFromTheBook(supplied: "@sarahchen", current: ""))
    }

    func testAHandleTheBookNeverTouchedIsNotMarked() {
        XCTAssertFalse(HandleBookMark.isFromTheBook(supplied: nil, current: "@sarahchen"))
    }

    // MARK: - What it says

    func testTheMarkSaysItWasMatchedOnNameAlone() {
        XCTAssertTrue(HandleBookMark.note.lowercased().contains("name"),
                      HandleBookMark.note)
    }

    /// The risk is specific, so the explanation has to be: it is a name match
    /// from a different event, not a person match.
    func testTheExplanationSaysItCameFromAnotherEvent() {
        let text = HandleBookMark.explanation.lowercased()

        XCTAssertTrue(text.contains("earlier event"), HandleBookMark.explanation)
        XCTAssertTrue(text.contains("check"), HandleBookMark.explanation)
    }
}
