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
    ///
    /// `int` and `string` THROW on the wrong kind rather than returning zero
    /// and the empty string. A malformed cell would otherwise read as a cell at
    /// the origin with no size, which every rule here would happily judge, and
    /// the suite would be asserting about a layout the fixture does not
    /// contain (L50).
    private enum CellField: Decodable {
        case name(String), number(Int)

        struct WrongKind: Error, CustomStringConvertible {
            let wanted: String
            var description: String {
                "a cell field in collage_layout_validity.json is not \(wanted); "
                + "a cell is [photo, x, y, w, h]"
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .number(n) }
            else { self = .name(try c.decode(String.self)) }
        }
        func int() throws -> Int {
            guard case .number(let n) = self else { throw WrongKind(wanted: "a number") }
            return n
        }
        func string() throws -> String {
            guard case .name(let s) = self else { throw WrongKind(wanted: "a string") }
            return s
        }
    }

    /// Through `RepoFixture` rather than reading the file here, so a folder
    /// macOS has refused reports as a permissions problem rather than as a
    /// broken suite (#271).
    private func contract() throws -> Contract {
        try JSONDecoder().decode(
            Contract.self, from: try RepoFixture.data("tests/fixtures/collage_layout_validity.json"))
    }

    private func cells(_ c: Contract.Case) throws -> [CollageCell] {
        try c.cells.map { f in
            guard f.count == 5 else {
                throw CellField.WrongKind(wanted: "five fields")
            }
            return CollageCell(photoPath: "/\(try f[0].string()).jpg",
                               x: try f[1].int(), y: try f[2].int(),
                               w: try f[3].int(), h: try f[4].int())
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
            let got = CollageCell.layoutProblems(try cells(c), stripBand: band)
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

    func testAnUnrenderableLayoutIsNotSaved() {
        // The write side. `saving` returns nil so the editor keeps the previous
        // layout rather than storing one the export cannot draw.
        let bad = [
            CollageCell(photoPath: "/a.jpg", x: 0, y: 0, w: 1080, h: 692),
            CollageCell(photoPath: "/b.jpg", x: 0, y: 782, w: 536, h: -2),
        ]
        XCTAssertNil(CollageCell.saving(bad))
    }

    func testAnOrdinaryLayoutIsSaved() {
        // The positive control. Without it the refusal above is satisfied by a
        // save path that refuses every layout, which would take the editor
        // away rather than fix it (L159).
        let good = [
            CollageCell(photoPath: "/a.jpg", x: 0, y: 0, w: 1080, h: 400),
            CollageCell(photoPath: "/b.jpg", x: 0, y: 490, w: 1080, h: 300),
        ]
        XCTAssertEqual(CollageCell.saving(good), good)
    }

    /// #970, and why the band has to be passed in rather than inferred.
    ///
    /// `brandedStripBand` reads the band out of the same cells being judged, so
    /// a verdict taken from it can only confirm the inference agrees with
    /// itself (L70). Grow a row down over the strip and the inferred band moves
    /// down with it, which is exactly the layout #965 reported.
    ///
    /// The band now comes from the sidecar Python writes beside the base PNG,
    /// recording where the strip SAT, so the same cells are refused.
    func testALayoutGrownOverTheStripIsRefusedAgainstTheBandItWasBuiltWith() {
        let overTheStrip = [
            CollageCell(photoPath: "/a.jpg", x: 0, y: 0, w: 1080, h: 600),
            CollageCell(photoPath: "/b.jpg", x: 0, y: 690, w: 536, h: 100),
            CollageCell(photoPath: "/c.jpg", x: 544, y: 690, w: 536, h: 100),
        ]

        // The inference still follows the damage, which is the whole reason it
        // cannot be the source.
        let inferred = CollageCell.brandedStripBand(in: overTheStrip)
        XCTAssertEqual(inferred?.top, 600)
        XCTAssertEqual(CollageCell.layoutProblems(overTheStrip, stripBand: inferred), [])

        // Told where the strip actually was, the save is refused.
        let built = (top: 400, height: 90)
        XCTAssertEqual(CollageCell.layoutProblems(overTheStrip, stripBand: built),
                       ["covers_strip"])
        XCTAssertNil(CollageCell.saving(overTheStrip, stripBand: built),
                     "a layout that covers the branding must not be stored")
        XCTAssertNil(CollageCell.usable(overTheStrip,
                                        forPhotos: [URL(fileURLWithPath: "/a.jpg"),
                                                    URL(fileURLWithPath: "/b.jpg"),
                                                    URL(fileURLWithPath: "/c.jpg")],
                                        stripBand: built))
    }

    /// The positive half. A band is only worth passing if a layout that
    /// respects it still saves, or this refuses every drag (L159).
    func testAnHonestLayoutStillSavesAgainstTheSameBand() {
        let honest = [
            CollageCell(photoPath: "/a.jpg", x: 0, y: 0, w: 1080, h: 400),
            CollageCell(photoPath: "/b.jpg", x: 0, y: 490, w: 536, h: 300),
            CollageCell(photoPath: "/c.jpg", x: 544, y: 490, w: 536, h: 300),
        ]
        XCTAssertEqual(CollageCell.saving(honest, stripBand: (top: 400, height: 90)), honest)
    }

    /// A collage rendered before the sidecar recorded a band passes nil, and
    /// nil has to mean "do not judge the band" rather than "there is none at
    /// zero", or every existing layout would be refused on the spot.
    func testAnUnrecordedBandDoesNotRefuseEverySavedLayout() {
        let honest = [
            CollageCell(photoPath: "/a.jpg", x: 0, y: 0, w: 1080, h: 400),
            CollageCell(photoPath: "/b.jpg", x: 0, y: 490, w: 536, h: 300),
            CollageCell(photoPath: "/c.jpg", x: 544, y: 490, w: 536, h: 300),
        ]
        XCTAssertEqual(CollageCell.saving(honest, stripBand: nil), honest)
        XCTAssertEqual(CollageCell.layoutProblems(honest, stripBand: nil), [])
    }

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
