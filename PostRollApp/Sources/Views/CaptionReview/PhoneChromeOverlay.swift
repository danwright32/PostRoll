import SwiftUI

/// What the phone and Instagram draw over a full-frame preview (#758).
///
/// Nothing in PostRoll showed a frame the way Instagram will. The caption
/// review screen drew each preview as a clean rectangle, with no status bar, no
/// Dynamic Island, no caption band and no action rail, so a template that put
/// something in a covered band looked perfect right up to the moment it was
/// published.
///
/// That gap is how #752 survived. The show title had been printed under the
/// clock on every scroll reel published, every local render looked perfect, and
/// the only detector was Dan seeing a live story on his phone. #753 is the same
/// shape at the foot of the frame.
///
/// The numbers are `PhoneSafeArea`, measured off two published reels on Dan's
/// iPhone 16 Pro Max on 2026-08-20, so this draws what was measured rather than
/// an impression of it.

/// Where the covered bands fall in a view showing a 1080 by 1920 frame at
/// `size`.
///
/// Its own type rather than maths inside the view body, because where the bands
/// LAND is the half worth testing and a view body cannot be asked.
struct PhoneChromeBands: Equatable {

    let top: CGRect
    let bottom: CGRect
    let rail: CGRect

    /// True when there is no frame to describe, which is what SwiftUI hands a
    /// `GeometryReader` on its first layout pass more often than anyone
    /// expects. Answered rather than divided by: a scale taken from zero is a
    /// NaN that silently paints nothing, and silence here reads exactly like a
    /// frame with nothing in the covered bands.
    var isEmpty: Bool { top == .zero && bottom == .zero && rail == .zero }

    init(in size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            top = .zero; bottom = .zero; rail = .zero
            return
        }
        // Scaled per axis from the canvas the tokens were measured against, so
        // a view drawing the frame at any size gets the same proportions. The
        // preview on the caption screen is a few hundred points tall, not 1920,
        // and a band drawn at its token value would swallow it whole.
        let sx = size.width / PhoneSafeArea.canvas.width
        let sy = size.height / PhoneSafeArea.canvas.height

        top = CGRect(x: 0, y: 0,
                     width: size.width, height: PhoneSafeArea.top * sy)
        bottom = CGRect(x: 0, y: size.height - PhoneSafeArea.bottom * sy,
                        width: size.width, height: PhoneSafeArea.bottom * sy)
        // A rail over the lower part of the frame, not a whole edge. Drawing it
        // full height would report a template's top right corner as covered
        // when nothing covers it, and the first false alarm is what gets an
        // overlay switched off (L36).
        let railTop = size.height * PhoneSafeArea.rightFrom
        rail = CGRect(x: size.width - PhoneSafeArea.right * sx, y: railTop,
                      width: PhoneSafeArea.right * sx,
                      height: size.height - railTop)
    }
}


/// Whether the overlay is drawn, remembered between launches.
///
/// ON until it is turned off. The whole point is that a template putting
/// something in a covered band is visible at review time; off by default would
/// ship the check present and inert, which is a safeguard nobody benefits from
/// (L65).
enum PhoneChromePreference {

    static let key = "showPhoneChromeOnPreviews"

    /// Named once, so the `@AppStorage` default at the call site and the reader
    /// below cannot disagree about what an unset key means (L107).
    static let defaultOn = true

    static func isOn(in defaults: UserDefaults = AppPreferences.store) -> Bool {
        // `object(forKey:)` rather than `bool(forKey:)`: an unset key reads as
        // false from the latter, which is indistinguishable from having been
        // turned off, and the default has to be on.
        defaults.object(forKey: key) as? Bool ?? defaultOn
    }

    static func set(_ on: Bool, in defaults: UserDefaults = AppPreferences.store) {
        defaults.set(on, forKey: key)
    }
}


/// Drawn over a full-frame preview at whatever size it is being shown.
struct PhoneChromeOverlay: View {

    var body: some View {
        GeometryReader { geometry in
            let bands = PhoneChromeBands(in: geometry.size)
            if !bands.isEmpty {
                ZStack(alignment: .topLeading) {
                    band(bands.top)
                    band(bands.bottom)
                    band(bands.rail, faint: true)
                    hairline(atY: bands.top.maxY, width: geometry.size.width)
                    hairline(atY: bands.bottom.minY, width: geometry.size.width)
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// A wash rather than a solid: what is underneath has to stay readable, or
    /// the preview stops being a preview and the overlay is switched off.
    private func band(_ rect: CGRect, faint: Bool = false) -> some View {
        Rectangle()
            .fill(faint ? PaintedSurfaces.phoneChromeFaint
                        : PaintedSurfaces.phoneChrome)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    private func hairline(atY y: CGFloat, width: CGFloat) -> some View {
        Rectangle()
            .fill(PaintedSurfaces.phoneChromeEdge)
            .frame(width: width, height: 1)
            .offset(y: y)
    }
}
