import XCTest

/// A name typed into a handle field never becomes a caption mention (#899).
///
/// On Battery Dance Festival, Thursday, one company's row carried its own
/// display name in the handle field:
///
///     'DPR Dance' -> handle: 'DPR Dance'
///
/// Nothing checked that a handle was SHAPED like a handle, so it travelled the
/// whole way: `isRealHandle` is a blacklist of seven sentinel words and passed
/// it, `CaptionCreditInputs` emitted `@DPR Dance` into `tag_handles` as a
/// handle to mention, the model obeyed, and the caption went to review naming
/// an account that resolves to whoever owns `@DPR`.
///
/// The shape rule itself lives in `CaptionBlocks.isHandleShaped` and is pinned
/// against Python by `HandleShapeTests`. This file is about what the app DOES
/// with a value that fails it.
final class HandleFieldShapeTests: XCTestCase {

    private func performer(_ name: String, _ handle: String) -> Performer {
        Performer(id: UUID(), name: name, role: "", handle: handle)
    }

    // MARK: - the predicate every list already shares

    func testANameInTheHandleFieldIsNotARealHandle() {
        XCTAssertFalse(PythonBridge.isRealHandle("DPR Dance"))
    }

    func testARealHandleIsStillOne() {
        XCTAssertTrue(PythonBridge.isRealHandle("@dpr.dance"))
    }

    func testASentinelIsStillRejectedForItsOwnReason() {
        XCTAssertFalse(PythonBridge.isRealHandle("unknown"))
    }

    // MARK: - what reaches the caption

    func testACompanyWithANameInItsHandleFieldIsCreditedByName() throws {
        var event = Event(name: "E", org: "", venue: "",
                          date: Date(), shootType: .fullShow)
        var ocr = OCRResult()
        let company = performer("DPR Dance", "DPR Dance")
        ocr.performers = [company]
        event.ocrResult = ocr
        var day = PostingDay(day: .sunday)
        day.selectedPerformerIDs = [company.id]

        let credits = CaptionCreditInputs.forDay(day, event: event)

        XCTAssertFalse(credits.handles.contains { $0.contains("DPR Dance") },
                       "the display name was handed to the caption prompt as a "
                       + "handle to mention, which is how it reached Instagram")
        XCTAssertTrue(credits.names.contains("DPR Dance"),
                      "no handle offered means credit by name, which is what "
                      + "should have happened for this company from the start")
    }

    func testAWellFormedHandleIsStillMentioned() throws {
        var event = Event(name: "E", org: "", venue: "",
                          date: Date(), shootType: .fullShow)
        var ocr = OCRResult()
        let company = performer("DPR Dance", "@dpr.dance")
        ocr.performers = [company]
        event.ocrResult = ocr
        var day = PostingDay(day: .sunday)
        day.selectedPerformerIDs = [company.id]

        let credits = CaptionCreditInputs.forDay(day, event: event)

        XCTAssertTrue(credits.handles.contains("@dpr.dance"))
        XCTAssertFalse(credits.names.contains("DPR Dance"))
    }

    func testProseInTheEventHandlesFieldBecomesTheAccountsInsideIt() {
        var event = Event(name: "E", org: "", venue: "",
                          date: Date(), shootType: .fullShow)
        // Exactly what postroll.handlebook.org.v1 holds today for two events.
        event.eventHandles = "@bludlineodyssey presented by @matchbookfestival"

        let credits = CaptionCreditInputs.forDay(nil, event: event)

        XCTAssertEqual(credits.handles.map { CaptionBlocks.bareUsername($0) },
                       ["bludlineodyssey", "matchbookfestival"],
                       "the whole sentence was passed through as one handle, "
                       + "so the caption was asked to mention prose")
    }

    func testACommaSeparatedEventFieldStillWorks() {
        var event = Event(name: "E", org: "", venue: "",
                          date: Date(), shootType: .fullShow)
        event.eventHandles = "dciny, carnegiehall"

        let credits = CaptionCreditInputs.forDay(nil, event: event)

        XCTAssertEqual(credits.handles.map { CaptionBlocks.bareUsername($0) },
                       ["dciny", "carnegiehall"])
    }

    // MARK: - the book neither learns nor replays one

    /// Read out of the STORE, never through `handle(forPerformer:)`.
    ///
    /// The book guards this at the write AND at the read, and each masks the
    /// other: a version of this asserting the book ANSWERS nothing passed with
    /// the write guard deliberately removed, so it was proving the read and
    /// reporting the write (measured by `tools/check_guards.py`, which said the
    /// guard survived its mutation).
    private func stored(in defaults: UserDefaults, forName key: String) -> String? {
        (defaults.dictionary(forKey: "postroll.handlebook.performer.v1")
            as? [String: String])?[key]
    }

    func testTheBookRefusesToLearnANameAsAHandle() throws {
        let defaults = try scratchDefaults()
        let book = HandleBook(defaults: defaults)

        book.recordAll(performers: [performer("DPR Dance", "DPR Dance")])

        XCTAssertNil(stored(in: defaults, forName: "dpr dance"),
                     "the book learned the display name against that name, so "
                     + "it auto fills into every future event carrying it")
    }

    func testTheBookStillLearnsARealHandle() throws {
        let defaults = try scratchDefaults()
        let book = HandleBook(defaults: defaults)

        book.recordAll(performers: [performer("DPR Dance", "@dpr.dance")])

        XCTAssertEqual(stored(in: defaults, forName: "dpr dance"), "@dpr.dance")
        XCTAssertEqual(book.handle(forPerformer: "DPR Dance"), "@dpr.dance")
    }

    func testOneRowRecordedOnItsOwnIsRefusedTheSameWay() throws {
        let defaults = try scratchDefaults()
        let book = HandleBook(defaults: defaults)

        book.record(performer: "DPR Dance", handle: "DPR Dance")

        XCTAssertNil(stored(in: defaults, forName: "dpr dance"))
    }

    func testARefusedWriteDoesNotTakeAwayAGoodHandleAlreadyThere() throws {
        let defaults = try scratchDefaults()
        defaults.set(["dpr dance": "@dpr.dance"],
                     forKey: "postroll.handlebook.performer.v1")
        let book = HandleBook(defaults: defaults)

        book.record(performer: "DPR Dance", handle: "DPR Dance")

        XCTAssertEqual(stored(in: defaults, forName: "dpr dance"), "@dpr.dance",
                       "a typo on the way past threw away a handle that was "
                       + "already correct (L5)")
    }

    /// The entries already stored. Planted directly, because the writers refuse
    /// to produce one now and a book written by an older build is not something
    /// this one can assume the shape of.
    func testAStoredNameIsNotAutoFilledIntoAFutureEvent() throws {
        let defaults = try scratchDefaults()
        defaults.set(["dpr dance": "DPR Dance"],
                     forKey: "postroll.handlebook.performer.v1")
        let book = HandleBook(defaults: defaults)

        var performers = [performer("DPR Dance", "")]
        let supplied = book.autoFill(performers: &performers)

        XCTAssertEqual(performers[0].handle, "",
                       "the value cached before the shape check was replayed "
                       + "into the field, so the defect recurs on every event")
        XCTAssertTrue(supplied.isEmpty)
    }

    func testAStoredHandleIsStillAutoFilled() throws {
        let defaults = try scratchDefaults()
        defaults.set(["dpr dance": "@dpr.dance"],
                     forKey: "postroll.handlebook.performer.v1")
        let book = HandleBook(defaults: defaults)

        var performers = [performer("DPR Dance", "")]
        book.autoFill(performers: &performers)

        XCTAssertEqual(performers[0].handle, "@dpr.dance")
    }

    // MARK: - the row says so where it is typed

    func testTheRowNamesTheProblemUnderTheField() {
        let notes = PerformerRowNotes.lines(duplicate: nil, isGuessed: false,
                                            handle: "DPR Dance")

        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].isProblem)
        XCTAssertTrue(notes[0].text.lowercased().contains("handle"), notes[0].text)
    }

    func testARealHandleDrawsNoNote() {
        XCTAssertTrue(PerformerRowNotes.lines(duplicate: nil, isGuessed: false,
                                              handle: "@dpr.dance").isEmpty)
    }

    func testAnEmptyFieldDrawsNoNote() {
        XCTAssertTrue(PerformerRowNotes.lines(duplicate: nil, isGuessed: false,
                                              handle: "").isEmpty)
    }

    func testASentinelDrawsNoNote() {
        XCTAssertTrue(PerformerRowNotes.lines(duplicate: nil, isGuessed: false,
                                              handle: "unknown").isEmpty,
                      "a sentinel is a recorded answer, not a malformed one")
    }

    /// A book on its own storage. A test that recorded handles for real would
    /// edit the book Dan has built up across every event he has shot (L2).
    private func scratchDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "handle-shape-\(UUID().uuidString)"))
    }
}
