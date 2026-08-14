import XCTest
import SwiftUI

/// #457: the hover is off the path that derives the event list.
///
/// `EventListView`'s body computes `filteredEvents`: a filter, a search and a
/// sort over every Event, and an Event is a large value carrying its days, its
/// photo paths and the whole week's generated result. While the hovered id
/// lived on that view, every enter and leave invalidated the body and paid the
/// whole derivation again, once per row the mouse crossed (L59).
///
/// The rule this holds is structural: the hover lives on its own object, and
/// the ONLY thing that reads it is the row background. A view that reads an
/// observable property is the view that re-renders when it changes, so a read
/// creeping back into the list's body would quietly restore the cost with
/// nothing looking different on screen.
@MainActor
final class EventRowBackgroundTests: XCTestCase {

    private var source: String {
        get throws {
            let dir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Views")
            return SwiftSourceText.withoutComments(
                try String(contentsOf: dir.appendingPathComponent("EventListView.swift"),
                           encoding: .utf8))
        }
    }

    func testTheListBodyNeverReadsTheHover() throws {
        let text = try source
        // Writing it is fine and is what the hover handler does. Reading it is
        // what ties the body to the pointer.
        let reads = text.components(separatedBy: "hover.eventID ==").count - 1
            + text.components(separatedBy: "== hover.eventID").count - 1

        XCTAssertEqual(reads, 0, """
            EventListView reads the hovered id in its own body, so every hover \
            enter and leave invalidates it and re-derives filteredEvents, which \
            is a filter plus a search plus a sort over every Event (#457).

            Read it in EventRowBackground instead, which is the only thing whose \
            appearance depends on it.
            """)
    }

    func testTheHoverIsWrittenSomewhere() throws {
        // A guard that passed because nothing hovers at all would be checking
        // nothing (L98).
        XCTAssertTrue(try source.contains("hover.eventID ="),
                      "nothing sets the hover, so the check above is vacuous")
    }

    // MARK: - What the background actually decides

    private let rowID = UUID()

    /// One namespace for every case: nothing here draws, so its identity is
    /// only needed to build the view.
    @Namespace private static var namespace

    func testTheHoveredRowIsHovered() {
        let hover = EventListHover()
        hover.eventID = rowID

        XCTAssertTrue(EventRowBackground(eventID: rowID, isSelected: false, hover: hover,
                                         selectionNamespace: Self.namespace)
            .isHoveredForTesting)
    }

    func testAnotherRowIsNotHovered() {
        let hover = EventListHover()
        hover.eventID = UUID()

        XCTAssertFalse(EventRowBackground(eventID: rowID, isSelected: false, hover: hover,
                                          selectionNamespace: Self.namespace)
            .isHoveredForTesting)
    }

    /// Selection wins. A selected row is already the strongest thing on the
    /// list, and warming it further would say the click had not landed.
    func testASelectedRowDoesNotAlsoShowTheHoverWarmth() {
        let hover = EventListHover()
        hover.eventID = rowID

        XCTAssertFalse(EventRowBackground(eventID: rowID, isSelected: true, hover: hover,
                                          selectionNamespace: Self.namespace)
            .isHoveredForTesting)
    }

    func testNothingHoveredIsNotHovered() {
        XCTAssertFalse(EventRowBackground(eventID: rowID, isSelected: false,
                                          hover: EventListHover(),
                                          selectionNamespace: Self.namespace)
            .isHoveredForTesting)
    }
}
