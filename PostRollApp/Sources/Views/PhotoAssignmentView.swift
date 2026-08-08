import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Main View

struct PhotoAssignmentView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var dayPhotos: [DayName: [URL]]
    @State private var pickerTarget: PickerTarget? = nil
    @State private var importResultMessage: String? = nil
    @State private var previewURL: URL? = nil
    // Photos whose files can't be found on disk (moved or deleted).
    @State private var missingPhotos: Set<URL> = []

    // Tuesday: speed edit reel inputs
    @State private var tuesdayScreenRecording: URL?
    @State private var tuesdayRawPhoto: URL?
    @State private var tuesdayEditedPhoto: URL?
    @State private var tuesdayBWPhoto: URL?
    @State private var tuesdayTargetDuration: Double = 20.0

    // Thursday: scroll reel
    @State private var thursdayAudio: URL?
    @State private var thursdayAudioMissing = false   // file set but gone from disk
    @State private var thursdayScrollDuration: Double = 30.0
    @State private var thursdayReelSeed: Int? = nil

    // Wednesday: collage
    @State private var wednesdayCollageSeed: Int? = nil

    // Crop offsets for Wednesday + Thursday photos (keyed by photo URL absoluteString)
    @State private var dayCropOffsets: [DayName: [String: CropOffset]] = [:]
    // Wednesday only: per-photo people tags (keyed by photo URL absoluteString)
    @State private var dayPhotoTags: [DayName: [String: [String]]] = [:]
    // Shooter observations per day — passed to caption generator
    @State private var dayNotes: [DayName: String] = [:]

    // Per-day performer assignments and extra handles
    @State private var dayHandles: [DayName: String] = [:]       // comma-separated @handles
    @State private var dayPlainNames: [DayName: String] = [:]    // comma-separated plain names
    @State private var dayPerformers: [DayName: Set<UUID>] = [:] // selected performer IDs

    var totalPhotos: Int { dayPhotos.values.reduce(0) { $0 + $1.count } }

    /// A day with a per-photo carousel that supports people tagging: Wednesday
    /// always, plus Sunday/Monday under a balanced layout. Uses this event's
    /// effective preset so a per-event override is respected.
    private func isCollageDay(_ day: DayName) -> Bool {
        event.effectivePostingPreset.isCollageCarousel(day)
    }

    /// Suggestions for a day's per-photo tag popover, drawn from the event's
    /// performers. Inserts the @handle when there is a real one, otherwise the
    /// plain name. Performers marked as appearing in that day's photos are listed
    /// first so the common picks are closest to hand.
    private func tagSuggestions(for day: DayName) -> [PhotoTagSuggestion] {
        // The event's own accounts (organization, venue, and anything else
        // written into those free-text fields) are taggable on a photo too:
        // a shot of the room or the presenting festival is often about them
        // rather than a performer.
        let eventAccounts = EventHandleSuggestions
            .tokens(fromAll: [event.eventHandles])
            .map { PhotoTagSuggestion(token: $0, display: $0) }

        let performers = event.ocrResult?.performers ?? []
        let selected = dayPerformers[day] ?? []
        let ordered = performers.sorted { a, b in
            let aSel = selected.contains(a.id), bSel = selected.contains(b.id)
            if aSel != bSel { return aSel }
            return false
        }
        let performerSuggestions = ordered.compactMap { p -> PhotoTagSuggestion? in
            let name = p.name.trimmingCharacters(in: .whitespaces)
            let handle = p.handle.trimmingCharacters(in: .whitespaces)
            let realHandle = PythonBridge.isRealHandle(handle)
            guard !name.isEmpty || realHandle else { return nil }
            let normalizedHandle = handle.hasPrefix("@") ? handle : "@\(handle)"
            let token = realHandle ? normalizedHandle : name
            // Label echoes the performer checkbox: name, instrument/role, handle.
            var parts: [String] = []
            if !name.isEmpty { parts.append(name) }
            let designation = p.designation
            if !designation.isEmpty { parts.append(designation.lowercased()) }
            if realHandle { parts.append(normalizedHandle) }
            let display = parts.isEmpty ? token : parts.joined(separator: " ")
            return PhotoTagSuggestion(token: token, display: display)
        }

        // Performers first: they're the common pick, and the event's own
        // accounts are a handful that stay findable at the end.
        var seen = Set<String>()
        return (performerSuggestions + eventAccounts).filter {
            seen.insert($0.token.lowercased()).inserted
        }
    }

    enum PickerTarget: Equatable {
        case day(DayName)
        case tuesdayScreenRecording
        case tuesdayRawPhoto
        case tuesdayEditedPhoto
        case tuesdayBWPhoto
        case thursdayAudio
    }

    init(event: Event) {
        self.event = event
        var loaded: [DayName: [URL]] = [:]
        for day in DayName.allCases { loaded[day] = event.days[day.rawValue]?.photoPaths ?? [] }
        _dayPhotos = State(initialValue: loaded)

        let tue = event.days[DayName.tuesday.rawValue]
        _tuesdayScreenRecording = State(initialValue: tue?.screenRecordingPath)
        _tuesdayRawPhoto        = State(initialValue: tue?.rawPhotoPath)
        _tuesdayEditedPhoto     = State(initialValue: tue?.editedPhotoPath)
        _tuesdayBWPhoto         = State(initialValue: tue?.bwPhotoPath)
        _tuesdayTargetDuration  = State(initialValue: tue?.reelTargetDuration ?? 20.0)

        let thu = event.days[DayName.thursday.rawValue]
        _thursdayAudio          = State(initialValue: thu?.audioPath)
        _thursdayScrollDuration = State(initialValue: thu?.scrollDuration ?? 40.0)
        _thursdayReelSeed       = State(initialValue: thu?.reelSeed)

        let wed = event.days[DayName.wednesday.rawValue]
        _wednesdayCollageSeed = State(initialValue: wed?.collageSeed)

        // Load crop offsets for all days
        var offsets: [DayName: [String: CropOffset]] = [:]
        for day in DayName.allCases {
            if let existing = event.days[day.rawValue]?.cropOffsets, !existing.isEmpty {
                offsets[day] = existing
            }
        }
        _dayCropOffsets = State(initialValue: offsets)

        // Load Wednesday per-photo tags
        var photoTags: [DayName: [String: [String]]] = [:]
        for day in DayName.allCases {
            if let existing = event.days[day.rawValue]?.photoTags, !existing.isEmpty {
                photoTags[day] = existing
            }
        }
        _dayPhotoTags = State(initialValue: photoTags)

        // Load per-day shooter notes
        var notes: [DayName: String] = [:]
        for day in DayName.allCases {
            notes[day] = event.days[day.rawValue]?.notes ?? ""
        }
        _dayNotes = State(initialValue: notes)

        // Load per-day performer assignments and handles
        var handles: [DayName: String] = [:]
        var plains: [DayName: String] = [:]
        var perfs: [DayName: Set<UUID>] = [:]
        for day in DayName.allCases {
            if let pd = event.days[day.rawValue] {
                if !pd.tagHandles.isEmpty { handles[day] = pd.tagHandles.joined(separator: ", ") }
                if !pd.nameMentions.isEmpty { plains[day] = pd.nameMentions.joined(separator: ", ") }
                if !pd.selectedPerformerIDs.isEmpty { perfs[day] = Set(pd.selectedPerformerIDs) }
            }
        }
        _dayHandles = State(initialValue: handles)
        _dayPlainNames = State(initialValue: plains)
        _dayPerformers = State(initialValue: perfs)
    }

    var body: some View {
        ZStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                EventHeader(event: event, subtitle: "Assign Photos")
                    .padding([.horizontal, .top], Spacing.xl)
                    .padding(.bottom, Spacing.sm)

                StageBackButton(label: "Back to OCR review") {
                    var ev = event; ev.stage = .ocrDone; appState.updateEvent(ev)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xs)

                Text("Your photo assignments are saved. Going back won't lose them.")
                    .font(.light(10))
                    .foregroundStyle(Color.warmMid.opacity(0.7))
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.md)

                BrandBanner(
                    icon: "rectangle.3.group",
                    message: "Drop photos into each posting day, or import a whole folder organized by day subfolders (named sunday–friday or day 1–day 6). Wednesday and Thursday show a crop button on each photo, and Wednesday photos also have a tag button to note who's in each carousel slide."
                )
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.sm)

                if let msg = importResultMessage {
                    BrandBanner(
                        icon: msg.hasPrefix("No photos") ? "exclamationmark.circle" : "checkmark.circle",
                        message: msg,
                        style: msg.hasPrefix("No photos") ? .error : .info
                    )
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.sm)
                }

                if !missingPhotos.isEmpty {
                    MissingPhotosBanner(
                        count: missingPhotos.count,
                        onLocate: locateMissingPhotos,
                        onRemove: removeMissingPhotos
                    )
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.sm)
                }

                HStack {
                    Spacer()
                    Button("Import from folder…") {
                        importResultMessage = nil
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Import"
                        if panel.runModal() == .OK, let url = panel.url {
                            importFromFolder(url)
                        }
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.roseGold)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.lg)

                ForEach(DayName.allCases, id: \.self) { day in
                    let enableCrop = (day == .wednesday || day == .thursday)
                    let wednesdayCount = day == .wednesday ? (dayPhotos[.wednesday]?.count ?? 0) : 0
                    let note: String? = day == .wednesday && wednesdayCount > 10
                        ? "Collage uses the first 10 photos (\(wednesdayCount) assigned). Drag to reorder."
                        : nil

                    // Friday is the before/after story — it reuses Tuesday's RAW + Edited
                    // photos, so there's no separate upload area for it.
                    if day != .friday {
                        PhotoDaySection(
                            label: day.displayName,
                            collageNote: note,
                            photos: dayBinding(day),
                            cropOffsets: enableCrop ? cropOffsetsBinding(day) : nil,
                            photoTags: isCollageDay(day) ? photoTagsBinding(day) : nil,
                            tagSuggestions: isCollageDay(day) ? tagSuggestions(for: day) : [],
                            notes: noteBinding(day),
                            onPreview: { previewURL = $0 },
                            onAddPhotos: { presentPicker(.day(day)) }
                        )
                    }

                    // Day-specific special input sections
                    switch day {
                    case .tuesday:
                        TuesdayReelSection(
                            screenRecording: $tuesdayScreenRecording,
                            rawPhoto:        $tuesdayRawPhoto,
                            editedPhoto:     $tuesdayEditedPhoto,
                            bwPhoto:         $tuesdayBWPhoto,
                            targetDuration:  $tuesdayTargetDuration,
                            dayPhotos:       dayPhotos[.tuesday] ?? [],
                            onPickScreenRecording: { presentPicker(.tuesdayScreenRecording) },
                            onPickRawPhoto:        { presentPicker(.tuesdayRawPhoto) },
                            onPickEditedPhoto:     { presentPicker(.tuesdayEditedPhoto) },
                            onPickBWPhoto:         { presentPicker(.tuesdayBWPhoto) }
                        )
                        .onChange(of: tuesdayScreenRecording) { _, _ in save() }
                        .onChange(of: tuesdayRawPhoto)        { _, _ in save() }
                        .onChange(of: tuesdayEditedPhoto)     { _, _ in save() }
                        .onChange(of: tuesdayBWPhoto)         { _, _ in save() }
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
                            audioMissing:   thursdayAudioMissing,
                            scrollDuration: $thursdayScrollDuration,
                            reelSeed:       $thursdayReelSeed,
                            onPickAudio:    { presentPicker(.thursdayAudio) },
                            onLocateAudio:  locateMissingAudio
                        )
                        .task(id: thursdayAudio) { await scanMissingAudio() }
                        .onChange(of: thursdayAudio)         { _, _ in save() }
                        .onChange(of: thursdayScrollDuration){ _, _ in save() }
                        .onChange(of: thursdayReelSeed)      { _, _ in save() }

                    case .friday:
                        FridayBeforeAfterSection(
                            rawPhoto:    tuesdayRawPhoto,
                            editedPhoto: tuesdayEditedPhoto
                        )

                    default:
                        EmptyView()
                    }

                    // Performer assignment (not on Friday — it's story-only from Tuesday)
                    if day != .friday, !(dayPhotos[day]?.isEmpty ?? true) {
                        PerformerAssignmentSection(
                            day: day,
                            performers: event.ocrResult?.performers ?? [],
                            eventHandles: event.eventHandles,
                            selectedPerformerIDs: performerBinding(day),
                            handles: handleBinding(day),
                            names: plainNameBinding(day),
                            isCarouselDay: isCollageDay(day),
                            onChanged: { save() }
                        )
                    }

                }

                VStack(alignment: .trailing, spacing: Spacing.sm) {
                    if totalPhotos == 0 {
                        Text("Add photos to at least one day to continue.")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    }
                    HStack {
                        Spacer()
                        Button("Continue to Generation") { advance() }
                            .buttonStyle(BrandButtonStyle())
                            .disabled(totalPhotos == 0)
                    }
                }
                .padding(Spacing.xl)
            }
        }
        .background(Color.cream)

        // Full-screen photo preview overlay
        if let url = previewURL {
            PhotoPreviewOverlay(url: url) { previewURL = nil }
                .transition(.opacity)
        }
        } // ZStack
        .animation(.easeOut(duration: 0.18), value: previewURL != nil)
        .task(id: dayPhotos.mapValues(\.count)) { await scanMissingPhotos() }
    }

    // MARK: - File picker

    /// NSOpenPanel instead of .fileImporter: the repo convention. The old
    /// fileImporter binding had an empty setter, so cancelling the dialog
    /// left pickerTarget stuck non-nil and Add Photos never opened again.
    private func presentPicker(_ target: PickerTarget) {
        pickerTarget = target
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = isMultiSelection
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK { handlePickedFiles(panel.urls) }
            pickerTarget = nil
        }
    }

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
        case .day: return true
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

    private func cropOffsetsBinding(_ day: DayName) -> Binding<[String: CropOffset]> {
        Binding(
            get: { dayCropOffsets[day] ?? [:] },
            set: { dayCropOffsets[day] = $0; save() }
        )
    }

    private func photoTagsBinding(_ day: DayName) -> Binding<[String: [String]]> {
        Binding(
            get: { dayPhotoTags[day] ?? [:] },
            set: { dayPhotoTags[day] = $0; save() }
        )
    }

    private func noteBinding(_ day: DayName) -> Binding<String> {
        Binding(
            get: { dayNotes[day] ?? "" },
            set: { dayNotes[day] = $0; save() }
        )
    }

    private func performerBinding(_ day: DayName) -> Binding<Set<UUID>> {
        Binding(
            get: { dayPerformers[day] ?? [] },
            set: { dayPerformers[day] = $0; save() }
        )
    }

    private func handleBinding(_ day: DayName) -> Binding<String> {
        Binding(
            get: { dayHandles[day] ?? "" },
            set: { dayHandles[day] = $0; save() }
        )
    }

    private func plainNameBinding(_ day: DayName) -> Binding<String> {
        Binding(
            get: { dayPlainNames[day] ?? "" },
            set: { dayPlainNames[day] = $0; save() }
        )
    }

    // MARK: - File handling

    private func handlePickedFiles(_ urls: [URL]) {
        guard let url = urls.first else { return }
        switch pickerTarget {
        case .day(let day):
            var list = dayPhotos[day] ?? []
            for u in urls {
                let stored = AppPaths.storedPhoto(u)
                if !list.contains(stored) { list.append(stored) }
            }
            dayPhotos[day] = list
        case .tuesdayScreenRecording: tuesdayScreenRecording = AppPaths.storedPhoto(url)
        case .tuesdayRawPhoto:        tuesdayRawPhoto = AppPaths.storedPhoto(url)
        case .tuesdayEditedPhoto:     tuesdayEditedPhoto = AppPaths.storedPhoto(url)
        case .tuesdayBWPhoto:         tuesdayBWPhoto = AppPaths.storedPhoto(url)
        case .thursdayAudio:          thursdayAudio = AppPaths.storedAudio(url)
        case nil: break
        }
        save()
    }

    private func importFromFolder(_ root: URL) {
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let imageExts = Set(["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "webp"])
        let videoExts = Set(["mov", "mp4", "m4v"])
        let audioExts = Set(["m4a", "mp3", "aiff", "aif", "aac"])


        func imageFiles(in dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { imageExts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
        }

        // "unedited" contains "edit" so check raw markers first, then edited
        func isRaw(_ name: String) -> Bool {
            name.contains("raw") || name.contains("before") || name.contains("unedited") || name.contains("original")
        }
        func isEdited(_ name: String) -> Bool {
            !isRaw(name) && (name.contains("edit") || name.contains("after"))
        }

        var totalImported = 0

        for (index, day) in DayName.allCases.enumerated() {
            // Accept named subfolders (sunday, monday…) or numbered (day 1, Day 1, day1…)
            let n = index + 1
            let candidates = [
                root.appendingPathComponent(day.rawValue),
                root.appendingPathComponent("day \(n)"),
                root.appendingPathComponent("Day \(n)"),
                root.appendingPathComponent("day\(n)"),
            ]
            guard let dayDir = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { continue }

            let images = imageFiles(in: dayDir)
            if !images.isEmpty {
                var list = dayPhotos[day] ?? []
                for u in images {
                    let stored = AppPaths.storedPhoto(u)
                    if !list.contains(stored) { list.append(stored); totalImported += 1 }
                }
                dayPhotos[day] = list
            }

            let contents = (try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil)) ?? []

            switch day {
            case .tuesday:
                if tuesdayScreenRecording == nil,
                   let rec = contents.first(where: { videoExts.contains($0.pathExtension.lowercased()) }) {
                    tuesdayScreenRecording = AppPaths.storedPhoto(rec)
                }
                for file in contents where imageExts.contains(file.pathExtension.lowercased()) {
                    let name = file.deletingPathExtension().lastPathComponent.lowercased()
                    if tuesdayRawPhoto == nil, isRaw(name) { tuesdayRawPhoto = AppPaths.storedPhoto(file) }
                    else if tuesdayEditedPhoto == nil, isEdited(name) { tuesdayEditedPhoto = AppPaths.storedPhoto(file) }
                }
            case .thursday:
                if thursdayAudio == nil,
                   let audio = contents.first(where: { audioExts.contains($0.pathExtension.lowercased()) }) {
                    thursdayAudio = AppPaths.storedAudio(audio)
                }
            default: break
            }
        }

        save()

        importResultMessage = totalImported == 0
            ? "No photos found. Expected subfolders named sunday–friday or day 1–day 6."
            : "Imported \(totalImported) photo\(totalImported == 1 ? "" : "s")."
    }

    // MARK: - Missing media

    /// Marks photos whose files are gone from disk so the UI can flag them.
    /// Runs off the main thread because it stats every assigned photo.
    private func scanMissingPhotos() async {
        let all = dayPhotos.values.flatMap { $0 }
        let missing = await Task.detached(priority: .utility) {
            Set(all.filter { !FileManager.default.fileExists(atPath: $0.path) })
        }.value
        missingPhotos = missing
    }

    /// Asks for a folder, then re-links any missing photo whose filename is
    /// found inside it (recursively), copying the re-found file into app
    /// storage and carrying its crop/tags over. Order is preserved.
    private func locateMissingPhotos() {
        guard !missingPhotos.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Locate"
        panel.message = "Choose the folder these photos were moved to."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let byName = filesByName(in: folder)
        var remap: [URL: URL] = [:]
        for missing in missingPhotos {
            guard let found = byName[missing.lastPathComponent] else { continue }
            remap[missing] = AppPaths.importedCopy(of: found, into: AppPaths.photosDir) ?? found
        }
        guard !remap.isEmpty else {
            importResultMessage = "No matching photos were found in that folder."
            return
        }

        for day in DayName.allCases {
            var pd = PostingDay(day: day)
            pd.photoPaths = dayPhotos[day] ?? []
            pd.cropOffsets = dayCropOffsets[day] ?? [:]
            pd.photoTags = dayPhotoTags[day] ?? [:]
            let rebound = pd.rebindingPhotos(remap)
            dayPhotos[day] = rebound.photoPaths
            dayCropOffsets[day] = rebound.cropOffsets
            dayPhotoTags[day] = rebound.photoTags
        }
        importResultMessage = "Re-linked \(remap.count) photo\(remap.count == 1 ? "" : "s")."
        save()
        Task { await scanMissingPhotos() }
    }

    /// Flags the Thursday audio when its file has moved or been deleted off disk,
    /// mirroring the missing-photo scan. Stats off the main thread.
    private func scanMissingAudio() async {
        let audio = thursdayAudio
        let missing = await Task.detached(priority: .utility) {
            MediaPresence.isMissing(audio)
        }.value
        thursdayAudioMissing = missing
    }

    /// Lets the user pick a replacement audio file when the original is gone,
    /// copying it into app storage so it can't go missing the same way again.
    private func locateMissingAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .mp3, .aiff,
                                     UTType(filenameExtension: "m4a") ?? .audio,
                                     UTType(filenameExtension: "aac") ?? .audio]
        panel.prompt = "Locate"
        panel.message = "Choose the audio file to use for the Thursday reel."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        thursdayAudio = AppPaths.storedAudio(url)
        save()
        Task { await scanMissingAudio() }
    }

    /// Maps filename -> URL for every file under `folder` (first match wins).
    private func filesByName(in folder: URL) -> [String: URL] {
        var map: [String: URL] = [:]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return map }
        for case let url as URL in walker where map[url.lastPathComponent] == nil {
            map[url.lastPathComponent] = url
        }
        return map
    }

    /// Drops every missing photo from each day (and its per-photo crop/tag
    /// entries), then persists. Leaves on-disk photos untouched.
    private func removeMissingPhotos() {
        guard !missingPhotos.isEmpty else { return }
        for day in DayName.allCases {
            var pd = PostingDay(day: day)
            pd.photoPaths = dayPhotos[day] ?? []
            pd.cropOffsets = dayCropOffsets[day] ?? [:]
            pd.photoTags = dayPhotoTags[day] ?? [:]
            let stripped = pd.removingPhotos(missingPhotos)
            guard stripped.photoPaths.count != pd.photoPaths.count else { continue }
            dayPhotos[day] = stripped.photoPaths
            dayCropOffsets[day] = stripped.cropOffsets
            dayPhotoTags[day] = stripped.photoTags
        }
        missingPhotos = []
        save()
    }

    // MARK: - Persistence

    private func save() {
        var ev = event
        for day in DayName.allCases {
            var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
            pd.photoPaths  = dayPhotos[day] ?? []
            pd.cropOffsets = dayCropOffsets[day] ?? [:]
            pd.photoTags   = dayPhotoTags[day] ?? [:]
            pd.notes       = dayNotes[day] ?? ""
            pd.tagHandles          = parseHandles(dayHandles[day] ?? "")
            pd.nameMentions        = parseHandles(dayPlainNames[day] ?? "")
            pd.selectedPerformerIDs = Array(dayPerformers[day] ?? [])
            switch day {
            case .tuesday:
                pd.screenRecordingPath = tuesdayScreenRecording
                pd.rawPhotoPath        = tuesdayRawPhoto
                pd.editedPhotoPath     = tuesdayEditedPhoto
                pd.bwPhotoPath         = tuesdayBWPhoto
                pd.reelTargetDuration  = tuesdayTargetDuration
            case .thursday:
                pd.audioPath      = thursdayAudio
                pd.scrollDuration = thursdayScrollDuration
                pd.reelSeed       = thursdayReelSeed
            case .wednesday:
                pd.collageSeed = wednesdayCollageSeed
            case .friday:
                // Before/after story uses Tuesday's RAW and edited photos (and
                // the optional B&W). Friday has no separate photo grid, so wipe
                // any stale paths.
                pd.rawPhotoPath    = tuesdayRawPhoto
                pd.editedPhotoPath = tuesdayEditedPhoto
                pd.bwPhotoPath     = tuesdayBWPhoto
                pd.photoPaths      = []
            default: break
            }
            ev.days[day.rawValue] = pd
        }
        // Blog photos auto-derived from Sunday + Monday + Wednesday
        ev.blogPhotoPaths = (dayPhotos[.sunday] ?? []) + (dayPhotos[.monday] ?? []) + (dayPhotos[.wednesday] ?? [])
        appState.updateEvent(ev)
    }

    private func parseHandles(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
    var photoTags: Binding<[String: [String]]>? = nil
    var tagSuggestions: [PhotoTagSuggestion] = []
    var notes: Binding<String>? = nil
    var onPreview: ((URL) -> Void)? = nil
    let onAddPhotos: () -> Void

    @State private var isExpanded = true
    @State private var isDropTargeted = false
    @State private var reorderTargetIndex: Int? = nil
    // Batch tagging (#172): which photos are picked out, and the tags being
    // composed for them. Only ever used where photoTags is non-nil.
    @State private var selection = PhotoSelection()
    /// Index of the photo open in the tagging sheet; nil when it's closed.
    @State private var taggingIndex: Int? = nil
    /// Which photos the open sheet walks. Empty means the whole day (opened
    /// from a photo's own tag button); non-empty is a batch selection.
    @State private var taggingScope: [String] = []

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
                            ForEach(Array(photos.enumerated()), id: \.element) { i, url in
                                // Drag payloads carry the photo URL, not a bare
                                // index: index strings leak across days, so a
                                // drag from Sunday onto Monday would silently
                                // reorder Monday by the wrong index. Resolving
                                // by content also rejects cross-day drops.
                                thumbView(for: url, at: i)
                                    .draggable(url.absoluteString)
                                    .dropDestination(for: String.self) { items, _ in
                                        guard let payload = items.first,
                                              let srcIdx = photos.firstIndex(where: { $0.absoluteString == payload }),
                                              let dstIdx = photos.firstIndex(of: url),
                                              srcIdx != dstIdx else { return false }
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            photos.move(fromOffsets: IndexSet(integer: srcIdx),
                                                        toOffset: srcIdx < dstIdx ? dstIdx + 1 : dstIdx)
                                        }
                                        return true
                                    } isTargeted: { targeted in
                                        reorderTargetIndex = targeted ? i : nil
                                    }
                            }
                        }
                    }
                    if photoTags != nil, !selection.isEmpty {
                        batchTagBar
                    }
                    if let collageNote {
                        Text(collageNote).font(.system(size: 10)).foregroundStyle(Color.warmMid).padding(.top, 2)
                    }
                    Button(photos.isEmpty ? "Add Photos…" : "Add more…", action: onAddPhotos)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.roseGold)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.sm)
                .background(isDropTargeted ? Color.roseGold.opacity(0.03) : Color.clear)
            }

            if let notesBinding = notes {
                DayNotesField(notes: notesBinding)
            }

            RoseGoldDivider(opacity: 0.3)
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { handleDrop($0) }
        // A photo removed or reordered away must not stay silently selected and
        // collect a later batch tag.
        .onChange(of: photos) { _, newValue in
            selection.prune(to: newValue.map(\.absoluteString))
        }
        .sheet(isPresented: Binding(get: { taggingIndex != nil },
                                    set: { if !$0 { closeTagging() } })) {
            if let tagsBinding = photoTags, taggingIndex != nil {
                PhotoTaggingSheet(
                    photos: scopedPhotos,
                    photoTags: tagsBinding,
                    suggestions: tagSuggestions,
                    isBatch: !taggingScope.isEmpty,
                    index: Binding(get: { taggingIndex ?? 0 },
                                   set: { taggingIndex = $0 }),
                    onClose: closeTagging
                )
            }
        }
    }

    /// The photos the open sheet walks: the batch selection when there is one,
    /// otherwise the whole day.
    private var scopedPhotos: [URL] {
        let keys = PhotoTagBatch.scope(taggingScope, in: photos.map(\.absoluteString))
        let wanted = Set(keys)
        return photos.filter { wanted.contains($0.absoluteString) }
    }

    private func closeTagging() {
        taggingIndex = nil
        taggingScope = []
        selection.clear()
    }

    /// Shown once at least one photo is selected: how many, and the one action
    /// that selection exists for.
    private var batchTagBar: some View {
        HStack(spacing: Spacing.sm) {
            Text("\(selection.count) selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.warmDark)

            Button("Tag \(selection.count == 1 ? "this photo" : "these \(selection.count)")…") {
                taggingScope = PhotoTagBatch.ordered(selection.keys,
                                                     in: photos.map(\.absoluteString))
                taggingIndex = 0
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.roseGold)

            Button("Clear") { selection.clear() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.warmMid)

            Spacer()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.xs).fill(Color.roseGold.opacity(0.08)))
    }

    @ViewBuilder
    private func thumbView(for url: URL, at i: Int) -> some View {
        // Crop (Wednesday, Thursday) and tagging (every carousel day) cover
        // different days, so each affordance answers only to its own binding.
        // Gating tagging on the crop binding hid it entirely on Sunday and
        // Monday, where crop is off but the carousel is real.
        if PhotoThumbControls.usesDetailedThumb(cropEnabled: cropOffsets != nil,
                                                taggingEnabled: photoTags != nil) {
            let cropBinding: Binding<CropOffset>? = cropOffsets.map { offsetsBinding in
                Binding<CropOffset>(
                    get: { offsetsBinding.wrappedValue[url.absoluteString] ?? CropOffset() },
                    set: { offsetsBinding.wrappedValue[url.absoluteString] = $0 }
                )
            }
            let tagBinding: Binding<[String]>? = photoTags.map { tags in
                Binding<[String]>(
                    get: { tags.wrappedValue[url.absoluteString] ?? [] },
                    set: { newValue in
                        if newValue.isEmpty {
                            tags.wrappedValue[url.absoluteString] = nil
                        } else {
                            tags.wrappedValue[url.absoluteString] = newValue
                        }
                    }
                )
            }
            CroppablePhotoThumb(url: url, cropOffset: cropBinding,
                                photoTags: tagBinding,
                                tagSuggestions: tagSuggestions,
                                isReorderTarget: reorderTargetIndex == i,
                                isSelected: photoTags == nil ? nil : selection.contains(url.absoluteString),
                                onSelect: photoTags == nil ? nil : { extending in
                                    let key = url.absoluteString
                                    if extending {
                                        selection.extend(to: key, in: photos.map(\.absoluteString))
                                    } else {
                                        selection.toggle(key)
                                    }
                                },
                                onTag: photoTags == nil ? nil : { taggingIndex = i },
                                onPreview: onPreview,
                                onRemove: { removePhoto(url) })
        } else {
            PhotoThumb(url: url, isReorderTarget: reorderTargetIndex == i,
                       onPreview: onPreview) {
                removePhoto(url)
            }
        }
    }

    /// Removes a photo by identity (not index, which goes stale after a
    /// reorder) and clears its per-photo crop and tag entries so no orphan
    /// keys linger in events.json.
    private func removePhoto(_ url: URL) {
        photos.removeAll { $0 == url }
        cropOffsets?.wrappedValue.removeValue(forKey: url.absoluteString)
        photoTags?.wrappedValue.removeValue(forKey: url.absoluteString)
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
                    // Copy synchronously here: the temp URL is invalidated as
                    // soon as this closure returns, so the copy can't be
                    // deferred to the Task. (Drops from Photos, Mail, and
                    // browsers arrive through this branch.)
                    guard let stored = Self.permanentPhotoCopy(of: url) else { return }
                    Task { @MainActor in if !photos.contains(stored) { photos.append(stored) } }
                }
            }
        }
        return true
    }

    /// Copies a dropped photo into ~/Documents/PostRoll/photos/ so the stored
    /// path survives the provider's temp file deletion. Shares one copy
    /// implementation with the file-picker import path.
    private nonisolated static func permanentPhotoCopy(of url: URL) -> URL? {
        AppPaths.importedCopy(of: url, into: AppPaths.photosDir)
    }
}

// MARK: - Croppable Photo Thumb

private struct CroppablePhotoThumb: View {
    let url: URL
    /// Nil on a day that doesn't crop, which hides the crop button without
    /// touching any of the other controls.
    var cropOffset: Binding<CropOffset>? = nil
    var photoTags: Binding<[String]>? = nil
    var tagSuggestions: [PhotoTagSuggestion] = []
    var isReorderTarget: Bool = false
    /// Batch tagging (#172). Non-nil only where per-photo tagging exists; the
    /// Bool passed back says whether shift was held, so the grid can extend a
    /// range rather than toggle one photo.
    var isSelected: Bool? = nil
    var onSelect: ((_ extending: Bool) -> Void)? = nil
    /// Opens the tagging sheet for this photo. The sheet needs the whole day's
    /// photo list to step through, so it's owned by the grid, not the thumb.
    var onTag: (() -> Void)? = nil
    var onPreview: ((URL) -> Void)? = nil
    let onRemove: () -> Void

    @State private var image: NSImage?
    @State private var loadFailed = false
    @State private var showingCropPopover = false
    @State private var isHovered = false

    var offset: CropOffset { cropOffset?.wrappedValue ?? CropOffset() }
    var hasCrop: Bool { offset.x != 0 || offset.y != 0 }
    var hasTags: Bool { !(photoTags?.wrappedValue.isEmpty ?? true) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    let (ox, oy) = imageShift(image: image, frameW: 80, frameH: 80)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .offset(x: offset.x * ox, y: offset.y * oy)
                        .frame(width: 80, height: 80)
                        .clipped()
                } else if loadFailed {
                    MissingPhotoBadge()
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
                        loadFailed ? Color.roseGold.opacity(0.7)
                            : (isReorderTarget ? Color.roseGold : (hasCrop ? Color.roseGold.opacity(0.5) : Color.creamEdge)),
                        lineWidth: isReorderTarget ? 2 : (hasCrop || loadFailed ? 1.5 : 0.5)
                    )
            )
            .opacity(isReorderTarget ? 0.75 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isReorderTarget)
            .onTapGesture { onPreview?(url) }

            // Selection circle (top left), always drawn where batch tagging is
            // available so it reads as a control at rest, not on hover only.
            if let isSelected, let onSelect {
                VStack {
                    HStack {
                        Button {
                            onSelect(NSEvent.modifierFlags.contains(.shift))
                        } label: {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .symbolRenderingMode(isSelected ? .palette : .monochrome)
                                .foregroundStyle(isSelected ? Color.cream : .white.opacity(0.9),
                                                 Color.roseGold)
                                .font(.system(size: 15))
                                .shadow(color: .black.opacity(0.35), radius: 1.5)
                        }
                        .buttonStyle(.plain)
                        .help(isSelected ? "Selected. Shift-click to select a range."
                                         : "Select this photo to tag several at once. Shift-click to select a range.")
                        .accessibilityLabel(isSelected ? "Deselect photo" : "Select photo")
                        Spacer()
                    }
                    Spacer()
                }
                .padding(3)
                .frame(width: 80, height: 80)
            }

            // Remove button — top right
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.cream, Color.warmDark.opacity(0.7))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .padding(3)
            .opacity(isHovered ? 1 : 0)

            // Crop button (bottom left), visible on hover or when a crop is
            // active. Absent entirely on a day that doesn't crop.
            VStack {
                Spacer()
                HStack {
                    if let cropBinding = cropOffset {
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
                        .help("Adjust crop position")
                        .popover(isPresented: $showingCropPopover, arrowEdge: .bottom) {
                            CropOffsetPopover(image: image, cropOffset: cropBinding)
                        }
                        .opacity(isHovered || hasCrop ? 1 : 0)
                    }

                    if let tagBinding = photoTags, let onTag {
                        Button(action: onTag) {
                            Image(systemName: hasTags ? "tag.fill" : "tag")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(hasTags ? Color.roseGold : .white.opacity(0.85))
                                .padding(3)
                                .background(Color.black.opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(.plain)
                        .help(hasTags ? "Tagged: \(tagBinding.wrappedValue.joined(separator: ", "))" : "Tag people in this photo")
                        .accessibilityLabel(hasTags ? "Edit tags for this photo" : "Tag people in this photo")
                        // Always visible so per-photo tagging is discoverable;
                        // softer when the photo has no tags yet.
                        .opacity(hasTags || isHovered ? 1 : 0.9)
                    }

                    Spacer()
                }
                .padding(.leading, 4)
                .padding(.bottom, 4)
            }
            .frame(width: 80, height: 80)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .task {
            let loaded = await Task.detached { NSImage(contentsOf: url) }.value
            image = loaded
            loadFailed = (loaded == nil)
        }
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

// MARK: - Photo Tag Popover

/// One performer suggestion offered in the per-photo tag popover. `token` is
/// what gets inserted into the tag list (an @handle when there is one, else
/// the plain name); `display` also shows the name alongside the handle.
struct PhotoTagSuggestion: Identifiable, Hashable {
    let token: String
    let display: String
    var id: String { token }
}

/// The tag editing controls themselves: type a name or @handle, see what's
/// already tagged, one-tap the event's performers. Shared by the popover
/// (batch tagging) and the tagging sheet (one photo, shown large) so the two
/// surfaces can't drift apart.
private struct PhotoTagEditor: View {
    @Binding var tags: [String]
    var suggestions: [PhotoTagSuggestion] = []
    var tagsHeading: String = "TAGGED IN THIS PHOTO"
    var autoFocus: Bool = true
    @State private var newTag: String = ""
    @FocusState private var focused: Bool

    /// Suggestions not already present in the current tags.
    private var available: [PhotoTagSuggestion] {
        let current = Set(tags.map { $0.lowercased() })
        return suggestions.filter { !current.contains($0.token.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                TextField("Add a name or @handle", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmDark)
                    .focused($focused)
                    .focusEffectDisabled()
                    .onSubmit { commit(newTag); newTag = "" }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.xs)
                            .fill(Color.creamDeep)
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.xs)
                                    .strokeBorder(focused ? Color.roseGold : Color.creamEdge,
                                                  lineWidth: focused ? 1.5 : 1)
                            )
                    )
                if !newTag.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { commit(newTag); newTag = "" } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.roseGold)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if !tags.isEmpty {
                        Text(tagsHeading)
                            .font(.system(size: 8, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(Color.warmMid.opacity(0.7))
                        FlowLayout(spacing: 4) {
                            ForEach(tags, id: \.self) { tag in
                                HStack(spacing: 3) {
                                    Text(tag)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.warmDark)
                                        .lineLimit(1)
                                    Button { tags.removeAll { $0 == tag } } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 7, weight: .bold))
                                            .foregroundStyle(Color.warmMid)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(tag)")
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.roseGold.opacity(0.14)))
                            }
                        }
                    }

                    if !available.isEmpty {
                        Text("FROM THIS EVENT")
                            .font(.system(size: 8, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(Color.warmMid.opacity(0.7))
                        TagSuggestionFlow(suggestions: available) { picked in
                            addToken(picked.token)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if autoFocus { focused = true } }
    }

    /// Splits free text on commas and adds each token.
    private func commit(_ raw: String) {
        for token in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            addToken(token)
        }
    }

    private func addToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !tags.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            tags.append(trimmed)
        }
    }
}

/// The one place people are tagged. Shows the photo large (an 80pt thumbnail
/// is too small to tell who is actually in a wide stage shot, which is the
/// whole reason tagging exists) and walks previous/next.
///
/// `photos` is the scope being walked: the whole day when opened from a
/// photo's tag button, or just the selected photos when opened from the
/// selection bar. In the second case `isBatch` is true and the current
/// photo's tags can be copied onto every photo in the scope in one go (#172).
private struct PhotoTaggingSheet: View {
    let photos: [URL]
    @Binding var photoTags: [String: [String]]
    var suggestions: [PhotoTagSuggestion] = []
    var isBatch: Bool = false
    @Binding var index: Int
    let onClose: () -> Void

    @State private var image: NSImage?
    @State private var loadFailed = false

    private var safeIndex: Int {
        PhotoTagSheetNavigation.clamped(index: index, count: photos.count)
    }
    private var currentURL: URL? {
        photos.isEmpty ? nil : photos[safeIndex]
    }
    private var tagsBinding: Binding<[String]> {
        Binding<[String]>(
            get: { currentURL.flatMap { photoTags[$0.absoluteString] } ?? [] },
            set: { newValue in
                guard let key = currentURL?.absoluteString else { return }
                photoTags[key] = newValue.isEmpty ? nil : newValue
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            RoseGoldDivider(opacity: 0.2)

            HStack(alignment: .top, spacing: Spacing.lg) {
                photoPane
                    .frame(width: 460)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Names or @handles. Saved into CAPTIONS.txt for this photo so you know who to tag on the slide.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.warmMid.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)

                    // Re-created per photo so the text field clears and the
                    // chips reflect the photo now on screen, not the last one.
                    PhotoTagEditor(tags: tagsBinding, suggestions: suggestions)
                        .id(currentURL?.absoluteString ?? "none")

                    if isBatch, photos.count > 1 {
                        Button(action: applyToAll) {
                            Text("Add these to all \(photos.count) selected")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(tagsBinding.wrappedValue.isEmpty ? Color.warmMid : Color.cream)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: Radius.xs)
                                        .fill(tagsBinding.wrappedValue.isEmpty ? Color.creamDeep : Color.roseGold)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(tagsBinding.wrappedValue.isEmpty)
                        .help("Copies this photo's tags onto every selected photo. Tags already on a photo are kept.")
                    }
                }
                .frame(width: 260)
            }
            .padding(Spacing.lg)

            RoseGoldDivider(opacity: 0.2)
            footer
        }
        .frame(width: 800, height: 560)
        .background(Color.cream)
        .task(id: currentURL) { await loadCurrent() }
    }

    private var header: some View {
        HStack {
            Text("TAG PEOPLE")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.roseGold)
            Spacer()
            Text(PhotoTagSheetNavigation.label(index: safeIndex, count: photos.count))
                .font(.system(size: 11))
                .foregroundStyle(Color.warmMid)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.cream, Color.warmMid)
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close tagging")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    @ViewBuilder
    private var photoPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.md).fill(Color.creamDeep)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            } else if loadFailed {
                // An unreadable photo says so rather than sitting on a
                // spinner that looks identical to still loading.
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.roseGold)
                    Text("This photo could not be opened.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmMid)
                }
            } else {
                ProgressView().controlSize(.small).tint(Color.roseGold)
            }
        }
        .frame(height: 380)
    }

    private var footer: some View {
        HStack {
            Button {
                index = PhotoTagSheetNavigation.previous(from: safeIndex, count: photos.count)
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PhotoTagSheetNavigation.canGoPrevious(from: safeIndex, count: photos.count)
                             ? Color.roseGold : Color.warmFaint)
            .disabled(!PhotoTagSheetNavigation.canGoPrevious(from: safeIndex, count: photos.count))
            .keyboardShortcut(.leftArrow, modifiers: [])

            Spacer()

            Button {
                index = PhotoTagSheetNavigation.next(from: safeIndex, count: photos.count)
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .font(.system(size: 12))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PhotoTagSheetNavigation.canGoNext(from: safeIndex, count: photos.count)
                             ? Color.roseGold : Color.warmFaint)
            .disabled(!PhotoTagSheetNavigation.canGoNext(from: safeIndex, count: photos.count))
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    /// Copies the photo on screen onto every photo in the scope, adding only:
    /// a photo that already carries other tags keeps them.
    private func applyToAll() {
        photoTags = PhotoTagBatch.applying(
            tags: tagsBinding.wrappedValue,
            to: photos.map(\.absoluteString),
            in: photoTags)
    }

    private func loadCurrent() async {
        guard let url = currentURL else { return }
        image = nil
        loadFailed = false
        let loaded = await Task.detached { NSImage(contentsOf: url) }.value
        image = loaded
        loadFailed = (loaded == nil)
    }
}

/// Minimal wrapping layout: places subviews left to right, wrapping to the
/// next line when the current one runs out of width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Wrapping row of tappable performer suggestion chips.
private struct TagSuggestionFlow: View {
    let suggestions: [PhotoTagSuggestion]
    let onPick: (PhotoTagSuggestion) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(suggestions) { suggestion in
                Button {
                    onPick(suggestion)
                } label: {
                    Text(suggestion.display)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.roseGold)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.roseGold.opacity(0.10))
                                .overlay(Capsule().strokeBorder(Color.roseGold.opacity(0.3), lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
                .help(suggestion.display)
            }
        }
    }
}

// MARK: - Crop Offset Popover

struct CropOffsetPopover: View {
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
    @Binding var bwPhoto: URL?
    @Binding var targetDuration: Double
    let dayPhotos: [URL]
    let onPickScreenRecording: () -> Void
    let onPickRawPhoto: () -> Void
    let onPickEditedPhoto: () -> Void
    let onPickBWPhoto: () -> Void

    @State private var isExpanded = true
    @State private var recordingSeconds: Double? = nil

    var hasReelInputs: Bool { rawPhoto != nil && editedPhoto != nil }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: hasReelInputs ? "film.fill" : "film")
                        .font(.system(size: 11))
                        .foregroundStyle(hasReelInputs ? Color.roseGold : Color.warmMid)
                    Text("SPEED EDIT REEL")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                    if hasReelInputs {
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
                    Text("RAW and edited photos become a before/after reel. Add a screen recording for a timelapse version.")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                        .padding(.bottom, 4)

                    BeforeAfterPicker(
                        label: "RAW Photo",
                        selected: rawPhoto,
                        otherSelected: editedPhoto,
                        dayPhotos: dayPhotos,
                        onSelect: { url in
                            rawPhoto = url
                            // Auto-pair: with exactly two day photos, picking one
                            // for RAW automatically picks the other for Edited.
                            if editedPhoto == nil, dayPhotos.count == 2,
                               let other = dayPhotos.first(where: { $0 != url }) {
                                editedPhoto = other
                            }
                        },
                        onClear: { rawPhoto = nil },
                        onPickFromFile: onPickRawPhoto
                    )
                    BeforeAfterPicker(
                        label: "Edited Photo",
                        selected: editedPhoto,
                        otherSelected: rawPhoto,
                        dayPhotos: dayPhotos,
                        onSelect: { url in
                            editedPhoto = url
                            if rawPhoto == nil, dayPhotos.count == 2,
                               let other = dayPhotos.first(where: { $0 != url }) {
                                rawPhoto = other
                            }
                        },
                        onClear: { editedPhoto = nil },
                        onPickFromFile: onPickEditedPhoto
                    )

                    if rawPhoto != nil && editedPhoto != nil {
                        Button {
                            let tmp = rawPhoto
                            rawPhoto = editedPhoto
                            editedPhoto = tmp
                        } label: {
                            Label("Swap RAW ↔ Edited", systemImage: "arrow.up.arrow.down")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.roseGold)
                    }

                    // Optional B&W after. When set, the reel reveals color over
                    // B&W and the Friday graphic stacks all three. Rare; leave
                    // empty for the normal two-photo before/after.
                    BeforeAfterPicker(
                        label: "B&W Edit (optional)",
                        selected: bwPhoto,
                        otherSelected: nil,
                        dayPhotos: dayPhotos,
                        onSelect: { url in bwPhoto = url },
                        onClear: { bwPhoto = nil },
                        onPickFromFile: onPickBWPhoto
                    )
                    if bwPhoto != nil {
                        Text("3-photo post: reel reveals color over B&W, Friday shows all three.")
                            .font(.light(10))
                            .foregroundStyle(Color.roseGold.opacity(0.9))
                    }

                    SingleFilePicker(label: "Screen Recording", url: screenRecording,
                                     onPick: onPickScreenRecording, onClear: { screenRecording = nil })

                    if screenRecording != nil && hasReelInputs {
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

    @State private var isExpanded = true

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
                        Text("Need 10 photos to generate the collage. \(10 - photoCount) more required.")
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
    var audioMissing: Bool = false
    @Binding var scrollDuration: Double
    @Binding var reelSeed: Int?
    let onPickAudio: () -> Void
    var onLocateAudio: () -> Void = {}

    @State private var isExpanded = true

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
                        Text("Optional audio, auto-fetched from Jamendo if omitted.")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                        AudioFilePicker(audio: $audio, isMissing: audioMissing,
                                        onPick: onPickAudio, onLocate: onLocateAudio)
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
                    VStack(alignment: .leading, spacing: 2) {
                        Button("New layout") { reelSeed = Int.random(in: 1...99999) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.roseGold)
                        Text("Re-rolls the photo arrangement. Takes effect when the reel is generated.")
                            .font(.light(10))
                            .foregroundStyle(Color.warmFaint)
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

// MARK: - Friday Before/After Section

private struct FridayBeforeAfterSection: View {
    let rawPhoto: URL?
    let editedPhoto: URL?

    var hasPhotos: Bool { rawPhoto != nil && editedPhoto != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Day header — matches PhotoDaySection styling so Friday reads as a real day
            HStack(alignment: .center, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FRIDAY")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(hasPhotos ? Color.roseGold : Color.warmMid)
                    Text("Before/after story — reuses Tuesday's RAW + edited photos")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                }
                Spacer()
                if hasPhotos {
                    Text("ready")
                        .font(.light(11))
                        .foregroundStyle(Color.roseGold.opacity(0.7))
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, 14)

            RoseGoldDivider(opacity: 0.3)
        }
    }
}

// MARK: - Before/After Photo Picker
//
// Lets the user assign one of Tuesday's already-uploaded photos as the RAW or
// Edited photo for the speed-edit reel. Shows a horizontal thumbnail strip;
// clicking a thumbnail assigns it. Falls back to a file picker if the photo
// they want isn't in Tuesday's day photos.

private struct BeforeAfterPicker: View {
    let label: String
    let selected: URL?
    let otherSelected: URL?       // Hidden from this row's strip
    let dayPhotos: [URL]
    let onSelect: (URL) -> Void
    let onClear: () -> Void
    let onPickFromFile: () -> Void

    /// Photos available for THIS role: day photos minus whatever the other role uses.
    private var availablePhotos: [URL] {
        dayPhotos.filter { $0 != otherSelected }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
                .frame(width: 110, alignment: .leading)
                .padding(.top, 16)  // Aligns with thumbnail centers

            if dayPhotos.isEmpty {
                HStack(spacing: 6) {
                    Button("Choose…", action: onPickFromFile)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.roseGold)
                    if selected != nil {
                        Spacer()
                        Button(action: onClear) {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.warmMid.opacity(0.6), Color.creamEdge)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 6) {
                    ForEach(availablePhotos, id: \.self) { url in
                        BeforeAfterThumb(
                            url: url,
                            isSelected: selected == url,
                            onTap: {
                                if selected == url { onClear() } else { onSelect(url) }
                            }
                        )
                    }
                    Button(action: onPickFromFile) {
                        VStack(spacing: 2) {
                            Image(systemName: "plus")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.roseGold)
                            Text("File")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.warmMid)
                        }
                        .frame(width: 40, height: 40)
                        .background(Color.creamDeep)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.creamEdge, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Pick from a different folder")
                }
            }
            Spacer()
        }
    }
}

private struct BeforeAfterThumb: View {
    let url: URL
    let isSelected: Bool
    let onTap: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.creamDeep
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(isSelected ? 1.0 : 0.55)        // Unselected dim → "click me"
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            isSelected ? Color.roseGold : Color.creamEdge,
                            lineWidth: isSelected ? 3 : 1
                        )
                )

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.cream, Color.roseGold)
                        .font(.system(size: 14))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Tap to clear" : "Tap to assign")
        .task {
            let captured = url
            image = await Task.detached {
                guard FileManager.default.fileExists(atPath: captured.path) else { return nil }
                return NSImage(contentsOf: captured)
            }.value
        }
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
    var onPreview: ((URL) -> Void)? = nil
    let onRemove: () -> Void
    @State private var image: NSImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if loadFailed {
                    MissingPhotoBadge()
                } else {
                    Color.creamDeep.overlay { ProgressView().controlSize(.small).tint(Color.roseGold) }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(loadFailed ? Color.roseGold.opacity(0.7) : (isReorderTarget ? Color.roseGold : Color.creamEdge),
                                  lineWidth: isReorderTarget ? 2 : (loadFailed ? 1.5 : 0.5))
            )
            .opacity(isReorderTarget ? 0.75 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isReorderTarget)
            .onTapGesture { onPreview?(url) }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.cream, Color.warmDark.opacity(0.7))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .padding(3)
        }
        .task {
            let loaded = await Task.detached { NSImage(contentsOf: url) }.value
            image = loaded
            loadFailed = (loaded == nil)
        }
    }
}

/// Banner shown when an event references photos whose files are gone, offering
/// to drop the dead references in one click.
private struct MissingPhotosBanner: View {
    let count: Int
    let onLocate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.roseGold)
            Text("\(count) photo\(count == 1 ? "" : "s") can't be found — the file\(count == 1 ? " was" : "s were") moved or deleted off disk.")
                .font(.system(size: 11))
                .foregroundStyle(Color.warmDark)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Locate…", action: onLocate)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.roseGold)
            Text("·").foregroundStyle(Color.warmMid.opacity(0.5))
            Button("Remove missing", action: onRemove)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.warmMid)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.roseGold.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.roseGold.opacity(0.25), lineWidth: 0.5))
        )
    }
}

/// Placeholder shown in a photo thumbnail when the underlying file can't be
/// read (moved or deleted off disk).
private struct MissingPhotoBadge: View {
    var body: some View {
        Color.creamDeep.overlay {
            VStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.roseGold.opacity(0.85))
                Text("missing")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color.warmMid)
            }
        }
    }
}

// MARK: - Audio File Picker (with play/pause)

private struct AudioFilePicker: View {
    @Binding var audio: URL?
    var isMissing: Bool = false
    let onPick: () -> Void
    var onLocate: () -> Void = {}

    @State private var player: AVAudioPlayer? = nil
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text("AUDIO FILE")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
                .frame(width: 110, alignment: .leading)

            if let url = audio, isMissing {
                // File set but gone from disk — mirror the missing-photo flag.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseGold)
                Text("\(url.lastPathComponent) can't be found")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warmDark)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Locate…", action: onLocate)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.roseGold)
                Button(action: { audio = nil; stopPlayback() }) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.warmMid.opacity(0.6), Color.creamEdge)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Remove")
            } else if let url = audio {
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warmDark)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    togglePlayback(url: url)
                } label: {
                    Image(systemName: isPlaying ? "pause.circle" : "play.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.roseGold)
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play")
                Button(action: { audio = nil; stopPlayback() }) {
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
        .onChange(of: audio) { _, _ in stopPlayback() }
    }

    private func togglePlayback(url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            if player?.url != url {
                player = try? AVAudioPlayer(contentsOf: url)
            }
            player?.play()
            isPlaying = true
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}

// MARK: - Day Notes Field

private struct DayNotesField: View {
    @Binding var notes: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 10))
                .foregroundStyle(notes.isEmpty && !focused ? Color.warmMid.opacity(0.3) : Color.warmMid.opacity(0.6))
            TextField("", text: $notes, prompt: Text("Notes for today's shoot (seen by caption generator)").foregroundStyle(Color.warmMid.opacity(0.30)))
                .focused($focused)
                .font(.light(11))
                .foregroundStyle(Color.warmDark)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, 7)
        .background(focused || !notes.isEmpty ? Color.roseGold.opacity(0.03) : Color.clear)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - Photo Preview Overlay

private struct PhotoPreviewOverlay: View {
    let url: URL
    let onDismiss: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(48)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 6)
            } else {
                ProgressView().tint(.white)
            }

            // Dismiss button — top right
            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white.opacity(0.9), Color.warmDark.opacity(0.5))
                            .font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)   // Esc dismisses the preview
                    .padding(16)
                }
                Spacer()
            }
        }
        .task { image = await Task.detached { NSImage(contentsOf: url) }.value }
    }
}

// MARK: - Performer Assignment Section

private struct PerformerAssignmentSection: View {
    let day: DayName
    let performers: [Performer]
    let eventHandles: String     // Org + venue handles applied to every post
    @Binding var selectedPerformerIDs: Set<UUID>
    @Binding var handles: String
    @Binding var names: String
    /// True on a day laid out as a per-photo carousel, where people are tagged
    /// on the photos themselves and this panel is the fallback (#171).
    let isCarouselDay: Bool
    let onChanged: () -> Void

    @State private var isExpanded: Bool

    init(day: DayName, performers: [Performer], eventHandles: String,
         selectedPerformerIDs: Binding<Set<UUID>>, handles: Binding<String>,
         names: Binding<String>, isCarouselDay: Bool, onChanged: @escaping () -> Void) {
        self.day = day
        self.performers = performers
        self.eventHandles = eventHandles
        self._selectedPerformerIDs = selectedPerformerIDs
        self._handles = handles
        self._names = names
        self.isCarouselDay = isCarouselDay
        self.onChanged = onChanged
        let hasContent = !handles.wrappedValue.isEmpty
            || !names.wrappedValue.isEmpty
            || !selectedPerformerIDs.wrappedValue.isEmpty
        self._isExpanded = State(initialValue: PerformerPanelDisplay.startsExpanded(
            isCarouselDay: isCarouselDay, hasContent: hasContent))
    }

    private var hasContent: Bool {
        !handles.isEmpty || !names.isEmpty || !selectedPerformerIDs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    Image(systemName: hasContent ? "person.crop.rectangle.stack.fill" : "person.crop.rectangle.stack")
                        .font(.system(size: 11))
                        .foregroundStyle(hasContent ? Color.roseGold : Color.warmMid)
                    Text(PerformerPanelDisplay.title(isCarouselDay: isCarouselDay))
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                    if hasContent {
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
                    if let hint = PerformerPanelDisplay.hint(isCarouselDay: isCarouselDay) {
                        Text(hint)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.warmMid.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !performers.isEmpty {
                        PerformerCheckboxGrid(
                            performers: performers,
                            selectedIDs: $selectedPerformerIDs
                        )
                        .onChange(of: selectedPerformerIDs) { _, _ in onChanged() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HandleField(
                            label: "additional @handles (comma-separated)",
                            placeholder: "@guestartist, @ensemble",
                            text: $handles
                        )
                        .onChange(of: handles) { _, _ in onChanged() }

                        if !eventHandles.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("Already tagged on every post: \(eventHandles)")
                                .font(.system(size: 10).italic())
                                .foregroundStyle(Color.warmFaint.opacity(0.85))
                        }
                    }

                    HandleField(
                        label: "additional plain names (no @, comma-separated)",
                        placeholder: "Jordan Langworthy, Maria Smith",
                        text: $names
                    )
                    .onChange(of: names) { _, _ in onChanged() }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.15)
        }
        .background(Color.roseGold.opacity(0.02))
    }
}

private struct PerformerCheckboxGrid: View {
    let performers: [Performer]
    @Binding var selectedIDs: Set<UUID>

    private var allSelected: Bool {
        performers.allSatisfy { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if allSelected {
                    selectedIDs = []
                } else {
                    selectedIDs = Set(performers.map(\.id))
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(allSelected ? Color.roseGold : Color.warmMid.opacity(0.5))
                    Text(allSelected ? "Deselect all" : "Select all")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
            }
            .buttonStyle(.plain)

            let columns = [GridItem(.adaptive(minimum: 230), spacing: 6)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(performers) { performer in
                    PerformerCheckbox(
                        performer: performer,
                        isSelected: selectedIDs.contains(performer.id)
                    ) { selected in
                        if selected {
                            selectedIDs.insert(performer.id)
                        } else {
                            selectedIDs.remove(performer.id)
                        }
                    }
                }
            }
        }
    }
}

private struct PerformerCheckbox: View {
    let performer: Performer
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    private var designation: String { performer.designation }

    var body: some View {
        Button { onToggle(!isSelected) } label: {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.roseGold : Color.warmMid.opacity(0.5))
                Text(performer.name)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.warmDark : Color.warmMid)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !designation.isEmpty {
                    Text(designation.lowercased())
                        .font(.system(size: 10).italic())
                        .foregroundStyle(Color.warmMid.opacity(0.75))
                        .lineLimit(1)
                }
                if PythonBridge.isRealHandle(performer.handle) {
                    Text(performer.handle.hasPrefix("@") ? performer.handle : "@\(performer.handle)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.warmMid.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .help(helpText)
        }
        .buttonStyle(.plain)
    }

    private var helpText: String {
        var parts = [performer.name]
        if !designation.isEmpty { parts.append(designation) }
        if PythonBridge.isRealHandle(performer.handle) {
            parts.append(performer.handle.hasPrefix("@") ? performer.handle : "@\(performer.handle)")
        }
        return parts.joined(separator: ", ")
    }
}

private struct HandleField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12).italic())
                        .foregroundStyle(Color.warmFaint.opacity(0.45))
                        .padding(.horizontal, 8)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .focused($focused)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmDark)
                    .focusEffectDisabled()
                    .padding(.horizontal, 8)
            }
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(Color.creamDeep)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.xs)
                                .strokeBorder(
                                    focused ? Color.roseGold : Color.creamEdge,
                                    lineWidth: focused ? 1.5 : 1
                                )
                        )
                )
                .animation(.easeOut(duration: 0.12), value: focused)
        }
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
