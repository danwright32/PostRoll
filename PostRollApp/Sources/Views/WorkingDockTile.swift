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

    init(seconds: Int) {
        self.seconds = seconds
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func draw(_ dirtyRect: NSRect) {
        NSApplication.shared.applicationIconImage?.draw(in: bounds)

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
