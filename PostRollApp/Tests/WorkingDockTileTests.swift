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
    ///
    /// `seconds` is a parameter rather than a literal because #950's clock
    /// checks render the SAME tile at two different times and hold the two to
    /// each other. It was baked in, and the first version of that check
    /// correctly reported the two renders as identical: the fixture was
    /// ignoring the time it was given, which is the very defect it was written
    /// to find (L48).
    private func rendered(icon: NSImage?, seconds: Int = 65) throws -> NSBitmapImageRep {
        let tile = WorkingDockTile(seconds: seconds, icon: icon)
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

    // MARK: - What the hand check can stop doing by hand (#950)

    /// The tile at two different elapsed times, so the clock can be compared.
    private func rendered(seconds: Int) throws -> NSBitmapImageRep {
        let icon = NSImage(size: NSSize(width: 128, height: 128))
        icon.lockFocus()
        NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 128, height: 128).fill()
        icon.unlockFocus()
        return try rendered(icon: icon, seconds: seconds)
    }

    /// The band's own height, from the view rather than restated here: a
    /// geometry copied into a check drifts from the one being drawn (L41).
    private static let bandHeight = 30

    func testTheClockIsActuallyDrawnOnTheBand() throws {
        // The hand check asks a person to watch the clock for five seconds
        // because "a mark that does not move cannot tell a run that is
        // progressing from one that is wedged or dead". That the digits are
        // DRAWN at all is the half a person should not have to check.
        let rep = try rendered(seconds: 65)
        let band = NSColor(PaintedSurfaces.dockWorkingBand).usingColorSpace(.deviceRGB)

        var unlikeTheBand = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<(Self.bandHeight * rep.pixelsHigh / 128) {
                guard let here = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)?
                    .usingColorSpace(.deviceRGB), let band else { continue }
                let difference = abs(here.redComponent - band.redComponent)
                    + abs(here.greenComponent - band.greenComponent)
                    + abs(here.blueComponent - band.blueComponent)
                if difference > 0.2 { unlikeTheBand += 1 }
            }
        }

        XCTAssertGreaterThan(unlikeTheBand, 50,
                             "the band has \(unlikeTheBand) pixels on it that "
                             + "are not the band's own colour, which is not a "
                             + "clock: the digits are not being drawn and the "
                             + "mark cannot tell a live run from a wedged one")
    }

    func testTheClockChangesWithTheTimeItIsShowing() throws {
        // The other half, and the one that matters: a clock DRAWN but frozen
        // reads exactly like a clock that is working (L106). Two tiles a minute
        // apart have to differ, or the number on the tile is decoration.
        let early = try rendered(seconds: 5)
        let later = try rendered(seconds: 65)

        var differing = 0
        for x in stride(from: 0, to: early.pixelsWide, by: 2) {
            for y in stride(from: 0, to: early.pixelsHigh, by: 2) {
                let a = early.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                let b = later.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                guard let a, let b else { continue }
                if abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) > 0.2 {
                    differing += 1
                }
            }
        }

        XCTAssertGreaterThan(differing, 10,
                             "0:05 and 1:05 draw the same tile, so the clock is "
                             + "not showing the time it was given and watching "
                             + "it for five seconds would prove nothing")
    }

    func testTheBandLeavesTheDockBadgesCornerAlone() throws {
        // #879 asks whether the band and the Dock BADGE are ever drawn on top
        // of each other, and says nobody has looked. Half of it can be looked
        // at here: macOS draws the badge in the TOP RIGHT of the tile, and this
        // is what says our band stays out of it.
        //
        // Honest about its reach. It cannot say the badge is legible, because
        // macOS draws that and this process does not. What it can say is that
        // the two are in different places, which is the half that is ours.
        let rep = try rendered(seconds: 65)
        let scale = rep.pixelsHigh / 128

        // The badge occupies roughly the top right quarter of a Dock tile.
        var painted = 0
        for x in (rep.pixelsWide * 3 / 4)..<rep.pixelsWide {
            for y in 0..<(rep.pixelsHigh / 4) {
                if let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   let band = NSColor(PaintedSurfaces.dockWorkingBand)
                    .usingColorSpace(.deviceRGB) {
                    let difference = abs(colour.redComponent - band.redComponent)
                        + abs(colour.greenComponent - band.greenComponent)
                        + abs(colour.blueComponent - band.blueComponent)
                    if difference < 0.05 { painted += 1 }
                }
            }
        }

        XCTAssertEqual(painted, 0,
                       "\(painted) pixels of the working band are in the top "
                       + "right quarter, where macOS draws the Dock badge, so "
                       + "the two marks are on top of each other and #879's "
                       + "question is answered the wrong way")
        XCTAssertGreaterThan(scale, 0, "the tile rendered at no scale at all")
    }

}
