import SwiftUI
import AppKit


struct ReelStripLayout: Decodable {
    let stripWidth: Int
    let stripHeight: Int
    let cells: [CollageCell]

    enum CodingKeys: String, CodingKey {
        case stripWidth = "strip_width"
        case stripHeight = "strip_height"
        case cells
    }
}
/// Vertical scroll editor for the Thursday reel strip. Shows the full masonry
/// strip inside a ScrollView, overlays per-cell pan/zoom controls on top of
/// each photo cell, and reuses CollageCellOverlay so live dragging matches
/// Python's crop_to_fill output exactly.
struct ReelStripPreviewThumbnail: View {
    let url: URL
    let layoutURL: URL
    @Binding var cropOffsets: [String: CropOffset]
    var isRegenerating: Bool = false
    var onRegenerate: (() -> Void)? = nil
    var onNewLayout: (() -> Void)? = nil
    var onSwapAudio: (() -> Void)? = nil
    var onUploadAudio: (() -> Void)? = nil
    var onChangePhotos: (() -> Void)? = nil
    var onSwapPhotos: ((URL, URL) -> Void)? = nil
    /// Current reel length (scroll seconds) — drives the checkmark in the
    /// "Reel length" submenu. nil hides the submenu.
    var currentReelLength: Double? = nil
    var onChangeReelLength: ((Double) -> Void)? = nil
    var maxHeight: CGFloat = 600

    /// Preset reel lengths offered in the menu (scroll seconds, 15–60 range).
    /// The PhotoAssignmentView slider still covers in-between values.
    private static let reelLengthPresets: [Int] = [15, 20, 30, 40, 50, 60]

    @State private var image: NSImage?
    @State private var cells: [CollageCell] = []
    @State private var stripW: CGFloat = 1080
    @State private var stripH: CGFloat = 1920
    @State private var selectedCellIndex: Int? = nil
    // Swap mode — entered from the menu. swapSourceIdx tracks the first
    // cell tapped; the next cell tap completes the swap and exits the mode.
    @State private var swapMode: Bool = false
    @State private var swapSourceIdx: Int? = nil

    /// One sentence when this reel is faster than is comfortable to watch.
    ///
    /// A computed property rather than the call inline in `body`, which is
    /// already large enough that the type checker feels it.
    ///
    /// Nil until a length is known: `currentReelLength` is only passed on
    /// Thursday, and every other caller of this view has no reel length to be
    /// fast at.
    /// Whether the pace sample is open.
    @State private var showingPace = false

    private var speedNotice: String? {
        guard let currentReelLength else { return nil }
        return ScrollReelTiming.speedNotice(
            stripHeight: Double(stripH),
            photoCount: cells.count,
            scrollSeconds: currentReelLength)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if swapMode {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.iconAccent)
                    Text(swapSourceIdx == nil
                         ? "Tap the photo you want to move"
                         : "Tap the spot you want to swap it with")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                    Spacer()
                    Button("Cancel") {
                        swapMode = false
                        swapSourceIdx = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(PaintedSurfaces.taggedAccountsFill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            GeometryReader { geo in
                let sx = geo.size.width / max(stripW, 1)
                let displayH = stripH * sx

                ScrollView(.vertical, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        Group {
                            if let image {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                PaintedSurfaces.photoPlaceholder
                                    .overlay { ProgressView().controlSize(.small).tint(PaintedSurfaces.photoPlaceholderSpinner) }
                            }
                        }
                        .frame(width: geo.size.width, height: displayH)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isRegenerating {
                                if swapMode {
                                    swapMode = false
                                    swapSourceIdx = nil
                                } else {
                                    selectedCellIndex = nil
                                }
                            }
                        }

                        ForEach(Array(cells.enumerated()), id: \.0) { idx, cell in
                            let photoKey = URL(fileURLWithPath: cell.photoPath).absoluteString
                            CollageCellOverlay(
                                cropOffset: Binding(
                                    get: { cropOffsets[photoKey] ?? CropOffset() },
                                    set: { cropOffsets[photoKey] = $0 }
                                ),
                                isSelected: !swapMode && selectedCellIndex == idx,
                                isDragTarget: swapMode && swapSourceIdx == idx,
                                cellW: CGFloat(cell.w) * sx,
                                cellH: CGFloat(cell.h) * sx,
                                photoURL: URL(fileURLWithPath: cell.photoPath),
                                onTap: { handleCellTap(idx: idx) },
                                onDragEnd: { if !swapMode { selectedCellIndex = idx } }
                            )
                            .position(
                                x: CGFloat(cell.x) * sx + CGFloat(cell.w) * sx / 2,
                                y: CGFloat(cell.y) * sx + CGFloat(cell.h) * sx / 2
                            )
                        }

                        if isRegenerating {
                            PaintedSurfaces.photoScrim
                                .frame(width: geo.size.width, height: displayH)
                                .overlay {
                                    VStack(spacing: 6) {
                                        ProgressView().controlSize(.small).tint(PaintedSurfaces.photoScrimText)
                                        Text("Regenerating…")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(PaintedSurfaces.photoScrimText)
                                    }
                                }
                        }
                    }
                    .frame(width: geo.size.width, height: displayH)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if onRegenerate != nil || onSwapAudio != nil || onUploadAudio != nil || onChangePhotos != nil || onChangeReelLength != nil {
                    Menu {
                        if let onRegenerate {
                            Button {
                                onRegenerate()
                            } label: {
                                Label(isRegenerating ? "Regenerating…" : "Regenerate reel", systemImage: "arrow.clockwise")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onNewLayout {
                            Button {
                                onNewLayout()
                            } label: {
                                Label("New layout (re-roll)", systemImage: "shuffle")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onChangeReelLength {
                            Menu {
                                ForEach(Self.reelLengthPresets, id: \.self) { secs in
                                    Button {
                                        onChangeReelLength(Double(secs))
                                    } label: {
                                        if let current = currentReelLength, Int(current.rounded()) == secs {
                                            Label("\(secs)s", systemImage: "checkmark")
                                        } else {
                                            Text("\(secs)s")
                                        }
                                    }
                                }
                            } label: {
                                Label("Reel length", systemImage: "timer")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onChangePhotos {
                            Button {
                                onChangePhotos()
                            } label: {
                                Label("Change photos", systemImage: "photo.on.rectangle.angled")
                            }
                            .disabled(isRegenerating)
                        }
                        if onSwapPhotos != nil {
                            Button {
                                swapMode = true
                                swapSourceIdx = nil
                                selectedCellIndex = nil
                            } label: {
                                Label("Swap two photos", systemImage: "arrow.left.arrow.right")
                            }
                            .disabled(isRegenerating || cells.count < 2)
                        }
                        if let onSwapAudio {
                            Button {
                                onSwapAudio()
                            } label: {
                                Label("New Jamendo audio", systemImage: "music.note")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onUploadAudio {
                            Button {
                                onUploadAudio()
                            } label: {
                                Label("Upload my own audio", systemImage: "square.and.arrow.down")
                            }
                            .disabled(isRegenerating)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(PaintedSurfaces.photoScrimIcon)
                            .padding(8)
                            .background(PaintedSurfaces.photoScrim)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel("Graphic options")
                    .help("Graphic options")
                    .fixedSize()
                    .padding(10)
                }
            }

            // How fast this reel will read, before it is rendered (#1066).
            //
            // In the panel rather than inside the options menu, which is where
            // the length control lives: a menu closes, and this is a standing
            // fact about the reel as it is currently set up, not a response to
            // an action (L126).
            if let speedNotice {
                Text(speedNotice)
                    .font(.light(11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            // The number says it is fast; this lets Dan check (#1071). Offered
            // whenever there is a length and a strip that scrolls, not only
            // when the warning fires: a reel judged comfortable by the
            // threshold is exactly the one worth confirming by eye.
            if let currentReelLength, image != nil, stripH > CGFloat(ScrollReelTiming.paceWindowHeight) {
                Button {
                    showingPace = true
                } label: {
                    Label("Watch the pace", systemImage: "play.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PaintedSurfaces.iconAccent)
                .padding(.horizontal, 2)
                .popover(isPresented: $showingPace, arrowEdge: .bottom) {
                    if let image {
                        ReelPaceSampler(
                            strip: image,
                            stripCanvasHeight: Double(stripH),
                            scrollSeconds: currentReelLength,
                            onClose: { showingPace = false })
                            .frame(width: 320)
                    }
                }
            }

            // Size slider — always reserves its height so the strip doesn't
            // jump when a cell is first selected. Content fades in/out.
            HStack(spacing: 6) {
                if let idx = selectedCellIndex, idx < cells.count {
                    let photoKey = URL(fileURLWithPath: cells[idx].photoPath).absoluteString
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
            .frame(height: 22)
            .padding(.horizontal, 2)
            .animation(.easeOut(duration: 0.15), value: selectedCellIndex != nil)

            // Apply-changes bar — explicit, always visible so the user knows
            // how to bake their crops into the actual MP4. Matches Wednesday's
            // "Apply frame changes" pattern.
            if let onRegenerate {
                HStack(spacing: Spacing.sm) {
                    Text(isRegenerating
                         ? "Rebuilding reel…"
                         : "Drag photos to pan · tap for zoom")
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    Spacer()
                    if onSwapPhotos != nil && !swapMode {
                        Button {
                            swapMode = true
                            swapSourceIdx = nil
                            selectedCellIndex = nil
                        } label: {
                            Label("Swap photos", systemImage: "arrow.left.arrow.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(PaintedSurfaces.pageAccentText)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRegenerating || cells.count < 2)
                    }
                    Button(isRegenerating ? "Rebuilding…" : "Apply changes") {
                        onRegenerate()
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(isRegenerating)
                }
                .padding(.horizontal, 2)
            }
        }
        .task(id: url) {
            // Through `ImageLoad.read` rather than bytes plus `NSImage(data:)`
            // (#1117): that pair reads off the main actor and then DECODES on
            // it, which is the lazy main thread decode #966 removed everywhere
            // else. This strip carries no colour sampling, so nothing here
            // depends on the pixels beyond drawing them.
            async let loaded = ImageLoad.read(url, fitting: maxHeight)
            async let decoded = Task.detached {
                (try? JSONDecoder().decode(ReelStripLayout.self, from: Data(contentsOf: layoutURL)))
            }.value
            let (load, layout) = await (loaded, decoded)
            let loadedImage = load.image
            await MainActor.run {
                image = loadedImage
                if let layout {
                    stripW = CGFloat(layout.stripWidth)
                    stripH = CGFloat(layout.stripHeight)
                    cells = layout.cells
                }
            }
        }
        .onChange(of: isRegenerating) { _, nowRegenerating in
            if !nowRegenerating {
                Task {
                    async let loaded = ImageLoad.read(url, fitting: maxHeight)
                    async let decoded = Task.detached {
                        (try? JSONDecoder().decode(ReelStripLayout.self, from: Data(contentsOf: layoutURL)))
                    }.value
                    let (load, layout) = await (loaded, decoded)
                    let loadedImage = load.image
                    await MainActor.run {
                        image = loadedImage
                        if let layout {
                            stripW = CGFloat(layout.stripWidth)
                            stripH = CGFloat(layout.stripHeight)
                            cells = layout.cells
                        }
                    }
                }
            }
        }
    }

    private func handleCellTap(idx: Int) {
        if swapMode {
            if let src = swapSourceIdx {
                if src == idx {
                    swapSourceIdx = nil
                } else if let onSwap = onSwapPhotos,
                          src < cells.count, idx < cells.count {
                    let a = URL(fileURLWithPath: cells[src].photoPath)
                    let b = URL(fileURLWithPath: cells[idx].photoPath)
                    // Swap the local cells so the overlay layer immediately
                    // shows photos in their new positions on top of the stale
                    // base PNG. Regen happens later via "Apply changes".
                    cells[src].photoPath = b.path
                    cells[idx].photoPath = a.path
                    onSwap(a, b)
                    swapMode = false
                    swapSourceIdx = nil
                }
            } else {
                swapSourceIdx = idx
            }
        } else {
            selectedCellIndex = (selectedCellIndex == idx) ? nil : idx
        }
    }
}
