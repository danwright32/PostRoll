import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Main View

struct PhotoAssignmentView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var dayPhotos: [DayName: [URL]]
    @State private var blogPhotos: [URL]
    @State private var pickerTarget: PickerTarget? = nil

    // Tuesday: speed edit reel inputs
    @State private var tuesdayScreenRecording: URL?
    @State private var tuesdayRawPhoto: URL?
    @State private var tuesdayEditedPhoto: URL?
    @State private var tuesdayTargetDuration: Double = 20.0

    // Thursday: scroll reel
    @State private var thursdayAudio: URL?
    @State private var thursdayScrollDuration: Double = 30.0
    @State private var thursdayReelSeed: Int? = nil

    // Wednesday: collage
    @State private var wednesdayCollageSeed: Int? = nil

    // Friday: before/after story
    @State private var fridayRawPhoto: URL?
    @State private var fridayEditedPhoto: URL?

    // Crop offsets for Wednesday + Thursday photos (keyed by photo URL absoluteString)
    @State private var dayCropOffsets: [DayName: [String: CropOffset]] = [:]

    var totalPhotos: Int { dayPhotos.values.reduce(0) { $0 + $1.count } }

    enum PickerTarget: Equatable {
        case day(DayName)
        case blog
        case tuesdayScreenRecording
        case tuesdayRawPhoto
        case tuesdayEditedPhoto
        case thursdayAudio
        case fridayRawPhoto
        case fridayEditedPhoto
    }

    init(event: Event) {
        self.event = event
        var loaded: [DayName: [URL]] = [:]
        for day in DayName.allCases { loaded[day] = event.days[day.rawValue]?.photoPaths ?? [] }
        _dayPhotos  = State(initialValue: loaded)
        _blogPhotos = State(initialValue: event.blogPhotoPaths)

        let tue = event.days[DayName.tuesday.rawValue]
        _tuesdayScreenRecording = State(initialValue: tue?.screenRecordingPath)
        _tuesdayRawPhoto        = State(initialValue: tue?.rawPhotoPath)
        _tuesdayEditedPhoto     = State(initialValue: tue?.editedPhotoPath)
        _tuesdayTargetDuration  = State(initialValue: tue?.reelTargetDuration ?? 20.0)

        let thu = event.days[DayName.thursday.rawValue]
        _thursdayAudio        = State(initialValue: thu?.audioPath)
        _thursdayScrollDuration = State(initialValue: thu?.scrollDuration ?? 30.0)
        _thursdayReelSeed     = State(initialValue: thu?.reelSeed)

        let wed = event.days[DayName.wednesday.rawValue]
        _wednesdayCollageSeed = State(initialValue: wed?.collageSeed)

        let fri = event.days[DayName.friday.rawValue]
        _fridayRawPhoto    = State(initialValue: fri?.rawPhotoPath)
        _fridayEditedPhoto = State(initialValue: fri?.editedPhotoPath)

        // Load crop offsets for all days
        var offsets: [DayName: [String: CropOffset]] = [:]
        for day in DayName.allCases {
            if let existing = event.days[day.rawValue]?.cropOffsets, !existing.isEmpty {
                offsets[day] = existing
            }
        }
        _dayCropOffsets = State(initialValue: offsets)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                EventHeader(event: event, subtitle: "Assign Photos")
                    .padding([.horizontal, .top], Spacing.xl)
                    .padding(.bottom, Spacing.sm)

                StageBackButton(label: "Back to OCR review") {
                    var ev = event; ev.stage = .ocrDone; appState.updateEvent(ev)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)

                BrandBanner(
                    icon: "rectangle.3.group",
                    message: "Drop photos into each posting day. Wednesday and Thursday show a crop button on each photo — use it to reframe before generating."
                )
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.lg)

                ForEach(DayName.allCases, id: \.self) { day in
                    let enableCrop = (day == .wednesday || day == .thursday)
                    let wednesdayCount = day == .wednesday ? (dayPhotos[.wednesday]?.count ?? 0) : 0
                    let note: String? = day == .wednesday && wednesdayCount > 10
                        ? "Collage uses the first 10 photos (\(wednesdayCount) assigned). Drag to reorder."
                        : nil

                    PhotoDaySection(
                        label: day.displayName,
                        collageNote: note,
                        photos: dayBinding(day),
                        cropOffsets: enableCrop ? cropOffsetsBinding(day) : nil,
                        onAddPhotos: { pickerTarget = .day(day) }
                    )

                    // Day-specific special input sections
                    switch day {
                    case .tuesday:
                        TuesdayReelSection(
                            screenRecording: $tuesdayScreenRecording,
                            rawPhoto:        $tuesdayRawPhoto,
                            editedPhoto:     $tuesdayEditedPhoto,
                            targetDuration:  $tuesdayTargetDuration,
                            onPickScreenRecording: { pickerTarget = .tuesdayScreenRecording },
                            onPickRawPhoto:        { pickerTarget = .tuesdayRawPhoto },
                            onPickEditedPhoto:     { pickerTarget = .tuesdayEditedPhoto }
                        )
                        .onChange(of: tuesdayScreenRecording) { _, _ in save() }
                        .onChange(of: tuesdayRawPhoto)        { _, _ in save() }
                        .onChange(of: tuesdayEditedPhoto)     { _, _ in save() }
                        .onChange(of: tuesdayTargetDuration)  { _, _ in save() }

                    case .wednesday:
                        WednesdayCollageSection(
                            photoCount:  dayPhotos[.wednesday]?.count ?? 0,
                            collageSeed: $wednesdayCollageSeed
                        )
                        .onChange(of: wednesdayCollageSeed) { _, _ in save() }

                    case .thursday:
                        ThursdayReelSection(
                            audio:          $thursdayAudio,
                            scrollDuration: $thursdayScrollDuration,
                            reelSeed:       $thursdayReelSeed,
                            onPickAudio:    { pickerTarget = .thursdayAudio }
                        )
                        .onChange(of: thursdayAudio)         { _, _ in save() }
                        .onChange(of: thursdayScrollDuration){ _, _ in save() }
                        .onChange(of: thursdayReelSeed)      { _, _ in save() }

                    case .friday:
                        FridayBeforeAfterSection(
                            rawPhoto:       $fridayRawPhoto,
                            editedPhoto:    $fridayEditedPhoto,
                            onPickRawPhoto:    { pickerTarget = .fridayRawPhoto },
                            onPickEditedPhoto: { pickerTarget = .fridayEditedPhoto }
                        )
                        .onChange(of: fridayRawPhoto)    { _, _ in save() }
                        .onChange(of: fridayEditedPhoto) { _, _ in save() }

                    default:
                        EmptyView()
                    }
                }

                PhotoDaySection(
                    label: "Blog Photos",
                    subtitle: "Appear in the full blog post",
                    photos: blogBinding,
                    onAddPhotos: { pickerTarget = .blog }
                )

                HStack {
                    Spacer()
                    Button("Continue to Generation") { advance() }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(totalPhotos == 0)
                }
                .padding(Spacing.xl)
            }
        }
        .background(Color.cream)
        .fileImporter(
            isPresented: Binding(get: { pickerTarget != nil }, set: { if !$0 { pickerTarget = nil } }),
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: isMultiSelection
        ) { result in
            if case .success(let urls) = result { handlePickedFiles(urls) }
            pickerTarget = nil
        }
    }

    // MARK: - File picker config

    private var allowedTypes: [UTType] {
        switch pickerTarget {
        case .tuesdayScreenRecording:
            return [.movie, .video, .mpeg4Movie, UTType(filenameExtension: "mov") ?? .movie]
        case .thursdayAudio:
            return [.audio, .mp3, .aiff,
                    UTType(filenameExtension: "m4a") ?? .audio,
                    UTType(filenameExtension: "aac") ?? .audio]
        default:
            return [.image]
        }
    }

    private var isMultiSelection: Bool {
        switch pickerTarget {
        case .day, .blog: return true
        default: return false
        }
    }

    // MARK: - Bindings

    private func dayBinding(_ day: DayName) -> Binding<[URL]> {
        Binding(
            get: { dayPhotos[day] ?? [] },
            set: { dayPhotos[day] = $0; save() }
        )
    }

    private var blogBinding: Binding<[URL]> {
        Binding(
            get: { blogPhotos },
            set: { blogPhotos = $0; save() }
        )
    }

    private func cropOffsetsBinding(_ day: DayName) -> Binding<[String: CropOffset]> {
        Binding(
            get: { dayCropOffsets[day] ?? [:] },
            set: { dayCropOffsets[day] = $0; save() }
        )
    }

    // MARK: - File handling

    private func handlePickedFiles(_ urls: [URL]) {
        guard let url = urls.first else { return }
        switch pickerTarget {
        case .day(let day):
            var list = dayPhotos[day] ?? []
            for u in urls where !list.contains(u) { list.append(u) }
            dayPhotos[day] = list
        case .blog:
            for u in urls where !blogPhotos.contains(u) { blogPhotos.append(u) }
        case .tuesdayScreenRecording: tuesdayScreenRecording = url
        case .tuesdayRawPhoto:        tuesdayRawPhoto = url
        case .tuesdayEditedPhoto:     tuesdayEditedPhoto = url
        case .thursdayAudio:          thursdayAudio = url
        case .fridayRawPhoto:         fridayRawPhoto = url
        case .fridayEditedPhoto:      fridayEditedPhoto = url
        case nil: break
        }
        save()
    }

    // MARK: - Persistence

    private func save() {
        var ev = event
        for day in DayName.allCases {
            var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
            pd.photoPaths  = dayPhotos[day] ?? []
            pd.cropOffsets = dayCropOffsets[day] ?? [:]
            switch day {
            case .tuesday:
                pd.screenRecordingPath = tuesdayScreenRecording
                pd.rawPhotoPath        = tuesdayRawPhoto
                pd.editedPhotoPath     = tuesdayEditedPhoto
                pd.reelTargetDuration  = tuesdayTargetDuration
            case .thursday:
                pd.audioPath      = thursdayAudio
                pd.scrollDuration = thursdayScrollDuration
                pd.reelSeed       = thursdayReelSeed
            case .wednesday:
                pd.collageSeed = wednesdayCollageSeed
            case .friday:
                pd.rawPhotoPath    = fridayRawPhoto
                pd.editedPhotoPath = fridayEditedPhoto
            default: break
            }
            ev.days[day.rawValue] = pd
        }
        ev.blogPhotoPaths = blogPhotos
        appState.updateEvent(ev)
    }

    private func advance() {
        save()
        var ev = event
        ev.stage = .assetsGenerated
        appState.updateEvent(ev)
    }
}

// MARK: - Photo Day Section

private struct PhotoDaySection: View {
    let label: String
    var subtitle: String? = nil
    var collageNote: String? = nil
    @Binding var photos: [URL]
    var cropOffsets: Binding<[String: CropOffset]>? = nil
    let onAddPhotos: () -> Void

    @State private var isExpanded = true
    @State private var isDropTargeted = false
    @State private var reorderTargetIndex: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button(action: { isExpanded.toggle() }) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Spacing.sm) {
                            Text(label.uppercased())
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.2)
                                .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                            if !photos.isEmpty { PhotoCountBadge(count: photos.count) }
                        }
                        if let subtitle {
                            Text(subtitle).font(.light(11)).foregroundStyle(Color.warmMid)
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if photos.isEmpty {
                        PhotoDropZone(isTargeted: isDropTargeted)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: Spacing.sm) {
                            ForEach(Array(photos.enumerated()), id: \.offset) { i, url in
                                thumbView(for: url, at: i)
                                    .draggable(i.description)
                                    .dropDestination(for: String.self) { items, _ in
                                        guard let src = items.first, let srcIdx = Int(src), srcIdx != i else { return false }
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            photos.move(fromOffsets: IndexSet(integer: srcIdx),
                                                        toOffset: srcIdx < i ? i + 1 : i)
                                        }
                                        return true
                                    } isTargeted: { targeted in
                                        reorderTargetIndex = targeted ? i : nil
                                    }
                            }
                        }
                    }
                    if let collageNote {
                        Text(collageNote).font(.system(size: 10)).foregroundStyle(Color.warmMid).padding(.top, 2)
                    }
                    Button(photos.isEmpty ? "Add Photos…" : "Add more…", action: onAddPhotos)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.roseGold)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
                .background(isDropTargeted ? Color.roseGold.opacity(0.03) : Color.clear)
            }

            RoseGoldDivider(opacity: 0.3)
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { handleDrop($0) }
    }

    @ViewBuilder
    private func thumbView(for url: URL, at i: Int) -> some View {
        if let offsetsBinding = cropOffsets {
            let cropBinding = Binding<CropOffset>(
                get: { offsetsBinding.wrappedValue[url.absoluteString] ?? CropOffset() },
                set: { offsetsBinding.wrappedValue[url.absoluteString] = $0 }
            )
            CroppablePhotoThumb(url: url, cropOffset: cropBinding,
                                isReorderTarget: reorderTargetIndex == i,
                                onRemove: { photos.remove(at: i) })
        } else {
            PhotoThumb(url: url, isReorderTarget: reorderTargetIndex == i) {
                photos.remove(at: i)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in if !photos.contains(url) { photos.append(url) } }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    guard let url else { return }
                    let captured = url
                    Task { @MainActor in if !photos.contains(captured) { photos.append(captured) } }
                }
            }
        }
        return true
    }
}

// MARK: - Croppable Photo Thumb

private struct CroppablePhotoThumb: View {
    let url: URL
    @Binding var cropOffset: CropOffset
    var isReorderTarget: Bool = false
    let onRemove: () -> Void

    @State private var image: NSImage?
    @State private var showingCropPopover = false

    var hasCrop: Bool { cropOffset.x != 0 || cropOffset.y != 0 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    let (ox, oy) = imageShift(image: image, frameW: 80, frameH: 80)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .offset(x: cropOffset.x * ox, y: cropOffset.y * oy)
                        .frame(width: 80, height: 80)
                        .clipped()
                } else {
                    Color.creamDeep
                        .overlay { ProgressView().controlSize(.small).tint(Color.roseGold) }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(
                        isReorderTarget ? Color.roseGold : (hasCrop ? Color.roseGold.opacity(0.5) : Color.creamEdge),
                        lineWidth: isReorderTarget ? 2 : (hasCrop ? 1.5 : 0.5)
                    )
            )
            .opacity(isReorderTarget ? 0.75 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isReorderTarget)

            // Remove button — top right
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.cream, Color.warmDark.opacity(0.7))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .padding(3)

            // Crop button — bottom left
            VStack {
                Spacer()
                HStack {
                    Button {
                        showingCropPopover = true
                    } label: {
                        Image(systemName: hasCrop ? "crop.rotate" : "crop")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(hasCrop ? Color.roseGold : .white.opacity(0.85))
                            .padding(3)
                            .background(Color.black.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingCropPopover, arrowEdge: .bottom) {
                        CropOffsetPopover(image: image, cropOffset: $cropOffset)
                    }
                    Spacer()
                }
                .padding(.leading, 4)
                .padding(.bottom, 4)
            }
            .frame(width: 80, height: 80)
        }
        .task { image = await Task.detached { NSImage(contentsOf: url) }.value }
    }

    /// Returns the max pixel shift the image can move within the 80×80 frame.
    private func imageShift(image: NSImage, frameW: Double, frameH: Double) -> (Double, Double) {
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return (0, 0) }
        let imageRatio = iw / ih
        let frameRatio = frameW / frameH
        if imageRatio > frameRatio {
            // Wider image — overflows horizontally
            let scaledW = frameH * imageRatio
            return ((scaledW - frameW) / 2, 0)
        } else {
            // Taller image — overflows vertically
            let scaledH = frameW / imageRatio
            return (0, (scaledH - frameH) / 2)
        }
    }
}

// MARK: - Crop Offset Popover

private struct CropOffsetPopover: View {
    let image: NSImage?
    @Binding var cropOffset: CropOffset

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("ADJUST CROP")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.0)
                .foregroundStyle(Color.warmMid)

            // Preview
            if let image {
                let (ox, oy) = shift(image: image, frameW: 160, frameH: 160)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .offset(x: cropOffset.x * ox, y: cropOffset.y * oy)
                    .frame(width: 160, height: 160)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            } else {
                Color.creamDeep
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            }

            // Horizontal
            VStack(alignment: .leading, spacing: 3) {
                Text("HORIZONTAL").font(.system(size: 8, weight: .medium)).tracking(0.8).foregroundStyle(Color.warmMid)
                HStack(spacing: 4) {
                    Text("◄").font(.system(size: 9)).foregroundStyle(Color.warmMid)
                    Slider(value: $cropOffset.x, in: -1...1)
                        .tint(Color.roseGold)
                    Text("►").font(.system(size: 9)).foregroundStyle(Color.warmMid)
                }
            }

            // Vertical
            VStack(alignment: .leading, spacing: 3) {
                Text("VERTICAL").font(.system(size: 8, weight: .medium)).tracking(0.8).foregroundStyle(Color.warmMid)
                HStack(spacing: 4) {
                    Text("▲").font(.system(size: 9)).foregroundStyle(Color.warmMid)
                    Slider(value: $cropOffset.y, in: -1...1)
                        .tint(Color.roseGold)
                    Text("▼").font(.system(size: 9)).foregroundStyle(Color.warmMid)
                }
            }

            if hasCrop {
                Button("Reset to default") { cropOffset = CropOffset() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseGold)
            }
        }
        .padding(Spacing.md)
        .frame(width: 210)
        .background(Color.cream)
    }

    private var hasCrop: Bool { cropOffset.x != 0 || cropOffset.y != 0 }

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
}

// MARK: - Tuesday Reel Section

private struct TuesdayReelSection: View {
    @Binding var screenRecording: URL?
    @Binding var rawPhoto: URL?
    @Binding var editedPhoto: URL?
    @Binding var targetDuration: Double
    let onPickScreenRecording: () -> Void
    let onPickRawPhoto: () -> Void
    let onPickEditedPhoto: () -> Void

    @State private var isExpanded = false
    @State private var recordingSeconds: Double? = nil

    var hasAllInputs: Bool { screenRecording != nil && rawPhoto != nil && editedPhoto != nil }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: hasAllInputs ? "film.fill" : "film")
                        .font(.system(size: 11))
                        .foregroundStyle(hasAllInputs ? Color.roseGold : Color.warmMid)
                    Text("SPEED EDIT REEL")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                    if hasAllInputs {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.roseGold.opacity(0.8))
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Screen recording + RAW and edited photos are combined into a timelapse reel.")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                        .padding(.bottom, 4)

                    SingleFilePicker(label: "Screen Recording", url: screenRecording,
                                     onPick: onPickScreenRecording, onClear: { screenRecording = nil })
                    SingleFilePicker(label: "RAW Photo",        url: rawPhoto,
                                     onPick: onPickRawPhoto,        onClear: { rawPhoto = nil })
                    SingleFilePicker(label: "Edited Photo",     url: editedPhoto,
                                     onPick: onPickEditedPhoto,     onClear: { editedPhoto = nil })

                    if hasAllInputs {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("TARGET DURATION")
                                    .font(.system(size: 9, weight: .medium))
                                    .tracking(0.8)
                                    .foregroundStyle(Color.warmMid)
                                Spacer()
                                if let dur = recordingSeconds {
                                    let speed = dur / targetDuration
                                    Text(String(format: "%.0f× speed", speed))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(speed > 40 ? Color.roseDeep : Color.roseGold)
                                }
                            }
                            HStack(spacing: Spacing.sm) {
                                Slider(value: $targetDuration, in: 10...30, step: 1)
                                    .tint(Color.roseGold)
                                Text("\(Int(targetDuration))s")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.warmDark)
                                    .frame(width: 28, alignment: .trailing)
                            }
                            if let dur = recordingSeconds {
                                let minutes = Int(dur) / 60
                                let seconds = Int(dur) % 60
                                Text("Recording: \(minutes > 0 ? "\(minutes)m " : "")\(seconds)s")
                                    .font(.light(10))
                                    .foregroundStyle(Color.warmMid)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.15)
        }
        .background(Color.roseGold.opacity(0.02))
        .task(id: screenRecording) {
            guard let url = screenRecording else { recordingSeconds = nil; return }
            recordingSeconds = await loadVideoDuration(url: url)
        }
    }
}

// MARK: - Wednesday Collage Section

private struct WednesdayCollageSection: View {
    let photoCount: Int
    @Binding var collageSeed: Int?

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmMid)
                    Text("COLLAGE LAYOUT")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                    if let seed = collageSeed {
                        Text("layout \(seed % 1000)")
                            .font(.light(10))
                            .foregroundStyle(Color.warmMid)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if photoCount < 10 {
                        Text("Need 10 photos to generate the collage — \(10 - photoCount) more required.")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    } else {
                        Text("Tap photos above to adjust crop. Tap below to try a different layout arrangement.")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)

                        Button("New layout") {
                            collageSeed = Int.random(in: 1...99999)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.roseGold)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.15)
        }
        .background(Color.roseGold.opacity(0.02))
    }
}

// MARK: - Thursday Reel Section

private struct ThursdayReelSection: View {
    @Binding var audio: URL?
    @Binding var scrollDuration: Double
    @Binding var reelSeed: Int?
    let onPickAudio: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: audio != nil ? "music.note" : "play.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(audio != nil ? Color.roseGold : Color.warmMid)
                    Text("SCROLL REEL")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // Audio
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Optional audio — auto-fetched from Jamendo if omitted.")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                        SingleFilePicker(label: "Audio File", url: audio,
                                         onPick: onPickAudio, onClear: { audio = nil })
                    }

                    // Scroll duration slider
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SCROLL DURATION")
                            .font(.system(size: 9, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(Color.warmMid)
                        HStack(spacing: Spacing.sm) {
                            Slider(value: $scrollDuration, in: 15...60, step: 5)
                                .tint(Color.roseGold)
                            Text("\(Int(scrollDuration))s")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.warmDark)
                                .frame(width: 32, alignment: .trailing)
                        }
                    }

                    // Layout seed
                    Button("New layout") { reelSeed = Int.random(in: 1...99999) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.roseGold)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.15)
        }
        .background(Color.roseGold.opacity(0.02))
    }
}

// MARK: - Friday Before/After Section

private struct FridayBeforeAfterSection: View {
    @Binding var rawPhoto: URL?
    @Binding var editedPhoto: URL?
    let onPickRawPhoto: () -> Void
    let onPickEditedPhoto: () -> Void

    @State private var isExpanded = false

    var hasAllInputs: Bool { rawPhoto != nil && editedPhoto != nil }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: hasAllInputs ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        .font(.system(size: 11))
                        .foregroundStyle(hasAllInputs ? Color.roseGold : Color.warmMid)
                    Text("BEFORE/AFTER STORY")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                    if hasAllInputs {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.roseGold.opacity(0.8))
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("RAW on top, edited on bottom. Same photos as Tuesday's reel closing frame.")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                        .padding(.bottom, 4)

                    SingleFilePicker(label: "RAW Photo",    url: rawPhoto,
                                     onPick: onPickRawPhoto,    onClear: { rawPhoto = nil })
                    SingleFilePicker(label: "Edited Photo", url: editedPhoto,
                                     onPick: onPickEditedPhoto, onClear: { editedPhoto = nil })
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.15)
        }
        .background(Color.roseGold.opacity(0.02))
    }
}

// MARK: - Single File Picker Row

private struct SingleFilePicker: View {
    let label: String
    let url: URL?
    let onPick: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
                .frame(width: 110, alignment: .leading)

            if let url {
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warmDark)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.warmMid.opacity(0.6), Color.creamEdge)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            } else {
                Button("Choose…", action: onPick)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.roseGold)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Photo Drop Zone

private struct PhotoDropZone: View {
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 24))
                .foregroundStyle(Color.roseGold.opacity(isTargeted ? 0.8 : 0.35))
            VStack(alignment: .leading, spacing: 3) {
                Text("Drop photos here")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isTargeted ? Color.roseGold : Color.warmMid)
                Text("JPEG · PNG · HEIC")
                    .font(.light(10))
                    .foregroundStyle(Color.warmMid)
            }
            Spacer()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity)
        .background(Color.creamDeep)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(
                    isTargeted ? Color.roseGold : Color.roseGold.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

// MARK: - Photo Count Badge

private struct PhotoCountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.cream)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.roseGold.opacity(0.65))
            .clipShape(Capsule())
    }
}

// MARK: - Photo Thumb (plain, no crop)

private struct PhotoThumb: View {
    let url: URL
    var isReorderTarget: Bool = false
    let onRemove: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.creamDeep.overlay { ProgressView().controlSize(.small).tint(Color.roseGold) }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(isReorderTarget ? Color.roseGold : Color.creamEdge,
                                  lineWidth: isReorderTarget ? 2 : 0.5)
            )
            .opacity(isReorderTarget ? 0.75 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isReorderTarget)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.cream, Color.warmDark.opacity(0.7))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .padding(3)
        }
        .task { image = await Task.detached { NSImage(contentsOf: url) }.value }
    }
}

// MARK: - AVFoundation helper

private func loadVideoDuration(url: URL) async -> Double? {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration) else { return nil }
    let secs = CMTimeGetSeconds(duration)
    return secs.isFinite && secs > 0 ? secs : nil
}
