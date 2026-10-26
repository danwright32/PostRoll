import XCTest

/// A flag that says an entry should not exist could not be acted on (#1573).
///
/// Claude flagged `performers[10].name` "Jack" as a pumpkin from the giveaway
/// rows, proposed no replacement, and the row offered only "replace the name"
/// (disabled, since the box held the OCR text) or "the OCR was right". Removing
/// the performer by hand was worse: flags address their entry by POSITION, so
/// every later flag in the list was left naming somebody else.
final class OCRFlagEditsTests: XCTestCase {

    private func ocr(_ names: [String]) -> OCRResult {
        var result = OCRResult()
        result.performers = names.map { Performer(name: $0) }
        return result
    }

    private func nameFlag(_ id: String, _ index: Int, _ value: String,
                          resolved: Bool = false) -> OCRFlag {
        OCRFlag(id: id, fieldPath: [.key("performers"), .index(index), .key("name")],
                currentValue: value, concern: "c", resolved: resolved)
    }

    private func names(_ result: OCRResult) -> [String] { result.performers.map(\.name) }

    /// The refusal, or nil when the entry was removed.
    private func remove(_ flag: OCRFlag, _ result: inout OCRResult,
                        _ flags: inout [OCRFlag]) -> OCRFlagEdits.Refusal? {
        if case .failure(let refusal) = OCRFlagEdits.removeEntry(for: flag, ocr: &result, flags: &flags) {
            return refusal
        }
        return nil
    }

    // MARK: - Which entry a flag is about

    func testTheEntryIsTheInnermostListElementThePathLandsIn() {
        let performer = OCRFlagEdits.entry(of: [.key("performers"), .index(10), .key("name")])
        XCTAssertEqual(performer?.list, [.key("performers")])
        XCTAssertEqual(performer?.index, 10)

        let movement = OCRFlagEdits.entry(of: [.key("pieces"), .index(5), .key("movements"), .index(2)])
        XCTAssertEqual(movement?.list, [.key("pieces"), .index(5), .key("movements")])
        XCTAssertEqual(movement?.index, 2)
    }

    func testAFieldOutsideAnyListHasNoEntryToRemove() {
        XCTAssertNil(OCRFlagEdits.entry(of: [.key("program_notes")]))
        XCTAssertNil(OCRFlagEdits.entry(of: []))
    }

    // MARK: - Removing the entry

    func testRemovingTheEntryDeletesItAndResolvesTheFlag() {
        var result = ocr(["Ana", "Ben", "Jack", "Joe"])
        var flags = [nameFlag("jack", 2, "Jack")]

        let refusal = remove(flags[0], &result, &flags)

        XCTAssertNil(refusal)
        XCTAssertEqual(names(result), ["Ana", "Ben", "Joe"])
        XCTAssertTrue(flags[0].resolved)
    }

    /// The case that made a hand delete unsafe: the flag after the removed
    /// entry must still name the same performer, not the one that slid up.
    func testLaterFlagsInTheSameListFollowTheirEntry() {
        var result = ocr(["Ana", "Ben", "Jack", "Joe", "Edgar"])
        var flags = [nameFlag("ana", 0, "Ana"), nameFlag("jack", 2, "Jack"),
                     nameFlag("joe", 3, "Joe"), nameFlag("edgar", 4, "Edgar")]

        XCTAssertNil(remove(flags[1], &result, &flags))

        XCTAssertEqual(flags[0].fieldPath, [.key("performers"), .index(0), .key("name")])
        XCTAssertEqual(flags[2].fieldPath, [.key("performers"), .index(2), .key("name")])
        XCTAssertEqual(flags[3].fieldPath, [.key("performers"), .index(3), .key("name")])
        // And they can be acted on straight after: Joe is removable at once.
        XCTAssertNil(remove(flags[2], &result, &flags))
        XCTAssertEqual(names(result), ["Ana", "Ben", "Edgar"])
        XCTAssertEqual(flags[3].fieldPath, [.key("performers"), .index(2), .key("name")])
    }

    /// Another concern about the same performer has nothing left to point at.
    func testOtherFlagsOnTheRemovedEntryAreResolvedWithIt() {
        var result = ocr(["Ana", "Jack"])
        let roleFlag = OCRFlag(id: "role", fieldPath: [.key("performers"), .index(1), .key("role")],
                               currentValue: "", concern: "c")
        var flags = [nameFlag("jack", 1, "Jack"), roleFlag]

        XCTAssertNil(remove(flags[0], &result, &flags))

        XCTAssertTrue(flags[1].resolved)
    }

    /// A resolved flag is a record of where it was when it was settled; moving
    /// it would rewrite that, and it is never acted on again.
    func testResolvedFlagsAndOtherListsAreLeftAlone() {
        var result = ocr(["Ana", "Jack", "Joe"])
        result.pieces = [Piece(), Piece(), Piece()]
        let pieceFlag = OCRFlag(id: "piece", fieldPath: [.key("pieces"), .index(2), .key("composer")],
                                currentValue: "", concern: "c")
        var flags = [nameFlag("jack", 1, "Jack"), nameFlag("old", 2, "Joe", resolved: true), pieceFlag]

        XCTAssertNil(remove(flags[0], &result, &flags))

        XCTAssertEqual(flags[1].fieldPath, [.key("performers"), .index(2), .key("name")])
        XCTAssertEqual(flags[2].fieldPath, pieceFlag.fieldPath)
    }

    /// Positions can still go stale by a route that does not move flags (a
    /// "describe the correction" rewrite). Acting there would delete somebody
    /// else, so it is refused and nothing changes.
    func testRemovingIsRefusedWhenTheEntryNoLongerHoldsTheFlaggedValue() {
        var result = ocr(["Ana", "Ben", "Joe"])
        var flags = [nameFlag("jack", 2, "Jack")]

        let refusal = remove(flags[0], &result, &flags)

        XCTAssertEqual(refusal, .entryChanged(now: "Joe"))
        XCTAssertEqual(names(result), ["Ana", "Ben", "Joe"])
        XCTAssertFalse(flags[0].resolved)
    }

    func testRemovingIsRefusedWhenThePositionIsGone() {
        var result = ocr(["Ana"])
        var flags = [nameFlag("jack", 4, "Jack")]

        XCTAssertEqual(remove(flags[0], &result, &flags), .missing)
        XCTAssertEqual(names(result), ["Ana"])
    }

    func testRemovingIsRefusedForAFieldOutsideAList() {
        var result = OCRResult()
        result.programNotes = "notes"
        var flags = [OCRFlag(id: "n", fieldPath: [.key("program_notes")], currentValue: "notes")]

        XCTAssertEqual(remove(flags[0], &result, &flags), .notInAList)
        XCTAssertEqual(result.programNotes, "notes")
    }

    /// Claude writes `current_value` itself, so spacing and case can differ
    /// from the stored text without it being a different performer.
    func testTheValueCheckIgnoresCaseAndSurroundingSpace() {
        var result = ocr(["Ana", "jack "])
        var flags = [nameFlag("jack", 1, "Jack")]

        XCTAssertNil(remove(flags[0], &result, &flags))
        XCTAssertEqual(names(result), ["Ana"])
    }

    /// Remove is destructive, so it is undoable: the entry goes back where it
    /// was, the flags it resolved reopen, and the later flags move back up.
    func testUndoingARemovePutsTheEntryAndItsFlagsBack() throws {
        let original = ocr(["Ana", "Jack", "Joe"])
        var result = original
        let roleFlag = OCRFlag(id: "role", fieldPath: [.key("performers"), .index(1), .key("role")],
                               currentValue: "", concern: "c")
        let originalFlags = [nameFlag("jack", 1, "Jack"), roleFlag, nameFlag("joe", 2, "Joe")]
        var flags = originalFlags

        let removal = try OCRFlagEdits.removeEntry(for: flags[0], ocr: &result, flags: &flags).get()
        OCRFlagEdits.restore(removal, ocr: &result, flags: &flags)

        XCTAssertEqual(result, original)
        XCTAssertEqual(flags, originalFlags)
    }

    /// A flag resolved BEFORE the remove stays resolved after the undo.
    func testUndoReopensOnlyTheFlagsTheRemoveResolved() throws {
        var result = ocr(["Ana", "Jack"])
        var flags = [nameFlag("jack", 1, "Jack"), nameFlag("done", 1, "Jack", resolved: true)]

        let removal = try OCRFlagEdits.removeEntry(for: flags[0], ocr: &result, flags: &flags).get()
        OCRFlagEdits.restore(removal, ocr: &result, flags: &flags)

        XCTAssertFalse(flags[0].resolved)
        XCTAssertTrue(flags[1].resolved)
    }

    // MARK: - The other routes that move entries

    /// Deleting a row in the Performers section, and undoing it, move flags
    /// the same way the flag's own Remove does.
    func testDeletingAndRestoringARowByHandKeepsFlagsOnTheirEntries() {
        let flags = [nameFlag("ana", 0, "Ana"), nameFlag("jack", 1, "Jack"), nameFlag("joe", 2, "Joe")]

        let afterDelete = OCRFlagEdits.flags(flags, afterRemoving: 1, from: [.key("performers")])
        XCTAssertEqual(afterDelete[2].fieldPath, [.key("performers"), .index(1), .key("name")])
        XCTAssertTrue(afterDelete[1].resolved)

        let settled = OCRFlagEdits.newlyResolved(from: flags, to: afterDelete)
        XCTAssertEqual(settled, ["jack"])
        let afterUndo = OCRFlagEdits.flags(afterDelete, afterInserting: 1, into: [.key("performers")],
                                           reopening: settled)
        XCTAssertEqual(afterUndo, flags)
    }

    /// Dragging a work to a new place in the Program list moves the flags with
    /// the works, in both directions, so each flag still names its own work.
    func testReorderingAListMovesEachFlagWithItsEntry() {
        func pieceFlag(_ id: String, _ i: Int) -> OCRFlag {
            OCRFlag(id: id, fieldPath: [.key("pieces"), .index(i), .key("title")], currentValue: id)
        }
        func positions(_ flags: [OCRFlag]) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: flags.compactMap { f in
                OCRFlagEdits.entry(of: f.fieldPath).map { (f.id, $0.index) }
            })
        }
        // Works a b c d e at 0...4, one flag each.
        let flags = ["a", "b", "c", "d", "e"].enumerated().map { pieceFlag($1, $0) }

        // b dragged down to sit after d: a c d b e.
        let down = OCRFlagEdits.flags(flags, afterMoving: 1, to: 3, in: [.key("pieces")])
        XCTAssertEqual(positions(down), ["a": 0, "c": 1, "d": 2, "b": 3, "e": 4])

        // d dragged up to the top: d a b c e.
        let up = OCRFlagEdits.flags(flags, afterMoving: 3, to: 0, in: [.key("pieces")])
        XCTAssertEqual(positions(up), ["d": 0, "a": 1, "b": 2, "c": 3, "e": 4])
    }

    /// The final index a drag lands on, from SwiftUI's `move(toOffset:)`,
    /// which counts the gap before the dragged item is taken out.
    func testTheDropOffsetBecomesTheFinalIndex() {
        XCTAssertEqual(OCRFlagEdits.finalIndex(movingFrom: 1, toOffset: 4), 3)
        XCTAssertEqual(OCRFlagEdits.finalIndex(movingFrom: 3, toOffset: 0), 0)
    }

    // MARK: - Saving a correction

    func testSavingIsRefusedWhenTheFieldNoLongerHoldsTheFlaggedValue() {
        let result = ocr(["Ana", "Joe"])
        XCTAssertEqual(OCRFlagEdits.stillHolds(nameFlag("jack", 1, "Jack"), in: result),
                       .entryChanged(now: "Joe"))
        XCTAssertNil(OCRFlagEdits.stillHolds(nameFlag("joe", 1, "Joe"), in: result))
    }

    func testRefusalsSayWhatToDo() {
        XCTAssertEqual(OCRFlagEdits.Refusal.entryChanged(now: "Joe").message(field: "name"),
                       "This entry's name is now \u{201C}Joe\u{201D}, not what Claude flagged, so nothing was changed. Check it in its section below.")
        XCTAssertEqual(OCRFlagEdits.Refusal.missing.message(field: "name"),
                       "This entry is no longer in the program data, so nothing was changed.")
    }

    func testTheRemoveButtonNamesWhatItRemoves() {
        XCTAssertEqual(OCRFlagEdits.removeLabel(for: [.key("performers"), .index(3), .key("name")]),
                       "Remove performer")
        XCTAssertEqual(OCRFlagEdits.removeLabel(for: [.key("pieces"), .index(3), .key("composer")]),
                       "Remove work")
        XCTAssertEqual(OCRFlagEdits.removeLabel(for: [.key("scenes"), .index(0), .key("name")]),
                       "Remove scene")
        XCTAssertNil(OCRFlagEdits.removeLabel(for: [.key("program_notes")]))
    }
}
