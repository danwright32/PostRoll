import XCTest
import CoreGraphics

/// The Swift half of the saved collage layout contract (#967, #970).
///
/// The Python half is tests/test_collage_layout_validity.py and reads the same
/// committed file. Two lists of the same rule agree only until somebody edits
/// one (L26).
final class CollageLayoutValidityTests: XCTestCase {

    private struct Contract: Decodable {
        struct Canvas: Decodable { let w: Int; let h: Int }
        struct Case: Decodable {
            let name: String
            let strip_y: Int?
            let strip_h: Int
            let cells: [[CellField]]
            let problems: [String]
        }
        let min_cell_px: Int
        let canvas: Canvas
        let cases: [Case]
    }

    /// A cell in the fixture is [photo, x, y, w, h], so the first field is a
    /// string and the rest are numbers.
    private enum CellField: Decodable {
        case name(String), number(Int)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .number(n) }
            else { self = .name(try c.decode(String.self)) }
        }
        var int: Int { if case .number(let n) = self { return n }; return 0 }
        var string: String { if case .name(let s) = self { return s }; return "" }
    }

    /// Through `RepoFixture` rather than reading the file here, so a folder
    /// macOS has refused reports as a permissions problem rather than as a
    /// broken suite (#271).
    private func contract() throws -> Contract {
        try JSONDecoder().decode(
            Contract.self, from: try RepoFixture.data("tests/fixtures/collage_layout_validity.json"))
    }

    private func cells(_ c: Contract.Case) -> [CollageCell] {
        c.cells.map { f in
            CollageCell(photoPath: "/\(f[0].string).jpg",
                        x: f[1].int, y: f[2].int, w: f[3].int, h: f[4].int)
        }
    }

    func testTheFixtureIsReadableAndCarriesItsCases() throws {
        let contract = try contract()
        // A contract this side could not read passes every assertion below
        // while checking nothing (L98).
        XCTAssertGreaterThanOrEqual(contract.cases.count, 12)
        let codes = Set(contract.cases.flatMap(\.problems))
        XCTAssertEqual(codes, ["under_floor", "off_canvas", "overlapping",
                               "covers_strip", "empty"])
        XCTAssertTrue(contract.cases.contains { $0.problems.isEmpty },
                      "no case shows a VALID layout")
    }

    func testSwiftAgreesWithTheContract() throws {
        let contract = try contract()
        for c in contract.cases {
            let band = c.strip_y.map { (top: $0, height: c.strip_h) }
            let got = CollageCell.layoutProblems(cells(c), stripBand: band)
            XCTAssertEqual(got, c.problems.sorted(), c.name)
        }
    }

    func testTheFloorIsTheOneTheDragClampsTo() throws {
        let contract = try contract()
        // Restated rather than shared, the floor and the clamp drift and a drag
        // becomes able to save what the validator would refuse (L41).
        XCTAssertEqual(minCollageCellPx, contract.min_cell_px)
    }

    func testTheCanvasIsTheOneTheRendererDrawsInto() throws {
        let contract = try contract()
        XCTAssertEqual(Int(CollageGeometry.canvasSize.width), contract.canvas.w)
        XCTAssertEqual(Int(CollageGeometry.canvasSize.height), contract.canvas.h)
    }

    // MARK: - Finding the band

    func testTheBandIsFoundWhereTheStripActuallyIs() {
        // Derived from the dividers rather than from a written offset, because
        // how far down the strip sits depends on how many rows are above it.
        let cells = [
            CollageCell(photoPath: "/a.jpg", x: 0, y: 0, w: 1080, h: 400),
            CollageCell(photoPath: "/b.jpg", x: 0, y: 490, w: 536, h: 300),
            CollageCell(photoPath: "/c.jpg", x: 544, y: 490, w: 536, h: 300),
        ]
        let band = CollageCell.brandedStripBand(in: cells)
        XCTAssertEqual(band?.top, 400)
        XCTAssertEqual(band?.height, 90)
    }

    func testASingleRowLayoutHasNoBandRatherThanOneAtZero() {
        // Reading the absence as a band at zero would refuse every single row
        // layout, which is a real state (L214).
        let cells = [
            CollageCell(photoPath: "/a.jpg", x: 0, y: 0, w: 536, h: 400),
            CollageCell(photoPath: "/b.jpg", x: 544, y: 0, w: 536, h: 400),
        ]
        XCTAssertNil(CollageCell.brandedStripBand(in: cells))
        XCTAssertEqual(CollageCell.layoutProblems(cells, stripBand: nil), [])
    }

    func testAnOrdinaryRowGapIsNotMistakenForTheBand() {
        // An 8px gap between two rows is a gap, not the branded strip. Treating
        // it as one would refuse every layout that has more than one row.
        let cells = [
            CollageCell(photoPath: "/a.jpg", x: 0, y: 0, w: 1080, h: 400),
            CollageCell(photoPath: "/b.jpg", x: 0, y: 408, w: 1080, h: 400),
        ]
        XCTAssertNil(CollageCell.brandedStripBand(in: cells))
    }

    // MARK: - The failure the issues asked for first

    func testTheLayoutTheStripDragUsedToProduceIsRefused() {
        // #965's symptom, as data: the top row grown down over the band and the
        // row below at a negative height. It is stored and exported today.
        let cells = [
            CollageCell(photoPath: "/a.jpg", x: 0, y: 0, w: 1080, h: 692),
            CollageCell(photoPath: "/b.jpg", x: 0, y: 782, w: 536, h: -2),
            CollageCell(photoPath: "/c.jpg", x: 544, y: 782, w: 536, h: -2),
        ]
        XCTAssertEqual(CollageCell.layoutProblems(cells, stripBand: (top: 400, height: 90)),
                       ["covers_strip", "under_floor"])
    }
}
