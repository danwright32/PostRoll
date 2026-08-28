import XCTest

/// The handles the app has learned can be read and corrected (#903).
///
/// The books learn a handle per performer name, per organisation and per venue,
/// and auto fill it into every future event with that name. Nothing anywhere
/// showed what they held. A wrong entry could only be found by opening an event
/// and noticing the wrong value in a field, and only corrected by editing that
/// row and advancing past Review.
///
/// On 2026-08-27 the correct handle for a company had to be read out of the
/// preferences plist by hand to answer "what does the app think this is".
///
/// All three books, decided by Dan on 2026-08-27. The issue named performers
/// because that is where the problem was noticed; the ORG book is where the
/// worst data actually is, holding two entries that are prose rather than a
/// handle.
final class HandleBookEntriesTests: XCTestCase {

    private func book() throws -> (HandleBook, UserDefaults) {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "handle-entries-\(UUID().uuidString)"))
        return (HandleBook(defaults: defaults), defaults)
    }

    // MARK: - reading what is there

    func testAnEmptyBookListsNothing() throws {
        let (book, _) = try book()
        for kind in HandleBook.Kind.allCases {
            XCTAssertEqual(book.entries(in: kind), [])
        }
    }

    func testEveryBookIsReadable() throws {
        let (book, defaults) = try book()
        defaults.set(["dpr dance": "@dpr.dance"], forKey: "postroll.handlebook.performer.v1")
        defaults.set(["battery dance": "@batterydance"], forKey: HandleBook.orgKey)
        defaults.set(["wagner park": "@wagnerpark"], forKey: HandleBook.venueKey)

        XCTAssertEqual(book.entries(in: .performer).map(\.value), ["@dpr.dance"])
        XCTAssertEqual(book.entries(in: .org).map(\.value), ["@batterydance"])
        XCTAssertEqual(book.entries(in: .venue).map(\.value), ["@wagnerpark"])
    }

    func testEntriesComeBackInAStableOrder() throws {
        let (book, defaults) = try book()
        defaults.set(["zed": "@z", "alice": "@a", "mid": "@m"],
                     forKey: "postroll.handlebook.performer.v1")

        XCTAssertEqual(book.entries(in: .performer).map(\.name), ["alice", "mid", "zed"],
                       "a dictionary has no order, so a list drawn straight "
                       + "from one rearranges itself between two readings of "
                       + "the same book")
    }

    /// The whole point. #899 filters a value that is not shaped like a handle
    /// at the READ, so `handle(forPerformer:)` answers nothing for it and it
    /// reaches no caption. That is right, and it also makes the entry
    /// invisible: this screen is the one surface that has to show it anyway,
    /// or the thing it exists to let Dan correct cannot be seen.
    func testAStoredValueThatIsNotAHandleIsStillLISTED() throws {
        let (book, defaults) = try book()
        defaults.set(["dpr dance": "DPR Dance"],
                     forKey: "postroll.handlebook.performer.v1")

        XCTAssertEqual(book.handle(forPerformer: "DPR Dance"), "",
                       "it is still filtered where it would reach a caption")
        XCTAssertEqual(book.entries(in: .performer).map(\.value), ["DPR Dance"],
                       "and it is shown here, or the only copy of it is in a "
                       + "preferences file")
    }

    func testSuchAnEntryIsMarkedAsNotInUse() throws {
        let (book, defaults) = try book()
        defaults.set(["dpr dance": "DPR Dance", "safa": "@safa.wav"],
                     forKey: "postroll.handlebook.performer.v1")

        let entries = book.entries(in: .performer)
        XCTAssertEqual(entries.first { $0.name == "dpr dance" }?.isUsable, false)
        XCTAssertEqual(entries.first { $0.name == "safa" }?.isUsable, true)
    }

    /// The org and venue fields are free text that legitimately holds a
    /// sentence with accounts inside it, so the handle shape rule is not theirs
    /// and a prose entry there is not marked wrong (L118).
    func testProseInTheOrgBookIsNotMarkedWrong() throws {
        let (book, defaults) = try book()
        defaults.set(["fermin suero, jr. and pete white":
                        "@bludlineodyssey presented by @matchbookfestival"],
                     forKey: HandleBook.orgKey)

        XCTAssertEqual(book.entries(in: .org).first?.isUsable, true,
                       "that field carries a sentence on purpose, and "
                       + "EventHandleSuggestions takes the accounts out of it")
    }

    // MARK: - correcting what is there

    func testAnEntryCanBeCorrected() throws {
        let (book, defaults) = try book()
        defaults.set(["dpr dance": "DPR Dance"],
                     forKey: "postroll.handlebook.performer.v1")

        book.setEntry(name: "dpr dance", value: "@dpr.dance", in: .performer)

        XCTAssertEqual(book.handle(forPerformer: "DPR Dance"), "@dpr.dance")
    }

    func testCorrectingAPerformerEntryToSomethingThatIsNotAHandleIsRefused() throws {
        let (book, defaults) = try book()
        defaults.set(["dpr dance": "@dpr.dance"],
                     forKey: "postroll.handlebook.performer.v1")

        book.setEntry(name: "dpr dance", value: "DPR Dance Company", in: .performer)

        XCTAssertEqual(book.entries(in: .performer).first?.value, "@dpr.dance",
                       "the screen that exists to correct a bad value must not "
                       + "be a second way to write one, and it may not throw "
                       + "away a good handle on the way past (L5)")
    }

    func testTheOrgBookTakesASentence() throws {
        let (book, _) = try book()

        book.setEntry(name: "battery dance",
                      value: "@batterydance presented by @downtowndance", in: .org)

        XCTAssertEqual(book.entries(in: .org).first?.value,
                       "@batterydance presented by @downtowndance")
    }

    func testAnEntryCanBeDeleted() throws {
        let (book, defaults) = try book()
        defaults.set(["dpr dance": "@dpr.dance", "safa": "@safa.wav"],
                     forKey: "postroll.handlebook.performer.v1")

        book.removeEntry(name: "dpr dance", in: .performer)

        XCTAssertEqual(book.entries(in: .performer).map(\.name), ["safa"])
    }

    func testDeletingOneBooksEntryLeavesTheOthersAlone() throws {
        let (book, defaults) = try book()
        defaults.set(["battery dance": "@batterydance"],
                     forKey: "postroll.handlebook.performer.v1")
        defaults.set(["battery dance": "@batterydance"], forKey: HandleBook.orgKey)

        book.removeEntry(name: "battery dance", in: .performer)

        XCTAssertEqual(book.entries(in: .performer), [])
        XCTAssertEqual(book.entries(in: .org).count, 1,
                       "the books are keyed the same way and a delete that "
                       + "reached across them would take a handle nobody asked "
                       + "about")
    }

    /// Clearing the field is how a row is removed on screen, so it has to mean
    /// the same thing here. A refusal would leave a dead control (L109).
    func testClearingAnEntryRemovesIt() throws {
        let (book, defaults) = try book()
        defaults.set(["dpr dance": "@dpr.dance"],
                     forKey: "postroll.handlebook.performer.v1")

        book.setEntry(name: "dpr dance", value: "  ", in: .performer)

        XCTAssertEqual(book.entries(in: .performer), [])
    }

    // MARK: - what the screen says

    func testEachBookHasItsOwnHeadingAndExplanation() {
        var seen = Set<String>()
        for kind in HandleBook.Kind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.explanation.isEmpty)
            XCTAssertTrue(seen.insert(kind.title).inserted,
                          "two books share the heading \(kind.title), so the "
                          + "screen cannot say which list is which")
        }
    }
}
