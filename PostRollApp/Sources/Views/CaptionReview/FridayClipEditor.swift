import SwiftUI
import AVFoundation
import AppKit


/// Reorder / include-exclude / swap the Friday auto-cut reel's clip
/// selection (#135). Every edit here writes only to fridayClipOverride and
/// re-renders locally via render_friday_override.py - never re-invokes
/// Claude (feedback_collage_edits_no_python_regen). "Re-cut with AI" is the
/// only action that clears the override and re-runs Stage 1 + 2.
/// Internal rather than private so the rendering check can host it (#732).
struct FridayClipEditor: View {
    let entries: [ReelClipOverride]
    let hasOverride: Bool
    var onApply: (([ReelClipOverride]) -> Void)? = nil
    var onSwap: ((String) -> Void)? = nil
    var onRecutWithAI: (() -> Void)? = nil
    /// Title card overlay (plan #148, Phase 3): on by default per event,
    /// toggled off here without re-invoking Claude.
    var titleCardMuted: Bool = false
    var onToggleTitleCard: (() -> Void)? = nil
    /// Whether Friday is rebuilding right now (#732).
    ///
    /// Every control in here rebuilds Friday, so the whole editor is disabled
    /// rather than each button in turn: a control added tomorrow inherits it
    /// instead of needing to be remembered (L96). Since #728 these actions are
    /// refused while a run is in flight, and a control that looks available and
    /// then declines teaches Dan to distrust it, which is worse than one that
    /// plainly cannot be used while he can see why.
    ///
    /// Disabled, not hidden: the clips stay legible, which is what he is
    /// watching during the rebuild they are being cut into (L10).
    var isRegenerating: Bool = false

    @State private var cropPopoverIndex: Int? = nil

    var body: some View {
        guard !entries.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("CLIPS")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)

                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: Spacing.sm) {
                        VStack(spacing: 2) {
                            Button(action: { move(index, by: -1) }) {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                            Button(action: { move(index, by: 1) }) {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == entries.count - 1)
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(PaintedSurfaces.secondaryText)

                        Text(URL(fileURLWithPath: entry.clipPath).lastPathComponent)
                            .font(.system(size: 11))
                            // An included clip was drawn in WHITE, on a panel
                            // filled with the cream page: about 1.02:1, which
                            // is the file name of every clip that IS in the
                            // reel, invisible, while the excluded ones beside
                            // them read fine (#620). Included is the emphasis
                            // now and excluded stays quiet and struck through.
                            .foregroundStyle(entry.included
                                             ? PaintedSurfaces.bodyText
                                             : PaintedSurfaces.secondaryText)
                            .lineLimit(1)
                            .strikethrough(!entry.included)

                        Spacer(minLength: 0)

                        Button(ClipCropFrameStrip.isCustomCrop(x: entry.cropX, y: entry.cropY) ? "Crop*" : "Crop") {
                            cropPopoverIndex = index
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                        .popover(isPresented: Binding(
                            get: { cropPopoverIndex == index },
                            set: { if !$0 { cropPopoverIndex = nil } }
                        )) {
                            FridayClipCropPopover(
                                clipPath: entry.clipPath,
                                trimIn: entry.trimIn,
                                trimOut: entry.trimOut,
                                cropOffset: cropBinding(index)
                            )
                        }

                        Button(entry.included ? "Exclude" : "Include") { toggleIncluded(index) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)

                        if let onSwap {
                            Button("Swap") { onSwap(entry.clipPath) }
                                .buttonStyle(.plain)
                                .font(.system(size: 10))
                                .foregroundStyle(PaintedSurfaces.pageAccentText)
                        }
                    }
                }

                HStack(spacing: Spacing.md) {
                    if let onToggleTitleCard {
                        Button(TitleCardToggleLabel.text(muted: titleCardMuted), action: onToggleTitleCard)
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                    }

                    if hasOverride, let onRecutWithAI {
                        Button("Re-cut with AI", action: onRecutWithAI)
                            .buttonStyle(BrandOutlineButtonStyle())
                    }
                }
                .padding(.top, Spacing.xs)
            }
            .disabled(isRegenerating)
        )
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard entries.indices.contains(target) else { return }
        var reordered = entries
        reordered.swapAt(index, target)
        for i in reordered.indices { reordered[i].order = i }
        onApply?(reordered)
    }

    private func toggleIncluded(_ index: Int) {
        var updated = entries
        updated[index].included.toggle()
        onApply?(updated)
    }

    /// (x, y) pair binding for one entry's crop offset: the popover edits
    /// both fields together, so a single Binding<(Double, Double)> avoids
    /// two separate onApply writes racing each other.
    private func cropBinding(_ index: Int) -> Binding<(x: Double, y: Double)> {
        Binding(
            get: { (entries[index].cropX, entries[index].cropY) },
            set: { newValue in
                var updated = entries
                updated[index].cropX = newValue.x
                updated[index].cropY = newValue.y
                onApply?(updated)
            }
        )
    }
}
/// Per-clip crop editor (plan #148, Phase 2): a 3-frame strip (start,
/// middle, end of the clip's trim window) so a crop that drifts off-subject
/// partway through a shot is visible before it ships, plus x/y sliders
/// mirroring PhotoAssignmentView's CropOffsetPopover for photos.
struct FridayClipCropPopover: View {
    let clipPath: String
    let trimIn: Double
    let trimOut: Double
    @Binding var cropOffset: (x: Double, y: Double)

    @State private var frames: [NSImage?] = [nil, nil, nil]

    private let previewW: Double = 72
    private let previewH: Double = 128

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("ADJUST CROP")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.0)
                .foregroundStyle(PaintedSurfaces.secondaryText)

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    framePreview(frames[i])
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("HORIZONTAL").font(.system(size: 8, weight: .medium)).tracking(0.8).foregroundStyle(PaintedSurfaces.secondaryText)
                HStack(spacing: 4) {
                    // Symbols rather than typed arrow characters (#538): a glyph
                    // renders at whatever size and weight the font decides, and
                    // is announced by its unicode name. Hidden, because they are
                    // decoration either side of the slider and the slider itself
                    // now carries the meaning.
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9)).foregroundStyle(PaintedSurfaces.secondaryText)
                        .accessibilityHidden(true)
                    Slider(value: $cropOffset.x, in: -1...1)
                        .tint(PaintedSurfaces.iconAccent)
                        .accessibilityLabel("Horizontal crop position")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(PaintedSurfaces.secondaryText)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("VERTICAL").font(.system(size: 8, weight: .medium)).tracking(0.8).foregroundStyle(PaintedSurfaces.secondaryText)
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9)).foregroundStyle(PaintedSurfaces.secondaryText)
                        .accessibilityHidden(true)
                    Slider(value: $cropOffset.y, in: -1...1)
                        .tint(PaintedSurfaces.iconAccent)
                        .accessibilityLabel("Vertical crop position")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9)).foregroundStyle(PaintedSurfaces.secondaryText)
                        .accessibilityHidden(true)
                }
            }

            if ClipCropFrameStrip.isCustomCrop(x: cropOffset.x, y: cropOffset.y) {
                Button("Reset to default") { cropOffset = (0, 0) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
            }
        }
        .padding(Spacing.md)
        .frame(width: 260)
        .background(PaintedSurfaces.page)
        .task(id: "\(clipPath)-\(trimIn)-\(trimOut)") {
            await loadFrames()
        }
    }

    @ViewBuilder
    private func framePreview(_ image: NSImage?) -> some View {
        Group {
            if let image {
                let (ox, oy) = shift(image: image, frameW: previewW, frameH: previewH)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .offset(x: cropOffset.x * ox, y: cropOffset.y * oy)
                    .frame(width: previewW, height: previewH)
                    .clipped()
            } else {
                PaintedSurfaces.photoPlaceholder
                    .frame(width: previewW, height: previewH)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private func shift(image: NSImage, frameW: Double, frameH: Double) -> (Double, Double) {
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return (0, 0) }
        let imageRatio = iw / ih
        let frameRatio = frameW / frameH
        if imageRatio > frameRatio {
            let scaledW = frameH * imageRatio
            return ((scaledW - frameW) / 2, 0)
        } else {
            let scaledH = frameW / imageRatio
            return (0, (scaledH - frameH) / 2)
        }
    }

    private func loadFrames() async {
        let times = ClipCropFrameStrip.sampleTimes(trimIn: trimIn, trimOut: trimOut)
        let asset = AVURLAsset(url: URL(fileURLWithPath: clipPath))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        var results: [NSImage?] = []
        for t in times {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: cmTime).image {
                results.append(NSImage(cgImage: cgImage, size: .zero))
            } else {
                results.append(nil)
            }
        }
        while results.count < 3 { results.append(nil) }
        frames = results
    }
}
