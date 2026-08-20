import SwiftUI
import UniformTypeIdentifiers
import AppKit


/// Full-width 9:16 collage thumbnail with drag-to-pan, per-cell zoom, and draggable frame dividers.
/// Drag any cell to reposition the photo within it; tap to select and reveal the SIZE slider.
/// Drag a horizontal divider handle to redistribute height between rows;
/// drag a vertical divider handle to redistribute width between adjacent columns.
struct CollagePreviewThumbnail: View {
    let url: URL
    let layoutURL: URL
    @Binding var cropOffsets: [String: CropOffset]
    var cellOverride: Binding<[CollageCell]?>
    let onPreview: () -> Void
    var isRegenerating: Bool = false
    var onRegenerate: (() -> Void)? = nil
    /// Replace the entire collage photo set with a freshly picked batch.
    var onChangePhotos: (() -> Void)? = nil
    /// The day's current photo set (the same URLs the draggable thumbnail strip
    /// uses). The layout JSON records whatever path Python used at generation
    /// time, but MediaReclaim may since have copied that file into app storage
    /// and rewritten the day's photoPaths. Rebasing JSON-loaded cells onto these
    /// by filename keeps each cell's photoPath equal to the drag-source path, so
    /// a swap matches the existing cell (instead of duplicating the photo) and
    /// per-cell crop keys still resolve.
    var photoURLs: [URL] = []

    @State private var image: NSImage?
    @State private var cells: [CollageCell] = []
    @State private var selectedCellIndex: Int? = nil
    @State private var dropTargetIdx: Int? = nil
    // Sampled from the loaded PNG's left-margin pixel so divider-drag fill
    // rectangles match Python's photo-tinted gap_color (varies per collage).
    @State private var gapColor: Color = PaintedSurfaces.deepPage

    private static let canvasW: Double = 1080
    private static let canvasH: Double = 1920

    private static func sampleGapColor(from nsImage: NSImage?) -> Color {
        guard let nsImage,
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return PaintedSurfaces.deepPage }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let sampled = bitmap.colorAt(x: 4, y: 4),
              let srgb = sampled.usingColorSpace(.sRGB)
        else { return PaintedSurfaces.deepPage }
        return Color(
            red:   Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue:  Double(srgb.blueComponent)
        )
    }

    /// Max display height: 75% of the screen's usable area so the collage always
    /// fits in the window without scrolling, regardless of screen size.
    private var maxCollageHeight: CGFloat {
        max(440, (NSScreen.main?.visibleFrame.height ?? 800) * 0.82)
    }

    /// Base cells — user-dragged override if present, otherwise JSON-loaded positions.
    /// An override that no longer fits the day's photo set is ignored here for the
    /// same reason the renderers ignore it: its cells name photos that are gone.
    private var baseCells: [CollageCell] {
        CollageCell.usable(cellOverride.wrappedValue, forPhotos: photoURLs) ?? cells
    }

    /// Re-links layout-JSON cell paths to the day's current photo set by
    /// filename. The override is already kept current by MediaReclaim
    /// (PostingDay.rebindingPhotos), so only the JSON-loaded cells need this.
    private func rebasedToCurrentPhotos(_ loaded: [CollageCell]) -> [CollageCell] {
        CollageCell.rebasing(loaded, toCurrentPhotos: photoURLs)
    }

    /// Drop a saved layout that can no longer describe the day's photo set, so it
    /// stops being written back to events.json on every save and stops suppressing
    /// the automatic layout. Editing the photos leaves exactly this behind.
    @MainActor
    private func discardUnusableOverride() {
        guard let stored = cellOverride.wrappedValue, !stored.isEmpty,
              CollageCell.usable(stored, forPhotos: photoURLs) == nil
        else { return }
        cellOverride.wrappedValue = nil
    }

    /// Renders the collage the way the editor shows it (base PNG plus the live
    /// SwiftUI crop overlays, same path the export uses via CollageRenderer) to a
    /// temp file and opens that, so the standalone preview reflects the crop/zoom
    /// the user set instead of Python's raw base PNG. Falls back to the base PNG
    /// if compositing fails.
    private func openComposited() {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("collage-preview-\(UUID().uuidString).png")
        if CollageRenderer.render(
            baseURL: url,
            cells: baseCells,
            cropOffsets: cropOffsets,
            outputURL: out
        ) {
            NSWorkspace.shared.open(out)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Collage image — full panel width, 9:16 aspect ratio
            GeometryReader { geo in
                let sx = geo.size.width  / Self.canvasW
                let sy = geo.size.height / Self.canvasH

                // Dividers are computed once from base cells.
                // Each CollageDividerHandle manages its own drag state internally
                // via @GestureState, so the parent never re-renders during a drag.
                let dividers = computeCollageDividers(baseCells)

                ZStack(alignment: .topLeading) {
                    // Base image — always visible so the branded strip (text + watermark)
                    // in the centre is preserved even when a cell override is active.
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            PaintedSurfaces.photoPlaceholder
                                .overlay { ProgressView().controlSize(.small).tint(PaintedSurfaces.photoPlaceholderSpinner) }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isRegenerating { selectedCellIndex = nil }
                    }

                    // Gap fill — covers stale PNG content showing through new gaps after a
                    // frame-divider drag. Cream rectangles are drawn at the current (post-drag)
                    // divider positions, sitting on top of the PNG but under cell overlays.
                    // Skip the strip divider (actualGapPx > 16 = the ~90px text/logo band).
                    if cellOverride.wrappedValue != nil {
                        ForEach(Array(dividers.enumerated()), id: \.0) { _, div in
                            if div.actualGapPx <= 16 {
                                switch div.kind {
                                case .horizontal:
                                    Rectangle()
                                        .fill(gapColor)
                                        .frame(width: geo.size.width,
                                               height: max(CGFloat(div.actualGapPx) * sy, 2))
                                        .position(
                                            x: geo.size.width / 2,
                                            y: CGFloat(div.canvasPos) * sy + CGFloat(div.actualGapPx) * sy / 2
                                        )
                                        .allowsHitTesting(false)
                                case .vertical:
                                    Rectangle()
                                        .fill(gapColor)
                                        .frame(width: max(CGFloat(div.actualGapPx) * sx, 2),
                                               height: CGFloat(div.rowCanvasH) * sy)
                                        .position(
                                            x: CGFloat(div.canvasPos) * sx,
                                            y: CGFloat(div.rowCanvasY + div.rowCanvasH / 2) * sy
                                        )
                                        .allowsHitTesting(false)
                                }
                            }
                        }

                        // Restroke the hairline ring the gap fill above just painted
                        // over. Without an override the PNG's own ring is untouched,
                        // so this only runs in the same case the gap fill does.
                        ForEach(Array(baseCells.enumerated()), id: \.0) { _, cell in
                            Rectangle()
                                .strokeBorder(CollageGeometry.hairlineColor,
                                              lineWidth: CollageGeometry.hairlineWidth)
                                .frame(width: CGFloat(cell.w) * sx + CollageGeometry.hairlineWidth * 2,
                                       height: CGFloat(cell.h) * sy + CollageGeometry.hairlineWidth * 2)
                                .position(
                                    x: CGFloat(cell.x) * sx + CGFloat(cell.w) * sx / 2,
                                    y: CGFloat(cell.y) * sy + CGFloat(cell.h) * sy / 2
                                )
                                .allowsHitTesting(false)
                        }
                    }

                    // Per-cell drag/tap targets — each in its own sub-view so
                    // @GestureState lives per-cell and doesn't break on re-render
                    ForEach(Array(baseCells.enumerated()), id: \.0) { idx, cell in
                        let photoKey = URL(fileURLWithPath: cell.photoPath).absoluteString
                        CollageCellOverlay(
                            cropOffset: Binding(
                                get: { cropOffsets[photoKey] ?? CropOffset() },
                                set: { cropOffsets[photoKey] = $0 }
                            ),
                            isSelected: selectedCellIndex == idx,
                            isDragTarget: dropTargetIdx == idx,
                            cellW: CGFloat(cell.w) * sx,
                            cellH: CGFloat(cell.h) * sy,
                            photoURL: URL(fileURLWithPath: cell.photoPath),
                            onTap: { selectedCellIndex = (selectedCellIndex == idx) ? nil : idx },
                            onDragEnd: { selectedCellIndex = idx }
                        )
                        .position(
                            x: CGFloat(cell.x) * sx + CGFloat(cell.w) * sx / 2,
                            y: CGFloat(cell.y) * sy + CGFloat(cell.h) * sy / 2
                        )
                    }

                    // Divider handles — hidden while a cell is selected or regenerating.
                    // Each handle owns its drag state via @GestureState internally;
                    // the parent only hears back once when the drag commits.
                    if selectedCellIndex == nil && !isRegenerating && !baseCells.isEmpty {
                        ForEach(Array(dividers.enumerated()), id: \.0) { _, div in
                            let scale = div.kind == .horizontal ? sy : sx
                            let minDelta = CGFloat(div.minPos - div.canvasPos) * scale
                            let maxDelta = CGFloat(div.maxPos - div.canvasPos) * scale
                            switch div.kind {
                            case .horizontal:
                                CollageDividerHandle(
                                    kind: .horizontal,
                                    displayLength: geo.size.width,
                                    minDelta: minDelta,
                                    maxDelta: maxDelta
                                ) { finalDeltaPx in
                                    // Persist the frame change to the override only.
                                    // The setter saves it, and CollageRenderer composites
                                    // it at export — no Python regen, which would re-roll
                                    // the whole layout. Use the ↺ button to regenerate.
                                    cellOverride.wrappedValue = applyCollageDividerDelta(
                                        to: baseCells, divider: div,
                                        delta: Int(finalDeltaPx / sy))
                                }
                                .position(
                                    x: geo.size.width / 2,
                                    y: CGFloat(div.canvasPos) * sy
                                )
                            case .vertical:
                                CollageDividerHandle(
                                    kind: .vertical,
                                    displayLength: CGFloat(div.rowCanvasH) * sy,
                                    minDelta: minDelta,
                                    maxDelta: maxDelta
                                ) { finalDeltaPx in
                                    // See the horizontal handle above: persist only, no regen.
                                    cellOverride.wrappedValue = applyCollageDividerDelta(
                                        to: baseCells, divider: div,
                                        delta: Int(finalDeltaPx / sx))
                                }
                                .position(
                                    x: CGFloat(div.canvasPos) * sx,
                                    y: CGFloat(div.rowCanvasY + div.rowCanvasH / 2) * sy
                                )
                            }
                        }
                    }

                    // Regenerating overlay
                    if isRegenerating {
                        PaintedSurfaces.photoScrim
                            .overlay {
                                VStack(spacing: 6) {
                                    ProgressView().controlSize(.small).tint(PaintedSurfaces.photoScrimText)
                                    Text("Regenerating…")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(PaintedSurfaces.photoScrimText)
                                }
                            }
                    }

                    // No-cells callout — collage was generated before layout JSON existed
                    if cells.isEmpty && cellOverride.wrappedValue == nil && image != nil && !isRegenerating {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(PaintedSurfaces.iconAccent)
                            // Names the control rather than drawing it (#538).
                            // Drawn, this sentence said nothing at all to anyone
                            // who cannot see the glyph, and nothing connected the
                            // two (L80). "Reset zoom" is exactly what that button
                            // is called on the row below.
                            Text("Click Reset zoom below\nto enable cell editing")
                                .font(.system(size: 10, weight: .medium))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(PaintedSurfaces.photoScrimText)
                        }
                        .padding(12)
                        .background(PaintedSurfaces.photoHintPanel.clipShape(RoundedRectangle(cornerRadius: 8)))
                        .allowsHitTesting(false)
                    }
                }
                // Single drop target on the whole ZStack — avoids the SwiftUI bug where
                // .position() children each claim the full parent area, causing only the
                // last-rendered cell to receive drops. Hit-test using cell rects + location.
                .onDrop(of: [UTType.plainText], isTargeted: Binding(
                    get: { dropTargetIdx != nil },
                    set: { if !$0 { dropTargetIdx = nil } }
                )) { providers, location in
                    guard let provider = providers.first else { return false }
                    let targetIdx = baseCells.firstIndex { cell in
                        CGRect(
                            x: CGFloat(cell.x) * sx,
                            y: CGFloat(cell.y) * sy,
                            width: CGFloat(cell.w) * sx,
                            height: CGFloat(cell.h) * sy
                        ).contains(location)
                    }
                    guard let idx = targetIdx else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                        guard let droppedPath = (item as? NSString).map(String.init) else { return }
                        DispatchQueue.main.async {
                            guard let newCells = CollageCell.applyingDrop(
                                of: droppedPath, ontoCellAt: idx, in: baseCells
                            ) else { return }
                            // Persist the swap to the override only. The setter saves
                            // it and CollageRenderer composites it at export — no Python
                            // regen, which would re-roll the layout and discard the swap.
                            cellOverride.wrappedValue = newCells
                        }
                    }
                    dropTargetIdx = nil
                    return true
                }
            }
            .aspectRatio(9/16, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: maxCollageHeight)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 0.5)
            )
            .overlay(alignment: .bottomTrailing) {
                Button { openComposited() } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 13))
                        .foregroundStyle(PaintedSurfaces.photoScrimIcon)
                        .padding(7)
                        .background(PaintedSurfaces.photoScrim)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open the collage at full size")
                .help("Open the collage at full size")
                .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if let onRegenerate {
                    Button(action: onRegenerate) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundStyle(PaintedSurfaces.photoScrimIcon)
                            .padding(7)
                            .background(PaintedSurfaces.photoScrim)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Regenerate the collage")
                    .disabled(isRegenerating)
                    .help("Regenerate collage with current crop and frame adjustments")
                    .padding(6)
                }
            }
            // Reset to the automatic layout (#161). Once a day has a saved cell
            // override the renderer takes that branch forever, so a hand-dragged
            // collage could never get back to the planner, and after the gallery
            // mat change it kept the old edge-to-edge geometry with no way to
            // opt in to the new design. Only shown when there IS an override,
            // so it never offers to undo something that was never done.
            .overlay(alignment: .topTrailing) {
                if CollageLayoutReset.isOffered(cellOverride: cellOverride.wrappedValue) {
                    Button {
                        let outcome = CollageLayoutReset.apply(
                            cellOverride: cellOverride.wrappedValue)
                        cellOverride.wrappedValue = outcome.cellOverride
                        selectedCellIndex = outcome.selectedCellIndex
                        if outcome.shouldRegenerate { onRegenerate?() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 13))
                            .foregroundStyle(PaintedSurfaces.photoScrimIcon)
                            .padding(7)
                            .background(PaintedSurfaces.photoScrim)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Undo the layout changes")
                    .disabled(isRegenerating)
                    .help("Reset to the automatic layout, discarding your dragged arrangement")
                    .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if let onChangePhotos {
                    Button(action: onChangePhotos) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 13))
                            .foregroundStyle(PaintedSurfaces.photoScrimIcon)
                            .padding(7)
                            .background(PaintedSurfaces.photoScrim)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose different photos")
                    .disabled(isRegenerating)
                    .help("Replace all collage photos with a new set")
                    .padding(6)
                }
            }

            // SIZE slider — always reserves its height so the collage doesn't
            // jump when a cell is first selected. Content fades in/out.
            HStack(spacing: 6) {
                if let idx = selectedCellIndex, idx < baseCells.count {
                    let photoKey = URL(fileURLWithPath: baseCells[idx].photoPath).absoluteString
                    let scaleBinding = Binding<Double>(
                        get: { cropOffsets[photoKey]?.scale ?? 1.0 },
                        set: {
                            var o = cropOffsets[photoKey] ?? CropOffset()
                            o.scale = $0
                            cropOffsets[photoKey] = o
                        }
                    )
                    let hasAdjust = (cropOffsets[photoKey]?.scale ?? 1.0) != 1.0

                    Image(systemName: "photo")
                        .font(.system(size: 9))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    Slider(value: scaleBinding, in: 0.25...2.5)
                    .tint(PaintedSurfaces.iconAccent)
                    Image(systemName: "photo.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    if hasAdjust {
                        // A symbol rather than a typed glyph, and named, because
                        // this is a control: nothing else on the row says what it
                        // does, and the instruction over the collage points at it
                        // by this name (#538).
                        Button {
                            var o = cropOffsets[photoKey] ?? CropOffset()
                            o.scale = 1.0
                            cropOffsets[photoKey] = o
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                                .foregroundStyle(PaintedSurfaces.iconAccent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reset zoom")
                        .help("Reset zoom")
                    }
                }
            }
            .frame(height: 22)  // always occupies space — no layout jump
            .padding(.horizontal, 2)
            .animation(.easeOut(duration: 0.15), value: selectedCellIndex != nil)

            // Frame edits (divider drags, photo swaps) are saved to the cell
            // override the moment they happen and composited by CollageRenderer
            // in both the preview and the export. There is nothing to "apply" via
            // Python — a regen here would re-roll the grid and discard the edit
            // (see the collage-edits-no-Python-regen rule). So this is a passive
            // confirmation, not an action button.
            if cellOverride.wrappedValue != nil {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.iconAccent)
                    Text("Frame changes saved — they'll appear in the exported collage")
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: cellOverride.wrappedValue != nil)
        // Re-runs automatically when url changes (Python wrote a new file path).
        // Both image and cells are awaited concurrently then committed in a single
        // MainActor.run so SwiftUI fires exactly one render — no intermediate flash
        // where the PNG is visible but the cell overlays haven't appeared yet.
        .task(id: url) {
            async let bytes   = ImageLoad.bytes(url)
            async let decoded = Task.detached {
                LayoutSidecar.read(at: layoutURL).cells
            }.value
            let (loadedBytes, loadedCells) = await (bytes, decoded)
            let loadedImage = loadedBytes.flatMap { NSImage(data: $0) }
            let sampledGap = Self.sampleGapColor(from: loadedImage)
            await MainActor.run {
                image = loadedImage
                cells = rebasedToCurrentPhotos(loadedCells)
                gapColor = sampledGap
                discardUnusableOverride()
            }
        }
        // Reload PNG + layout JSON when Python regeneration finishes in-place
        // (same file path, new content — .task(id: url) won't re-fire in this case)
        .onChange(of: isRegenerating) { _, nowRegenerating in
            if !nowRegenerating {
                Task {
                    async let bytes   = ImageLoad.bytes(url)
                    async let decoded = Task.detached {
                        LayoutSidecar.read(at: layoutURL).cells
                    }.value
                    let (loadedBytes, loadedCells) = await (bytes, decoded)
                    let loadedImage = loadedBytes.flatMap { NSImage(data: $0) }
                    let sampledGap = Self.sampleGapColor(from: loadedImage)
                    // Commit image, cells, and override-clear in one render cycle.
                    await MainActor.run {
                        image = loadedImage
                        cells = rebasedToCurrentPhotos(loadedCells)
                        gapColor = sampledGap
                        cellOverride.wrappedValue = nil
                    }
                }
            }
        }
        // Cell override is saved to AppState on every drag commit.
        // Regeneration is triggered manually via the ↺ button.
    }
}
