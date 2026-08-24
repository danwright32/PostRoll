import AppKit
import SwiftUI

/// The app icon with a working mark and an elapsed clock on it (#863).
///
/// Drawn rather than badged. The Dock badge already means something else: how
/// many finished pieces of work are waiting to be looked at. One number meaning
/// two things is a number that says neither, so this is a separate mark in a
/// separate place (L118).
///
/// The elapsed time is the point of it. The rule this exists to satisfy is that
/// working, still alive and failed must be three visibly distinct states, and a
/// mark that never changes cannot tell the first two apart: it looks the same
/// whether the run is progressing, wedged or dead. A number that goes up every
/// second can only be produced by something still running.
///
/// A view rather than an image so the Dock redraws it on `display()`, and so the
/// app icon underneath stays whatever the app icon is rather than being baked
/// into a copy that goes stale the next time it changes.
final class WorkingDockTile: NSView {

    private let seconds: Int
    private let icon: NSImage?

    /// - Parameter icon: the app icon to draw the mark on. Injected, with the
    ///   running app's icon as the default, so the case where there ISN'T one
    ///   can be rendered by a test. The shipping app always passes the default.
    init(seconds: Int, icon: NSImage? = NSApplication.shared.applicationIconImage) {
        self.seconds = seconds
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func draw(_ dirtyRect: NSRect) {
        // A tile with nothing on it is not an option (#885).
        //
        // This used to be `applicationIconImage?.draw(in: bounds)`, one
        // optional chain, and a nil icon drew a black band on nothing at all:
        // the mark that says work is happening would have arrived as a strip
        // floating on an empty square, and nothing anywhere would have said so.
        // The Dock is the one surface that reports a run with no window, so its
        // failure has to be visible rather than silent (L67).
        //
        // The fallback is deliberately not a second attempt at the icon. It is
        // a filled field in the band's own colour, so the mark still reads as a
        // mark on something, and it is obviously not the app icon, which is the
        // point: it says the icon went missing rather than pretending it did
        // not.
        if let icon {
            icon.draw(in: bounds)
        } else {
            NSColor(PaintedSurfaces.dockMissingIcon).setFill()
            bounds.fill()
            NSLog("WorkingDockTile: the application has no icon, so the working "
                  + "mark is being drawn on a plain field (#885)")
        }

        let text = WorkingDockTile.clock(seconds)
        let height: CGFloat = 30
        let strip = NSRect(x: 0, y: 0, width: bounds.width, height: height)

        // A band rather than a floating label, so the digits are legible over
        // whatever part of the icon happens to be behind them, and an OPAQUE
        // one so the pair does not depend on the artwork underneath. Both
        // halves are named in PaintedSurfaces and measured there (L213).
        NSColor(PaintedSurfaces.dockWorkingBand).setFill()
        strip.fill()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: NSColor(PaintedSurfaces.dockWorkingClock),
            .paragraphStyle: style,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            in: NSRect(x: 0, y: (height - size.height) / 2, width: bounds.width, height: size.height),
            withAttributes: attributes)
    }

    /// Elapsed time, short enough to read on a Dock icon.
    ///
    /// Minutes and seconds up to an hour, then hours and minutes. A run that has
    /// been going for two hours reading "120:00" is a number nobody parses at a
    /// glance, and glancing is the entire use of this.
    static func clock(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        if safe < 3600 {
            return String(format: "%d:%02d", safe / 60, safe % 60)
        }
        return String(format: "%dh%02d", safe / 3600, (safe % 3600) / 60)
    }
}
