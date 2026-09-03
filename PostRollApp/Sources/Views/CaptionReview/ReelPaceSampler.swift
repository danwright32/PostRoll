import SwiftUI

/// A few seconds of the Thursday reel actually moving, without rendering it
/// (#1071).
///
/// `build_reel_preview` writes the masonry strip as a still, which answers what
/// the reel looks like but not how it FEELS, and pace is the thing that has
/// been wrong. On 2026-08-30 Dan settled the comfortable scroll speed by having
/// ten complete reels rendered at 50 to 160 seconds each and opening them in
/// QuickTime, roughly forty minutes to answer one question.
///
/// It shows a VIEWPORT-shaped window of the strip, moving at the rate
/// `ScrollReelTiming` derives from the encoder's own travel and cruise factor.
/// Both matter: the whole strip scaled to fit would move at a completely
/// different speed from the one a viewer sees, and a rate invented here would
/// be trusted while being wrong.
///
/// The ramps at each end are not sampled. Cruise is where the reel spends its
/// time and what "too fast" was reported about.
struct ReelPaceSampler: View {
    let strip: NSImage
    /// The strip's height in CANVAS pixels, which is the unit the scroll rate
    /// is expressed in and is not the image's pixel height once it has been
    /// scaled for display.
    let stripCanvasHeight: Double
    let scrollSeconds: Double
    let onClose: () -> Void

    @State private var offset: Double = 0
    @State private var running = false

    private var pixelsPerSecond: Double {
        ScrollReelTiming.cruisePixelsPerSecond(
            stripHeight: stripCanvasHeight, scrollSeconds: scrollSeconds)
    }

    /// How far the sample travels, capped at what is left of the strip so it
    /// cannot scroll past the end into empty space.
    private var sampleTravel: Double {
        min(pixelsPerSecond * ScrollReelTiming.paceSampleSeconds,
            max(0, stripCanvasHeight - ScrollReelTiming.paceWindowHeight))
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Text("PACE AT CRUISE")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(PaintedSurfaces.secondaryText)

            GeometryReader { geo in
                // One scale for both axes, so the window is the viewport's
                // real shape rather than a stretched one, and the movement is
                // in the same proportion a viewer sees.
                let scale = geo.size.width / 1080.0
                ZStack(alignment: .top) {
                    Image(nsImage: strip)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: geo.size.width,
                               height: stripCanvasHeight * scale)
                        .offset(y: -offset * scale)
                }
                .frame(width: geo.size.width,
                       height: ScrollReelTiming.paceWindowHeight * scale,
                       alignment: .top)
                .clipped()
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 0.5)
                )
                .onAppear(perform: start)
            }
            .aspectRatio(1080.0 / ScrollReelTiming.paceWindowHeight, contentMode: .fit)

            // Says what it is showing, in the units the warning uses, so the
            // two surfaces cannot be read as describing different reels.
            Text(caption)
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.sm) {
                Button(running ? "Playing…" : "Play again", action: start)
                    .disabled(running)
                Button("Done", action: onClose)
            }
            .font(.system(size: 11))
        }
        .padding(Spacing.md)
    }

    private var caption: String {
        let screen = ScrollReelTiming.secondsPerScreen(
            stripHeight: stripCanvasHeight, scrollSeconds: scrollSeconds)
        guard screen.isFinite else {
            return "This strip fits on one screen, so the reel does not scroll."
        }
        return String(
            format: "%.0f seconds of the middle of a %.0f second scroll, at the "
                  + "speed it will run. The whole screen is replaced every %.1f "
                  + "seconds.",
            ScrollReelTiming.paceSampleSeconds, scrollSeconds, screen)
    }

    private func start() {
        guard sampleTravel > 0 else { return }
        running = true
        offset = 0
        // Linear, because this samples CRUISE, which is a constant speed. An
        // eased animation here would show a pace the reel never runs at.
        withAnimation(.linear(duration: ScrollReelTiming.paceSampleSeconds)) {
            offset = sampleTravel
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ScrollReelTiming.paceSampleSeconds) {
            running = false
        }
    }
}
