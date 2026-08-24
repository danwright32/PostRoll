import AppKit
import XCTest

/// The working mark is never drawn on nothing (#885).
///
/// While background work runs with no window open, PostRoll replaces its whole
/// Dock tile with a band and an elapsed clock. The icon underneath used to be
/// drawn through an optional chain, so an application with no icon produced a
/// black strip floating on an empty square, and nothing said so. The Dock is
/// the ONE surface reporting a run that has no window, so a silent failure
/// there is the failure that matters (L67).
///
/// Rendered rather than reasoned about. The question is what lands on the tile,
/// and only drawing it answers that.
@MainActor
final class WorkingDockTileTests: XCTestCase {

    /// Draw the tile and read its pixels back.
    private func rendered(icon: NSImage?) throws -> NSBitmapImageRep {
        let tile = WorkingDockTile(seconds: 65, icon: icon)
        let rep = try XCTUnwrap(tile.bitmapImageRepForCachingDisplay(in: tile.bounds),
                                "the tile could not be rendered at all")
        tile.cacheDisplay(in: tile.bounds, to: rep)
        return rep
    }

    /// What fraction of the tile has anything on it.
    private func covered(_ rep: NSBitmapImageRep) -> Double {
        var painted = 0
        var total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                total += 1
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.05 {
                    painted += 1
                }
            }
        }
        return total == 0 ? 0 : Double(painted) / Double(total)
    }

    func testATileWithNoIconIsStillAFullTile() throws {
        let rep = try rendered(icon: nil)

        // Measured against the tile being EMPTY, which is what the optional
        // chain produced: a band across the foot and transparency everywhere
        // else. The band is 30 of 128 points, so anything at or below about a
        // quarter is the defect.
        let coverage = covered(rep)
        XCTAssertGreaterThan(coverage, 0.9,
                             "only \(Int(coverage * 100))% of the tile is drawn "
                             + "with no icon to draw, so the working mark is a "
                             + "band on an empty square (#885)")
    }

    func testTheFallbackFieldIsNotTheBandsOwnColour() throws {
        let rep = try rendered(icon: nil)

        // The band has to stay readable AS a band. A fallback in the band's own
        // colour makes the tile one solid square with a clock on it, which is a
        // mark with no shape (L213: a pair is overridden as a pair).
        let field = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 4),
                                  "the upper half of the tile has no colour at all")
        let band = NSColor(PaintedSurfaces.dockWorkingBand)
            .usingColorSpace(.deviceRGB)
        let fieldRGB = try XCTUnwrap(field.usingColorSpace(.deviceRGB))
        let difference = abs(fieldRGB.redComponent - (band?.redComponent ?? 0))
            + abs(fieldRGB.greenComponent - (band?.greenComponent ?? 0))
            + abs(fieldRGB.blueComponent - (band?.blueComponent ?? 0))
        XCTAssertGreaterThan(difference, 0.2,
                             "the field behind the mark is the band's own colour, "
                             + "so the tile is one solid square and the band has "
                             + "no shape")
    }

    func testAnIconIsStillDrawnWhenThereIsOne() throws {
        // The positive case in the same fixture, because a fallback that fires
        // ALWAYS passes the two assertions above while hiding the app icon on
        // every run (L159).
        let icon = NSImage(size: NSSize(width: 128, height: 128))
        icon.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 128, height: 128).fill()
        icon.unlockFocus()

        let rep = try rendered(icon: icon)

        let above = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 4)?
            .usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(above.redComponent, 0.5,
                             "the icon that was handed in is not on the tile, so "
                             + "the fallback is drawing over every run")
    }
}
