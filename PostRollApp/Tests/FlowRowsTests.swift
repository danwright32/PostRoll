import XCTest

/// The packing behind the tagging sheet's chips.
final class FlowRowsTests: XCTestCase {

    /// A chip of one line of text: `ideal` wide when nothing limits it, and
    /// wrapping onto as many lines as it takes when offered less.
    private func chip(_ ideal: CGFloat, lineHeight: CGFloat = 18) -> (CGFloat?) -> CGSize {
        { offered in
            guard let offered, offered < ideal else {
                return CGSize(width: ideal, height: lineHeight)
            }
            return CGSize(width: offered, height: lineHeight * (ideal / offered).rounded(.up))
        }
    }

    private func frames(_ chips: [(CGFloat?) -> CGSize], maxWidth: CGFloat) -> [CGRect] {
        FlowRows.frames(count: chips.count, maxWidth: maxWidth, spacing: 4) { index, width in
            chips[index](width)
        }
    }

    func testChipsThatFitShareARowAndTheNextOneWraps() {
        let placed = frames([chip(100), chip(100), chip(100)], maxWidth: 260)

        XCTAssertEqual(placed.map(\.minX), [0, 104, 0])
        XCTAssertEqual(placed.map(\.minY), [0, 0, 22])
    }

    func testAChipWiderThanTheRowIsHeldToTheRowsWidth() {
        let placed = frames([chip(372)], maxWidth: 260)

        XCTAssertLessThanOrEqual(placed[0].maxX, 260,
                                 "a chip wider than its column is drawn past the column's edge, "
                                 + "and the end of its label is cut off by the panel")
    }

    func testAChipHeldToTheRowTakesTheHeightItsWrappedTextNeeds() {
        let placed = frames([chip(372), chip(100)], maxWidth: 260)

        XCTAssertEqual(placed[0].height, 36, "two lines of text need two lines of chip")
        XCTAssertEqual(placed[1].minY, 40,
                       "the chip after a wrapped one starts below all of it, not across its "
                       + "second line")
    }

    func testAChipWiderThanTheRowStartsOnARowOfItsOwn() {
        let placed = frames([chip(100), chip(372)], maxWidth: 260)

        XCTAssertEqual(placed[1].minX, 0)
        XCTAssertEqual(placed[1].minY, 22)
    }

    func testWithNoWidthOfferedNothingWrapsAndNothingIsHeld() {
        let placed = frames([chip(372), chip(100)], maxWidth: .infinity)

        XCTAssertEqual(placed.map(\.minY), [0, 0])
        XCTAssertEqual(placed[0].width, 372)
        XCTAssertEqual(FlowRows.size(of: placed, maxWidth: .infinity).width, 476)
    }

    func testTheRowsAreAsWideAsTheyWereOfferedAndAsTallAsTheirLastRow() {
        let placed = frames([chip(100), chip(372)], maxWidth: 260)

        XCTAssertEqual(FlowRows.size(of: placed, maxWidth: 260), CGSize(width: 260, height: 58))
    }
}
