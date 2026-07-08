import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct CaptionReviewView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(HashtagStore.self) private var hashtagStore

    @State private var result: WeekGenerationResult
    @State private var expanded: ReviewSection? = nil
    @State private var isRegenerating = false
    @State private var showRegenerateConfirm = false
    @State private var regenerateError: String?

    enum ReviewSection: Equatable {
        case caption(DayName)
        case blog
    }

    init(event: Event) {
        self.event = event
        _result = State(initialValue: event.weekResult ?? WeekGenerationResult())
        var offsets: [String: [String: CropOffset]] = [:]
        for (key, pd) in event.days where !pd.collageCropOffsets.isEmpty {
            offsets[key] = pd.collageCropOffsets
        }
        _dayCollageCropOffsets = State(initialValue: offsets)
        var reelOffsets: [String: [String: CropOffset]] = [:]
        for (key, pd) in event.days where !pd.reelCropOffsets.isEmpty {
            reelOffsets[key] = pd.reelCropOffsets
        }
        _dayReelCropOffsets = State(initialValue: reelOffsets)
        var cellOverrides: [String: [CollageCell]] = [:]
        for (key, pd) in event.days {
            if let override = pd.collageCellOverride { cellOverrides[key] = override }
        }
        _dayCollageCellOverrides = State(initialValue: cellOverrides)
        var clipOverrides: [String: [ReelClipOverride]] = [:]
        for (key, pd) in event.days {
            if let override = pd.fridayClipOverride { clipOverrides[key] = override }
        }
        _dayFridayClipOverride = State(initialValue: clipOverrides)
    }

    var daysWithContent: [DayName] {
        DayName.allCases.filter { day in
            if result[day] != nil { return true }
            if day == .friday, let pd = event.days[day.rawValue],
               (pd.rawPhotoPath != nil || pd.editedPhotoPath != nil || !pd.photoPaths.isEmpty) {
                return true
            }
            return false
        }
    }

    @State private var previewURL: URL? = nil

    // Collage layout gallery (#57). Non-nil → the picker sheet is shown for that day.
    @State private var layoutGalleryTarget: GalleryTarget? = nil

    /// Identifiable wrapper so the layout gallery can drive `.sheet(item:)`.
    struct GalleryTarget: Identifiable {
        let day: DayName
        var id: String { day.rawValue }
    }

    // Upload-your-own reel audio
    @State private var showingReelAudioPicker = false
    @State private var uploadReelAudioDay: DayName = .tuesday

    // Inline RAW/Edited photo state (used by InlineReelPhotoAssignment)
    @State private var inlineRawPhoto: URL? = nil
    @State private var inlineEditedPhoto: URL? = nil
    // Optional B&W after. When set, the reel reveals color over B&W and the
    // Friday graphic stacks all three (RAW / color / B&W).
    @State private var inlineBWPhoto: URL? = nil

    // Learning flow
    @State private var isAnalyzingEdits = false
    @State private var learningSuggestion: String? = nil
    @State private var showLearnSheet = false

    // Preview graphics generation
    @State private var isGeneratingGraphics = false
    @State private var regeneratingDays: Set<DayName> = []
    /// When each day's current regen started, so the UI can show elapsed
    /// time instead of a bare spinner (#135's Friday pipeline in particular:
    /// import copy + Stage 1 scoring + Stage 2 Claude + ffmpeg render can
    /// genuinely take a while).
    @State private var regenerationStartTimes: [DayName: Date] = [:]
    @State private var graphicVersions: [DayName: Int] = [:]

    // Cover image regen (Thursday + Friday only, #141). Separate from
    // regeneratingDays/regenerationStartTimes: regenerating the cover must
    // never look like (or actually trigger) a full reel/story regen.
    @State private var coverRegeneratingDays: Set<DayName> = []
    @State private var coverRegenerationStartTimes: [DayName: Date] = [:]

    // Collage crop offsets (separate from carousel) — keyed by day rawValue then photo URL absoluteString
    @State private var dayCollageCropOffsets: [String: [String: CropOffset]] = [:]
    // Thursday reel crop offsets — same shape, independent storage so reels and collages don't fight
    @State private var dayReelCropOffsets: [String: [String: CropOffset]] = [:]
    // Collage cell layout overrides — keyed by day rawValue; nil entry = use Python layout
    @State private var dayCollageCellOverrides: [String: [CollageCell]] = [:]
    // Friday clip reel manual edits (reorder/include-exclude/trim), keyed by day rawValue
    @State private var dayFridayClipOverride: [String: [ReelClipOverride]] = [:]

    // Thursday reel editor — built eagerly in the background on view appear so the
    // PNG + layout JSON are ready by the time the user expands the Thursday card.
    @State private var thursdayEditorURL: URL? = nil
    @State private var isBuildingThursdayEditor: Bool = false

    // Pre-renders the Thursday reel in the background as the user edits crops /
    // swaps photos, so "Apply changes" usually adopts a finished encode instead
    // of waiting on ffmpeg. Reset per event (the view is .id(event.id)-remounted).
    @State private var speculativeReel = SpeculativeReelRenderer(day: .thursday)

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    EventHeader(event: event, subtitle: "Review Content")
                        .padding([.horizontal, .top], Spacing.xl)
                        .padding(.bottom, Spacing.sm)

                    StageBackButton(label: "Back to generation") {
                        var ev = event
                        ev.stage = .assetsGenerated
                        appState.updateEvent(ev)
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.md)

                    if result.errorCount > 0 {
                        BrandBanner(
                            icon: "exclamationmark.triangle",
                            message: "\(result.errorCount) day\(result.errorCount == 1 ? "" : "s") failed to generate. You can re-run generation from the previous step.",
                            style: .error
                        )
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.md)
                    }

                    ForEach(daysWithContent, id: \.self) { day in
                        let section = ReviewSection.caption(day)
                        // Read postingDay + previewPaths from liveEvent, not the
                        // captured `event` property. The captured value never
                        // refreshes when AppState changes, so a regen that updates
                        // previewMediaPaths in AppState wouldn't propagate to the
                        // mockup — it would keep rendering the old MP4 path.
                        let live = liveEvent
                        CaptionSection(
                            day: day,
                            postingDay: live.days[day.rawValue],
                            previewPaths: live.previewMediaPaths[day.rawValue],
                            caption: captionBinding(day),
                            isExpanded: expanded == section,
                            onToggle: { expanded = expanded == section ? nil : section },
                            onRevise: { feedback in
                                try await reviseCaption(day: day, feedback: feedback)
                            },
                            onPreview: { previewURL = $0 },
                            isRegeneratingGraphic: regeneratingDays.contains(day),
                            graphicVersion: graphicVersions[day] ?? 0,
                            onRegenerateGraphic: {
                                regenerateGraphic(day: day)
                                // Tuesday's before/after reel and Friday's before/after
                                // graphic share the same RAW/Edited/B&W, so regenerate
                                // Friday whenever the Tuesday reel does — but only when
                                // Friday actually has before/after inputs to render.
                                if day == .tuesday,
                                   let fri = appState.events.first(where: { $0.id == event.id })?
                                       .days[DayName.friday.rawValue],
                                   fri.rawPhotoPath != nil, fri.editedPhotoPath != nil {
                                    regenerateGraphic(day: .friday)
                                }
                            },
                            onNewLayout: (isCollageDay(day) || day == .thursday)
                                ? { regenerateGraphic(day: day, newLayout: true) }
                                : nil,
                            onSwapReelAudio: { swapReelAudio(day: day) },
                            onUploadReelAudio: { uploadReelAudioDay = day; showingReelAudioPicker = true },
                            reelLength: day == .thursday ? (live.days[day.rawValue]?.scrollDuration ?? 40.0) : nil,
                            onChangeReelLength: day == .thursday ? { newLength in changeReelLength(day: .thursday, to: newLength) } : nil,
                            onChangeReelPhotos: (day == .tuesday || day == .thursday) ? { changeReelPhotos(day: day) } : nil,
                            onImportFridayClips: day == .friday ? { importFridayClips() } : nil,
                            onApplyFridayOverride: day == .friday ? { applyFridayOverride($0) } : nil,
                            onSwapFridayClip: day == .friday ? { swapFridayClip($0) } : nil,
                            onRecutFridayWithAI: day == .friday ? { recutFridayWithAI() } : nil,
                            fridayRegenStartedAt: day == .friday ? regenerationStartTimes[.friday] : nil,
                            fridayRegenerateError: day == .friday ? regenerateError : nil,
                            onSkipFridayClips: day == .friday ? { skipFridayClipsKeepStoryOnly() } : nil,
                            onChangeCollagePhotos: isCollageDay(day) ? { changeCollagePhotos(day: day) } : nil,
                            onChooseLayout: isCollageDay(day) ? { layoutGalleryTarget = GalleryTarget(day: day) } : nil,
                            onSwapReelPhotos: day == .thursday ? { a, b in swapReelPhotos(day: .thursday, a: a, b: b) } : nil,
                            onAssignReelPhotos: day == .tuesday ? { raw, edited, bw in
                                assignReelPhotosAndGenerate(raw: raw, edited: edited, bw: bw)
                            } : nil,
                            onPickInlineRaw: day == .tuesday ? {
                                let panel = NSOpenPanel()
                                panel.title = "Select RAW (unedited) photo"
                                panel.allowedContentTypes = [.image]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    inlineRawPhoto = url
                                }
                            } : nil,
                            onPickInlineEdited: day == .tuesday ? {
                                let panel = NSOpenPanel()
                                panel.title = "Select Edited photo"
                                panel.allowedContentTypes = [.image]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    inlineEditedPhoto = url
                                }
                            } : nil,
                            onPickInlineBW: day == .tuesday ? {
                                let panel = NSOpenPanel()
                                panel.title = "Select B&W edit (optional)"
                                panel.allowedContentTypes = [.image]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    inlineBWPhoto = url
                                }
                            } : nil,
                            onClearInlineBW: day == .tuesday ? { inlineBWPhoto = nil } : nil,
                            onChangeBW: day == .tuesday ? { changeBWPhoto() } : nil,
                            onRemoveBW: day == .tuesday ? { removeBWPhoto() } : nil,
                            inlineRawPhoto: inlineRawPhoto,
                            inlineEditedPhoto: inlineEditedPhoto,
                            inlineBWPhoto: inlineBWPhoto,
                            collageCropOffsets: isCollageDay(day) ? collageOffsetsBinding(day) : nil,
                            collageCellOverride: isCollageDay(day) ? collageCellOverrideBinding(day) : nil,
                            reelCropOffsets: day == .thursday ? reelOffsetsBinding(day) : nil,
                            thursdayEditorURL: day == .thursday ? thursdayEditorURL : nil,
                            isBuildingThursdayEditor: day == .thursday ? isBuildingThursdayEditor : false,
                            isCoverRegenerating: coverRegeneratingDays.contains(day),
                            coverRegenStartedAt: coverRegenerationStartTimes[day],
                            onRegenerateCover: (day == .thursday || day == .friday) ? { regenerateCover(day: day) } : nil,
                            onChooseCoverOverride: (day == .thursday || day == .friday) ? {
                                let panel = NSOpenPanel()
                                panel.title = "Choose a cover photo"
                                panel.allowedContentTypes = [.image]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    regenerateCover(day: day, overrideSource: url)
                                }
                            } : nil
                        )
                        .disabled(isRegenerating)
                    }

                    if result.blog != nil {
                        BlogSection(
                            blog: blogBinding,
                            photoCount: event.blogPhotoPaths.count,
                            isExpanded: expanded == .blog,
                            onToggle: { expanded = expanded == .blog ? nil : .blog },
                            onRevise: { feedback in try await reviseBlog(feedback: feedback) },
                            onSwapPhotos: { urls in try await swapBlogPhotos(urls: urls) }
                        )
                        .disabled(isRegenerating)
                    }

                if let error = regenerateError {
                    BrandBanner(icon: "exclamationmark.triangle", message: error, style: .error)
                        .padding(.horizontal, Spacing.xl)
                }

                if isRegenerating {
                    HStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.small).tint(Color.roseGold)
                        Text("Regenerating captions…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.warmDark)
                        Text("~3 to 6 min")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    }
                    .padding(Spacing.xl)
                } else if isGeneratingGraphics {
                    HStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.small).tint(Color.roseGold)
                        Text("Generating story graphics…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.warmDark)
                        Text("~1 min")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    }
                    .padding(Spacing.xl)
                } else if isAnalyzingEdits {
                    HStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.small).tint(Color.roseGold)
                        Text("Reviewing your edits…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.warmDark)
                    }
                    .padding(Spacing.xl)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Button("Regenerate All…") { showRegenerateConfirm = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.warmMid)
                            Spacer()
                            Button("Approve & Export") { advance() }
                                .buttonStyle(BrandButtonStyle())
                        }
                        .padding(Spacing.xl)
                    }
                }
            }
            }
            .background(Color.cream)
            .onAppear {
                mergeGlobalTags()
                if event.previewMediaPaths.isEmpty {
                    generateGraphics()
                } else {
                    prepareThursdayEditor()
                }
            }
            .alert("Regenerate all captions?", isPresented: $showRegenerateConfirm) {
                Button("Regenerate", role: .destructive) {
                    Task { await regenerateAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will replace all current captions and the blog draft. Your inline edits will be lost.")
            }

            // Full-screen photo preview overlay
            if let url = previewURL {
                ReviewPhotoOverlay(url: url, onDismiss: { previewURL = nil })
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: previewURL != nil)
        .sheet(item: $layoutGalleryTarget) { target in
            CollageLayoutGallery(
                event: liveEvent,
                day: target.day,
                onPick: { seed in
                    layoutGalleryTarget = nil
                    applyCollageLayout(day: target.day, seed: seed)
                },
                onCancel: { layoutGalleryTarget = nil }
            )
        }
        .sheet(isPresented: $showLearnSheet) {
            if let suggestion = learningSuggestion {
                LearningSuggestionSheet(
                    suggestion: suggestion,
                    onSave: { editedSuggestion in
                        try? PythonBridge.shared.appendBrandVoiceNote(editedSuggestion)
                        showLearnSheet = false
                        finalizeAdvance()
                    },
                    onSkip: {
                        showLearnSheet = false
                        finalizeAdvance()
                    }
                )
            }
        }
        .fileImporter(
            isPresented: $showingReelAudioPicker,
            allowedContentTypes: [.audio, .mp3, .wav, .aiff, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                uploadReelAudio(day: uploadReelAudioDay, url: url)
            }
        }
    }

    // MARK: - Bindings

    /// A day whose feed is a carousel + editable collage story: Wednesday always,
    /// plus Sunday/Monday under a balanced layout. Uses this event's effective
    /// preset so a per-event override is respected.
    private func isCollageDay(_ day: DayName) -> Bool {
        liveEvent.effectivePostingPreset.isCollageCarousel(day)
    }

    private func collageOffsetsBinding(_ day: DayName) -> Binding<[String: CropOffset]> {
        Binding(
            get: { dayCollageCropOffsets[day.rawValue] ?? [:] },
            set: { dayCollageCropOffsets[day.rawValue] = $0; save() }
        )
    }

    private func reelOffsetsBinding(_ day: DayName) -> Binding<[String: CropOffset]> {
        Binding(
            get: { dayReelCropOffsets[day.rawValue] ?? [:] },
            set: {
                dayReelCropOffsets[day.rawValue] = $0
                save()
                // Assume the user will Apply: start encoding the new crop in the
                // background now so the button press is near-instant.
                if day == .thursday { speculativeReel.schedule(for: liveEvent) }
            }
        )
    }

    private func collageCellOverrideBinding(_ day: DayName) -> Binding<[CollageCell]?> {
        Binding(
            get: { dayCollageCellOverrides[day.rawValue] },
            set: {
                if let cells = $0 { dayCollageCellOverrides[day.rawValue] = cells }
                else { dayCollageCellOverrides.removeValue(forKey: day.rawValue) }
                save()
            }
        )
    }

    private func captionBinding(_ day: DayName) -> Binding<DayCaption> {
        Binding(
            get: { result[day] ?? DayCaption() },
            set: { result[day] = $0; save() }
        )
    }

    private var blogBinding: Binding<BlogOutput> {
        Binding(
            get: { result.blog ?? BlogOutput() },
            set: { result.blog = $0; save() }
        )
    }

    // MARK: - Regenerate all

    /// Read the current event from AppState by id. The captured `event` value
    /// can become stale relative to AppState (e.g. when @State leaks across
    /// detail-pane switches), so any code path that hands an Event to Python
    /// must use this — otherwise Python regenerates on stale data and saves
    /// the wrong-event content back under the right-event id.
    private var liveEvent: Event {
        appState.events.first(where: { $0.id == event.id }) ?? event
    }

    private func regenerateAll() async {
        isRegenerating = true
        regenerateError = nil
        do {
            let live = liveEvent
            let newResult = try await PythonBridge.shared.runWeekGeneration(event: live)
            result = newResult
            mergeGlobalTags()
            NotificationService.shared.notifyRegenerationComplete(eventName: live.name, what: "Captions")
        } catch {
            regenerateError = error.localizedDescription
        }
        isRegenerating = false
    }

    // MARK: - Global hashtag merge

    private func mergeGlobalTags() {
        guard !hashtagStore.globalTags.isEmpty else { return }
        var changed = false
        for day in daysWithContent {
            guard var cap = result[day] else { continue }
            var dayChanged = false
            for tag in hashtagStore.globalTags where !cap.hashtags.contains(tag) {
                cap.hashtags.append(tag)
                dayChanged = true
            }
            if dayChanged { result[day] = cap; changed = true }
        }
        if changed { save() }
    }

    // MARK: - Preview graphics

    private func generateGraphics() {
        isGeneratingGraphics = true
        Task {
            if let result = try? await PythonBridge.shared.runPreviewGeneration(event: liveEvent),
               !result.paths.isEmpty {
                await MainActor.run {
                    // Base the write-back on the live event: the run takes a
                    // minute or more and a snapshot would revert interleaved edits.
                    var ev = appState.events.first(where: { $0.id == event.id }) ?? event
                    ev.previewMediaPaths = result.paths
                    ev.applyFridayClipPlan(result.fridayClipPlan)
                    for (day, pick) in result.coverPicks { ev.applyCoverPick(pick, forDay: day) }
                    appState.updateEvent(ev)
                }
            }
            await MainActor.run {
                isGeneratingGraphics = false
                // Fresh generation already wrote reel_preview.png as a side
                // effect — this just resolves the URL so the Thursday card is
                // instant when expanded.
                prepareThursdayEditor()
            }
        }
    }

    /// Kick off the Thursday reel still-preview build in the background so the
    /// per-cell editor is ready the moment the user expands Thursday. Safe to
    /// call multiple times — idempotent via `thursdayEditorURL` and the
    /// in-progress guard.
    private func prepareThursdayEditor() {
        guard thursdayEditorURL == nil, !isBuildingThursdayEditor else { return }
        let live = appState.events.first(where: { $0.id == event.id }) ?? event
        guard let thurPd = live.days[DayName.thursday.rawValue],
              !thurPd.photoPaths.isEmpty,
              let reelStr = live.previewMediaPaths[DayName.thursday.rawValue]?["reel"] else {
            return
        }
        let expected = URL(fileURLWithPath: reelStr)
            .deletingLastPathComponent()
            .appendingPathComponent("reel_preview.png")
        if FileManager.default.fileExists(atPath: expected.path) {
            thursdayEditorURL = expected
            return
        }
        isBuildingThursdayEditor = true
        Task {
            let built = try? await PythonBridge.shared.runBuildReelPreview(event: live)
            await MainActor.run {
                thursdayEditorURL = built
                isBuildingThursdayEditor = false
            }
        }
    }

    private func swapReelAudio(day: DayName) {
        // Clear any uploaded audio so regeneration fetches fresh Jamendo
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
        pd.audioPath = nil
        ev.days[day.rawValue] = pd
        appState.updateEvent(ev)

        regeneratingDays.insert(day)
        regenerateError = nil
        Task {
            do {
                _ = try await PythonBridge.shared.runSwapReelAudio(event: liveEvent, day: day)
                await MainActor.run {
                    // Bump the version so SwiftUI rebuilds AVPlayer with the updated file.
                    graphicVersions[day] = (graphicVersions[day] ?? 0) + 1
                    regeneratingDays.remove(day)
                    NotificationService.shared.notifyRegenerationComplete(
                        eventName: liveEvent.name,
                        what: "\(day.displayName) audio"
                    )
                }
            } catch {
                await MainActor.run {
                    regeneratingDays.remove(day)
                    regenerateError = "\(day.displayName) audio swap failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Set the Thursday scroll reel length and re-render it. The number of
    /// frames depends on `scrollDuration`, so a full regenerate is required
    /// (regenerateGraphic reads the updated value from the live event).
    private func changeReelLength(day: DayName, to seconds: Double) {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
        guard pd.scrollDuration != seconds else { return }
        pd.scrollDuration = seconds
        ev.days[day.rawValue] = pd
        appState.updateEvent(ev)
        regenerateGraphic(day: day)
    }

    private func uploadReelAudio(day: DayName, url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        // Copy to a stable location: this path is persisted on the event and
        // reused by later regenerations, so it cannot live in the temp
        // directory (macOS purges it). Fail loudly if the copy fails; the
        // persisted path is only valid when the copy succeeded.
        let dir = AppPaths.audioDir
        let dest = dir.appendingPathComponent("upload_\(UUID().uuidString)_\(url.lastPathComponent)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            regenerateError = "Couldn't copy the audio file: \(error.localizedDescription)"
            return
        }

        // Persist the audio path on the event so regeneration reuses it
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
        pd.audioPath = dest
        ev.days[day.rawValue] = pd
        appState.updateEvent(ev)

        regeneratingDays.insert(day)
        regenerateError = nil
        Task {
            do {
                _ = try await PythonBridge.shared.runSwapReelAudioWithFile(
                    event: liveEvent, day: day, audioPath: dest.path
                )
                await MainActor.run {
                    graphicVersions[day] = (graphicVersions[day] ?? 0) + 1
                    regeneratingDays.remove(day)
                    NotificationService.shared.notifyRegenerationComplete(
                        eventName: liveEvent.name,
                        what: "\(day.displayName) audio"
                    )
                }
            } catch {
                await MainActor.run {
                    regeneratingDays.remove(day)
                    regenerateError = "\(day.displayName) audio upload failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func assignReelPhotosAndGenerate(raw: URL, edited: URL, bw: URL?) {
        // Save the RAW + Edited photos to the event model for Tuesday (and Friday).
        // `bw` is the optional B&W after; when set it flips both the Tuesday reel
        // and the Friday graphic into the 3-photo treatment. When nil it clears
        // any previously assigned B&W.
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        var tue = ev.days[DayName.tuesday.rawValue] ?? PostingDay(day: .tuesday)
        tue.rawPhotoPath = raw
        tue.editedPhotoPath = edited
        tue.bwPhotoPath = bw
        ev.days[DayName.tuesday.rawValue] = tue
        // Friday reuses Tuesday's RAW/Edited (and B&W) for before/after
        var fri = ev.days[DayName.friday.rawValue] ?? PostingDay(day: .friday)
        fri.rawPhotoPath = raw
        fri.editedPhotoPath = edited
        fri.bwPhotoPath = bw
        ev.days[DayName.friday.rawValue] = fri
        appState.updateEvent(ev)

        // Now generate the reel for Tuesday and the Friday before/after story
        regenerateGraphic(day: .tuesday)
        regenerateGraphic(day: .friday)
    }

    /// Add or change the optional B&W after on an already-generated before/after.
    /// Reuses the saved Tuesday RAW/Edited (which exist once the reel has been
    /// generated) and re-runs both the Tuesday reel and Friday graphic in the
    /// 3-photo treatment.
    private func changeBWPhoto() {
        guard let live = appState.events.first(where: { $0.id == event.id }),
              let tue = live.days[DayName.tuesday.rawValue],
              let raw = tue.rawPhotoPath, let edited = tue.editedPhotoPath else { return }
        let panel = NSOpenPanel()
        panel.title = "Select B&W edit"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        assignReelPhotosAndGenerate(raw: raw, edited: edited, bw: url)
    }

    /// Remove the B&W after and fall back to the classic two-photo before/after,
    /// regenerating both days.
    private func removeBWPhoto() {
        guard let live = appState.events.first(where: { $0.id == event.id }),
              let tue = live.days[DayName.tuesday.rawValue],
              let raw = tue.rawPhotoPath, let edited = tue.editedPhotoPath else { return }
        assignReelPhotosAndGenerate(raw: raw, edited: edited, bw: nil)
    }

    private func changeReelPhotos(day: DayName) {
        if day == .tuesday {
            // Step 1: Pick RAW photo
            let rawPanel = NSOpenPanel()
            rawPanel.title = "Select RAW (unedited) photo"
            rawPanel.allowedContentTypes = [.image]
            rawPanel.allowsMultipleSelection = false
            guard rawPanel.runModal() == .OK, let rawURL = rawPanel.url else { return }

            // Step 2: Pick Edited photo
            let editedPanel = NSOpenPanel()
            editedPanel.title = "Select Edited photo"
            editedPanel.allowedContentTypes = [.image]
            editedPanel.allowsMultipleSelection = false
            guard editedPanel.runModal() == .OK, let editedURL = editedPanel.url else { return }

            // Preserve any existing B&W assignment when re-picking RAW/Edited.
            let existingBW = appState.events.first(where: { $0.id == event.id })?
                .days[DayName.tuesday.rawValue]?.bwPhotoPath
            assignReelPhotosAndGenerate(raw: rawURL, edited: editedURL, bw: existingBW)
        } else {
            // Thursday: multi-select
            let panel = NSOpenPanel()
            panel.title = "Select photos for Thursday reel"
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

            print("[PostRoll:changeReelPhotos] NSOpenPanel returned \(panel.urls.count) files:")
            for (i, url) in panel.urls.enumerated() {
                print("  [\(i)] \(url.lastPathComponent)")
            }
            var ev = appState.events.first(where: { $0.id == event.id }) ?? event
            var thu = ev.days[DayName.thursday.rawValue] ?? PostingDay(day: .thursday)
            thu.photoPaths = panel.urls.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
            print("[PostRoll:changeReelPhotos] After sort, \(thu.photoPaths.count) photos:")
            for (i, url) in thu.photoPaths.enumerated() {
                print("  [\(i)] \(url.lastPathComponent)")
            }
            ev.days[DayName.thursday.rawValue] = thu
            appState.updateEvent(ev)
            regenerateGraphic(day: .thursday)
        }
    }

    /// Multi-select clip picker for Friday's auto-cut reel (#135). Every picked
    /// URL is routed through AppPaths.storedClip so a raw ~/Downloads/~/Desktop
    /// path never reaches PostingDay.clipPaths, per the standing TCC rule.
    private func importFridayClips() {
        let panel = NSOpenPanel()
        panel.title = "Select video clips for the Friday reel"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let copied = panel.urls.map { AppPaths.storedClip($0) }

        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        let fri = ev.days[DayName.friday.rawValue] ?? PostingDay(day: .friday)
        ev.days[DayName.friday.rawValue] = fri.addingClips(copied)
        appState.updateEvent(ev)

        regenerateGraphic(day: .friday)
    }

    /// Reorder/include-exclude edit to the Friday clip selection (#135).
    /// Writes only to fridayClipOverride and re-renders locally via
    /// render_friday_override.py - never re-invokes Claude
    /// (feedback_collage_edits_no_python_regen).
    private func applyFridayOverride(_ override: [ReelClipOverride]) {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.days[DayName.friday.rawValue]?.fridayClipOverride = override
        appState.updateEvent(ev)

        regeneratingDays.insert(.friday)
        regenerationStartTimes[.friday] = Date()
        regenerateError = nil
        Task {
            do {
                let liveEvent = appState.events.first(where: { $0.id == event.id }) ?? ev
                let reelPath = try await PythonBridge.shared.runRenderFridayOverride(event: liveEvent)
                await MainActor.run {
                    regeneratingDays.remove(.friday)
                    regenerationStartTimes[.friday] = nil
                    guard let reelPath else {
                        regenerateError = "Friday reel edit couldn't be applied: no reel to update"
                        return
                    }
                    var current = appState.events.first(where: { $0.id == event.id }) ?? liveEvent
                    var paths = current.previewMediaPaths[DayName.friday.rawValue] ?? [:]
                    paths["reel"] = reelPath
                    current.previewMediaPaths[DayName.friday.rawValue] = paths
                    appState.updateEvent(current)
                    graphicVersions[.friday] = (graphicVersions[.friday] ?? 0) + 1
                }
            } catch {
                await MainActor.run {
                    regeneratingDays.remove(.friday)
                    regenerationStartTimes[.friday] = nil
                    regenerateError = "Friday reel edit failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Replace one clip in the Friday override with a freshly picked file.
    private func swapFridayClip(_ oldClipPath: String) {
        let panel = NSOpenPanel()
        panel.title = "Select a replacement video clip"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        let newPath = AppPaths.storedClip(picked).path

        let live = appState.events.first(where: { $0.id == event.id }) ?? event
        guard let fri = live.days[DayName.friday.rawValue] else { return }
        var override = fri.effectiveFridayOverride
        guard let index = override.firstIndex(where: { $0.clipPath == oldClipPath }) else { return }
        override[index].clipPath = newPath
        applyFridayOverride(override)
    }

    /// Clear the manual override and re-run the full AI pipeline
    /// (Stage 1 scoring + Stage 2 Claude selection + render).
    private func recutFridayWithAI() {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.days[DayName.friday.rawValue]?.fridayClipOverride = nil
        appState.updateEvent(ev)
        regenerateGraphic(day: .friday)
    }

    /// Escape hatch for the "< 3 usable clips" error banner: drop the
    /// imported clips so future regens don't retry the clip pipeline, and
    /// dismiss the error. Friday falls back to its existing before/after
    /// story path exactly as it did before clips were ever imported.
    private func skipFridayClipsKeepStoryOnly() {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        if let fri = ev.days[DayName.friday.rawValue] {
            ev.days[DayName.friday.rawValue] = fri.clearingFridayClips()
        }
        appState.updateEvent(ev)
        regenerateError = nil
    }

    /// Replace the entire Wednesday collage photo set from the review screen.
    /// Picks a fresh batch, discards layout/crop state tied to the old photos,
    /// then regenerates the collage. Mirrors `changeReelPhotos` for Thursday.
    private func changeCollagePhotos(day: DayName) {
        // The collage targets the preset's photo count, but the generator adapts
        // to fewer (down to a 2-photo grid), so only block below that floor and
        // surface the target as guidance rather than a hard requirement (#63).
        let target = CollagePhotoSelection.target(preset: liveEvent.effectivePostingPreset, day: day)
        let panel = NSOpenPanel()
        panel.title = "Select photos for the \(day.displayName) collage (about \(target))"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        if let message = CollagePhotoSelection.validationError(
            selectedCount: panel.urls.count, dayDisplayName: day.displayName
        ) {
            regenerateError = message
            return
        }

        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
        pd.photoPaths = panel.urls.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending
        }
        // Crop offsets and the cell layout are keyed to the old photo paths, so
        // discard them for a clean rebuild from the new set.
        pd.collageCropOffsets = [:]
        pd.collageCellOverride = nil
        ev.days[day.rawValue] = pd
        appState.updateEvent(ev)

        // Keep the in-memory editor state in sync so the live overlay doesn't
        // reference photos that no longer exist.
        dayCollageCropOffsets[day.rawValue] = [:]
        dayCollageCellOverrides.removeValue(forKey: day.rawValue)

        regenerateGraphic(day: day)
    }

    /// Apply a layout chosen from the gallery: store its seed as the day's
    /// collage seed, drop any per-cell override (tied to the old layout), and
    /// regenerate. `regenerateGraphic` keeps a non-nil seed when newLayout is
    /// false, so the rendered collage reproduces the picked layout.
    private func applyCollageLayout(day: DayName, seed: Int) {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
        pd.collageSeed = seed
        pd.collageCellOverride = nil
        ev.days[day.rawValue] = pd
        appState.updateEvent(ev)
        dayCollageCellOverrides.removeValue(forKey: day.rawValue)
        regenerateGraphic(day: day)
    }

    /// Swap two photos in a day's photoPaths. Persists the new order but
    /// does NOT trigger regen — the user batches swaps with crop / resize
    /// edits and bakes them all in one shot via "Apply changes".
    private func swapReelPhotos(day: DayName, a: URL, b: URL) {
        guard a.path != b.path else { return }
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        guard var pd = ev.days[day.rawValue] else { return }
        // Compare by .path (decoded, normalized) — URL `==` uses absoluteString
        // which can differ between URLs built from Python's plain-string layout
        // JSON and URLs decoded from events.json's stored absoluteString.
        guard let i = pd.photoPaths.firstIndex(where: { $0.path == a.path }),
              let j = pd.photoPaths.firstIndex(where: { $0.path == b.path }),
              i != j else { return }
        pd.photoPaths.swapAt(i, j)
        ev.days[day.rawValue] = pd
        appState.updateEvent(ev)
        // Pre-render the swapped order in the background ahead of "Apply changes".
        if day == .thursday { speculativeReel.schedule(for: liveEvent) }
    }

    private func regenerateGraphic(day: DayName, newLayout: Bool = false) {
        // Always read the CURRENT event from AppState — not self.event.
        // self.event is captured by value in the closure that calls this function and
        // may be stale (pre-save snapshot). appState is a reference type so .events
        // always reflects the latest write from save().
        guard let live = appState.events.first(where: { $0.id == event.id }) else { return }
        var eventSnapshot = live

        // For a collage day, lock the collage seed before the first regen so
        // Python always produces the same grid layout when only crop offsets
        // change. When `newLayout` is true, force a fresh seed regardless.
        if isCollageDay(day),
           newLayout || eventSnapshot.days[day.rawValue]?.collageSeed == nil {
            var pd = eventSnapshot.days[day.rawValue] ?? PostingDay(day: day)
            pd.collageSeed = Int.random(in: 1...999_999_999)
            // Drop any per-cell overrides — they're keyed to the previous layout.
            pd.collageCellOverride = nil
            eventSnapshot.days[day.rawValue] = pd
            appState.updateEvent(eventSnapshot)
        }
        if day == .thursday, newLayout {
            var pd = eventSnapshot.days[DayName.thursday.rawValue] ?? PostingDay(day: .thursday)
            pd.reelSeed = Int.random(in: 1...999_999_999)
            eventSnapshot.days[DayName.thursday.rawValue] = pd
            appState.updateEvent(eventSnapshot)
        }

        regeneratingDays.insert(day)
        regenerationStartTimes[day] = Date()
        regenerateError = nil
        Task {
            // For Thursday, try to adopt a speculative pre-render that was kicked
            // off when the user edited. `newLayout` randomizes the seed, so there's
            // nothing pre-rendered to match — skip straight to a fresh encode.
            if day == .thursday, !newLayout,
               let result = await speculativeReel.take(matching: eventSnapshot) {
                await MainActor.run {
                    regeneratingDays.remove(day)
                    regenerationStartTimes[day] = nil
                    applyRegenResult(result, day: day)
                }
                return
            }
            // No usable pre-render: make sure no stale speculative encode is still
            // writing the same output file before we start a fresh one.
            if day == .thursday { speculativeReel.cancelAll() }

            // Capture the result so we can distinguish "Python crashed" from
            // "Python exited 0 but reported a per-day error". Both used to be
            // swallowed by `try?`, which fired the success notification while
            // the mockup silently kept showing the old MP4.
            let outcome: Result<PythonBridge.PreviewGenerationResult, Error>
            do {
                let result = try await PythonBridge.shared.runPreviewGeneration(
                    event: eventSnapshot, days: [day.rawValue]
                )
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }

            await MainActor.run {
                regeneratingDays.remove(day)
                regenerationStartTimes[day] = nil
                switch outcome {
                case .failure(let error):
                    regenerateError = "\(day.displayName) regeneration failed: \(error.localizedDescription)"
                case .success(let result):
                    applyRegenResult(result, day: day)
                }
            }
        }
    }

    /// Land a finished (or adopted) reel render onto the live event: swap in the
    /// new media paths, bump the version so AVPlayer reloads, and notify.
    @MainActor
    private func applyRegenResult(_ result: PythonBridge.PreviewGenerationResult, day: DayName) {
        if let pyError = result.errors[day.rawValue] {
            regenerateError = "\(day.displayName) regeneration failed: \(pyError)"
        } else if let dayPaths = result.paths[day.rawValue], !dayPaths.isEmpty {
            // Read the CURRENT event — not self.event which may be stale
            // (e.g. after assignReelPhotosAndGenerate saved new photos).
            var ev = appState.events.first(where: { $0.id == event.id }) ?? event
            ev.previewMediaPaths[day.rawValue] = dayPaths
            if day == .friday { ev.applyFridayClipPlan(result.fridayClipPlan) }
            ev.applyCoverPick(result.coverPicks[day.rawValue], forDay: day.rawValue)
            appState.updateEvent(ev)
            graphicVersions[day] = (graphicVersions[day] ?? 0) + 1
            NotificationService.shared.notifyRegenerationComplete(
                eventName: event.name,
                what: day.displayName
            )
        } else {
            regenerateError = "\(day.displayName) regeneration produced no output"
        }
    }

    /// Regenerate (or manually override) just the day's cover image (#141).
    /// Deliberately does NOT call regenerateGraphic: that would force a full
    /// reel/story regen (for Friday specifically, a real Stage 1/2 recut +
    /// ffmpeg render) just to refresh one thumbnail. Routes to
    /// PythonBridge.runCoverRegeneration instead, the cheap cover-only path.
    private func regenerateCover(day: DayName, overrideSource: URL? = nil) {
        guard let live = appState.events.first(where: { $0.id == event.id }) else { return }
        coverRegeneratingDays.insert(day)
        coverRegenerationStartTimes[day] = Date()
        Task {
            let outcome: Result<PythonBridge.CoverRegenerationResult, Error>
            do {
                let result = try await PythonBridge.shared.runCoverRegeneration(
                    event: live, day: day, overrideSource: overrideSource
                )
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }

            await MainActor.run {
                coverRegeneratingDays.remove(day)
                coverRegenerationStartTimes[day] = nil
                switch outcome {
                case .failure(let error):
                    regenerateError = "\(day.displayName) cover regeneration failed: \(error.localizedDescription)"
                case .success(let result):
                    var ev = appState.events.first(where: { $0.id == event.id }) ?? event
                    ev.previewMediaPaths[day.rawValue, default: [:]]["cover"] = result.coverPath
                    if let pick = result.coverPick {
                        ev.applyCoverPick(pick, forDay: day.rawValue)
                    } else if let overrideSource {
                        ev.days[day.rawValue]?.coverOverride = overrideSource.path
                    }
                    appState.updateEvent(ev)
                    graphicVersions[day] = (graphicVersions[day] ?? 0) + 1
                }
            }
        }
    }

    // MARK: - Caption revision

    private func reviseCaption(day: DayName, feedback: String) async throws {
        guard let current = result[day] else { return }
        let revised = try await PythonBridge.shared.runCaptionRevision(
            event: liveEvent,
            day: day,
            feedback: feedback,
            currentCaption: current
        )
        result[day] = revised
        save()
    }

    private func reviseBlog(feedback: String) async throws {
        guard let current = result.blog else { return }
        let revised = try await PythonBridge.shared.runBlogRevision(
            event: liveEvent,
            feedback: feedback,
            currentBlog: current
        )
        result.blog = revised
        save()
    }

    private func swapBlogPhotos(urls: [URL]) async throws {
        guard let current = result.blog else { return }
        let updated = try await PythonBridge.shared.runBlogPhotoSwap(
            currentBody: current.body,
            photoPaths: urls
        )
        var updatedBlog = current
        updatedBlog.body = updated.body
        updatedBlog.photoCount = urls.count
        result.blog = updatedBlog
        save()
        // blogPhotoPaths lives outside weekResult — re-read live event so
        // this write lands on top of what save() just persisted.
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.blogPhotoPaths = urls
        appState.updateEvent(ev)
    }

    // MARK: - Persistence

    private func save() {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.weekResult = result
        DayStateMerger.mergeLocalStateIntoDays(
            &ev,
            collageCropOffsets: dayCollageCropOffsets,
            reelCropOffsets: dayReelCropOffsets,
            collageCellOverrides: dayCollageCellOverrides,
            fridayClipOverride: dayFridayClipOverride
        )
        appState.updateEvent(ev)
    }

    private func advance() {
        save()
        let hasEdits = DayName.allCases.contains { result[$0]?.wasEdited == true }
        guard hasEdits else {
            finalizeAdvance()
            return
        }
        isAnalyzingEdits = true
        Task {
            let suggestion = try? await PythonBridge.shared.runLearnFromEdits(result: result)
            await MainActor.run {
                isAnalyzingEdits = false
                if let s = suggestion, !s.isEmpty {
                    learningSuggestion = s
                    showLearnSheet = true
                } else {
                    finalizeAdvance()
                }
            }
        }
    }

    private func finalizeAdvance() {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.weekResult = result
        DayStateMerger.mergeLocalStateIntoDays(
            &ev,
            collageCropOffsets: dayCollageCropOffsets,
            reelCropOffsets: dayReelCropOffsets,
            collageCellOverrides: dayCollageCellOverrides,
            fridayClipOverride: dayFridayClipOverride
        )
        // Approving captions only opens the Export screen; the export itself
        // (and the archivedAt / exportPath stamps that mark real completion)
        // happens once the user picks a folder and runs it in ExportView.
        ev.stage = .exported
        appState.updateEvent(ev)
    }
}

// MARK: - Caption Section

private struct CaptionSection: View {
    let day: DayName
    let postingDay: PostingDay?
    var previewPaths: [String: String]? = nil
    @Binding var caption: DayCaption
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRevise: (String) async throws -> Void
    var onPreview: ((URL) -> Void)? = nil
    var isRegeneratingGraphic: Bool = false
    var graphicVersion: Int = 0
    var onRegenerateGraphic: (() -> Void)? = nil
    /// Re-roll the layout seed and regenerate (Wednesday collage / Thursday reel).
    var onNewLayout: (() -> Void)? = nil
    var onSwapReelAudio: (() -> Void)? = nil
    var onUploadReelAudio: (() -> Void)? = nil
    /// Current Thursday reel length (scroll seconds) and the change handler.
    var reelLength: Double? = nil
    var onChangeReelLength: ((Double) -> Void)? = nil
    var onChangeReelPhotos: (() -> Void)? = nil
    /// Open the multi-select clip picker for Friday's auto-cut reel (#135).
    var onImportFridayClips: (() -> Void)? = nil
    /// Called with the full edited list whenever reorder/include-exclude
    /// changes in the Friday manual override editor (#135). Never re-invokes
    /// Claude: writes fridayClipOverride and re-renders locally.
    var onApplyFridayOverride: (([ReelClipOverride]) -> Void)? = nil
    /// Swap one clip in the Friday override for a freshly picked file.
    var onSwapFridayClip: ((String) -> Void)? = nil
    /// Clear fridayClipOverride and re-run the full AI pipeline (Stage 1 + 2).
    var onRecutFridayWithAI: (() -> Void)? = nil
    /// When Friday's current pipeline run (import/regen/override-apply)
    /// started, so the elapsed-timer status view can show real progress
    /// instead of a bare spinner. nil when nothing is running.
    var fridayRegenStartedAt: Date? = nil
    /// The parent's regenerateError, passed down so Friday's card can show
    /// the fail-loud "< 3 usable clips" banner with its two escape hatches
    /// instead of relying on the generic top-of-screen error text (#135).
    var fridayRegenerateError: String? = nil
    /// "Skip clips, keep story-only": clears clipPaths so future regens
    /// don't retry the clip pipeline, and dismisses the error.
    var onSkipFridayClips: (() -> Void)? = nil
    /// Replace the whole Wednesday collage photo set (review-screen action).
    var onChangeCollagePhotos: (() -> Void)? = nil
    /// Open the collage layout gallery to pick a layout (collage days only).
    var onChooseLayout: (() -> Void)? = nil
    var onSwapReelPhotos: ((URL, URL) -> Void)? = nil
    /// Called when the user assigns RAW + Edited photos inline (review screen fallback).
    var onAssignReelPhotos: ((URL, URL, URL?) -> Void)? = nil
    /// Inline photo picker callbacks (hoisted to parent for fileImporter presentation)
    var onPickInlineRaw: (() -> Void)? = nil
    var onPickInlineEdited: (() -> Void)? = nil
    var onPickInlineBW: (() -> Void)? = nil
    var onClearInlineBW: (() -> Void)? = nil
    /// Add/change/remove the optional B&W on an already-generated before/after.
    var onChangeBW: (() -> Void)? = nil
    var onRemoveBW: (() -> Void)? = nil
    var inlineRawPhoto: URL? = nil
    var inlineEditedPhoto: URL? = nil
    var inlineBWPhoto: URL? = nil
    var collageCropOffsets: Binding<[String: CropOffset]>? = nil
    var collageCellOverride: Binding<[CollageCell]?>? = nil
    var reelCropOffsets: Binding<[String: CropOffset]>? = nil
    var thursdayEditorURL: URL? = nil
    var isBuildingThursdayEditor: Bool = false
    /// Cover image (Thursday scroll reel + Friday auto-cut clip reel, #141).
    var isCoverRegenerating: Bool = false
    var coverRegenStartedAt: Date? = nil
    var onRegenerateCover: (() -> Void)? = nil
    /// Manual "choose a different photo/frame" escape hatch: writes
    /// coverOverride directly, never re-invokes Claude (same discipline as
    /// every other manual override in this app).
    var onChooseCoverOverride: (() -> Void)? = nil

    @State private var showingRevision = false
    @State private var feedbackText = ""
    @State private var saveToBrandVoice = false
    @State private var isRevising = false
    @State private var revisionError: String?
    @State private var undoCaption: DayCaption? = nil
    @State private var mockupWidth: CGFloat = 480

    // Tuesday reel card: size the reel so that when the day is expanded, the
    // adjacent day (Wednesday) is visible below but Thursday/Friday are not.
    // Formula: 82% of screen height minus mockup chrome (~200pt overhead).
    private var tuesdayReelCardWidth: CGFloat {
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        let reelH = max(240, screenH * 0.82 - 200)
        return reelH * 9.0 / 16.0
    }

    // Shared minimum height for all expanded day cards so that adjacent days
    // are visible without scrolling. Matches Tuesday's total mockup height.
    private var expandedCardMinHeight: CGFloat {
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        return max(440, screenH * 0.82)
    }

    // All non-Tuesday days share the same expanded height budget so the left
    // column (mockup + caption editing controls) fits without scrolling.
    // Tuned so the next day's header still peeks below on a ~800pt screen.
    private var storyExpandedMaxHeight: CGFloat {
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        return max(520, screenH * 0.84)
    }

    // Cap the Instagram mockup width on story days so a landscape photo
    // doesn't force the left column to dominate the expanded card height.
    private var storyMockupMaxWidth: CGFloat {
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        return max(300, screenH * 0.40)
    }

    // Split layout: non-Wednesday days that have a generated story/reel graphic.
    // On those days the preview goes left, captions go right.
    private var splitPreviewURL: URL? {
        guard let paths = previewPaths else { return nil }
        // Wednesday uses the collage as its right-column preview
        if day == .wednesday {
            if let p = paths["collage"], FileManager.default.fileExists(atPath: p) {
                return URL(fileURLWithPath: p)
            }
            return nil
        }
        // Tuesday only needs its reel — the before/after story is covered on Friday.
        // Sunday/Monday carry a "collage" key under the balanced preset (their
        // collage doubles as the story); a "story" key under classic.
        let keys: [String] = day == .tuesday
            ? ["reel"]
            : ["collage", "reel", "before_after", "story_cover", "story"]
        for key in keys {
            if let p = paths[key], FileManager.default.fileExists(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    /// A day whose feed is a carousel + collage story (Wednesday always; Sunday
    /// and Monday under the balanced preset). Detected by the "collage" asset
    /// key so the view stays preset-agnostic.
    private var isCollageCarouselDay: Bool { previewPaths?["collage"] != nil }

    /// The rendered cover.png, only when it's still on disk (a stale path
    /// surviving after the file was reclaimed/deleted must not show a
    /// broken image, same guard FridayReviewDisplay.showsDualSlot uses).
    private var coverURL: URL? {
        let path = previewPaths?["cover"]
        guard CoverReviewDisplay.showsCover(coverPath: path, fileExists: FileManager.default.fileExists(atPath:)) else {
            return nil
        }
        return path.map { URL(fileURLWithPath: $0) }
    }

    /// nil once a manual override is in effect (no AI rationale for the
    /// user's own pick), otherwise the AI's one-line rationale when it has one.
    private var coverRationale: String? {
        CoverReviewDisplay.rationale(coverOverride: postingDay?.coverOverride, coverPick: postingDay?.coverPick)
    }

    private var splitPreviewIsReel: Bool {
        guard let paths = previewPaths, let reelP = paths["reel"] else { return false }
        return splitPreviewURL == URL(fileURLWithPath: reelP)
    }

    /// Path to the Thursday reel's still-preview PNG — written next to the MP4.
    /// Used by the per-cell crop editor so the user can pan/zoom without re-encoding.
    private var thursdayReelPreviewURL: URL? {
        guard day == .thursday, let reelStr = previewPaths?["reel"] else { return nil }
        return URL(fileURLWithPath: reelStr)
            .deletingLastPathComponent()
            .appendingPathComponent("reel_preview.png")
    }

    private var thursdayReelLayoutURL: URL? {
        thursdayReelPreviewURL?
            .deletingLastPathComponent()
            .appendingPathComponent("reel_preview_layout.json")
    }

    private var splitPreviewIsCollage: Bool { isCollageCarouselDay }

    private var splitPreviewLabel: String {
        if day == .wednesday { return "COLLAGE" }
        guard let paths = previewPaths else { return "PREVIEW" }
        if paths["reel"] != nil && splitPreviewIsReel { return "REEL" }
        if paths["before_after"] != nil { return "BEFORE / AFTER" }
        if paths["story_cover"] != nil { return "STORY COVER" }
        if paths["collage"] != nil { return "COLLAGE" }
        return "STORY"
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    Text(day.displayName.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)

                    if day == .friday {
                        Text("Story only")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    } else if !caption.caption.isEmpty {
                        Text(String(caption.caption.prefix(40)) + (caption.caption.count > 40 ? "…" : ""))
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                            .lineLimit(1)
                    }

                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if day == .friday,
                   FridayReviewDisplay.showsDualSlot(
                       fridayClipPlan: postingDay?.fridayClipPlan,
                       reelPath: previewPaths?["reel"],
                       fileExists: FileManager.default.fileExists(atPath:)
                   ),
                   let plan = postingDay?.fridayClipPlan,
                   let reelPath = previewPaths?["reel"] {
                    // ── Friday: dual-slot review (auto-cut reel + before/after story) (#135) ──
                    let reelURL = URL(fileURLWithPath: reelPath)
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Spacer(minLength: 0)
                                InstagramMockup(
                                    photoURL: nil,
                                    videoURL: reelURL,
                                    videoVersion: graphicVersion,
                                    dayLabel: day.displayName,
                                    caption: caption.caption,
                                    hashtags: caption.hashtags,
                                    cardWidth: tuesdayReelCardWidth,
                                    isReelDay: true,
                                    onRegenerate: onRegenerateGraphic,
                                    onReviseCaption: { showingRevision = true },
                                    onChangePhotos: onImportFridayClips,
                                    isRegenerating: isRegeneratingGraphic
                                )
                                .id("friday-reel-\(graphicVersion)")
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 16)

                            if !plan.rationale.isEmpty {
                                Text(plan.rationale)
                                    .font(.light(11))
                                    .italic()
                                    .foregroundStyle(Color.warmMid)
                                    .frame(maxWidth: tuesdayReelCardWidth, alignment: .leading)
                                    .padding(.top, Spacing.sm)
                            }

                            // Story slot: same before/after asset Friday already
                            // produces today, relabeled as the Story post here
                            // alongside the Feed Post reel.
                            if let storyPath = previewPaths?["before_after"],
                               FileManager.default.fileExists(atPath: storyPath) {
                                let storyURL = URL(fileURLWithPath: storyPath)
                                Text("STORY")
                                    .font(.system(size: 9, weight: .medium))
                                    .tracking(0.8)
                                    .foregroundStyle(Color.warmMid.opacity(0.55))
                                    .frame(maxWidth: tuesdayReelCardWidth, alignment: .leading)
                                    .padding(.top, Spacing.md)
                                PreviewGraphicThumbnail(
                                    url: storyURL,
                                    onPreview: { onPreview?(storyURL) },
                                    isRegenerating: false,
                                    maxHeight: 160
                                )
                                .frame(maxWidth: tuesdayReelCardWidth)
                            }

                            if let coverURL {
                                CoverSlotView(
                                    coverURL: coverURL,
                                    rationale: coverRationale,
                                    isRegenerating: isCoverRegenerating,
                                    regenStartedAt: coverRegenStartedAt,
                                    onPreview: { onPreview?(coverURL) },
                                    onRegenerate: onRegenerateCover,
                                    onChooseOverride: onChooseCoverOverride,
                                    maxHeight: 160
                                )
                                .frame(maxWidth: tuesdayReelCardWidth, alignment: .leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Divider()

                        VStack(alignment: .leading, spacing: 0) {
                            Spacer(minLength: 0)
                            VStack(alignment: .leading, spacing: Spacing.md) {
                                ReviewTextArea(label: "Caption", text: $caption.caption, minHeight: 60)
                                    .frame(maxHeight: 120)
                                HashtagsEditor(hashtags: $caption.hashtags)

                                FridayClipEditor(
                                    entries: postingDay?.effectiveFridayOverride ?? [],
                                    hasOverride: postingDay?.fridayClipOverride != nil,
                                    onApply: onApplyFridayOverride,
                                    onSwap: onSwapFridayClip,
                                    onRecutWithAI: onRecutFridayWithAI
                                )
                                if fridayRegenStartedAt != nil {
                                    PipelineStatusView(startedAt: fridayRegenStartedAt)
                                }

                                if showingRevision {
                                    RevisionPanel(
                                        feedbackText: $feedbackText,
                                        saveToBrandVoice: $saveToBrandVoice,
                                        isRevising: isRevising,
                                        error: revisionError,
                                        onApply: { applyRevision() },
                                        onCancel: {
                                            showingRevision = false
                                            feedbackText = ""
                                            saveToBrandVoice = false
                                            revisionError = nil
                                        }
                                    )
                                } else {
                                    Button("Revise with feedback…") { showingRevision = true }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.roseGold)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.bottom, Spacing.md)

                } else if day == .friday {
                    // ── Friday: story image only — no caption/hashtags/revise ──
                    if let previewURL = splitPreviewURL {
                        VStack(spacing: 0) {
                            Text(splitPreviewLabel)
                                .font(.system(size: 9, weight: .medium))
                                .tracking(0.8)
                                .foregroundStyle(Color.warmMid.opacity(0.55))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.md)
                                .padding(.top, Spacing.sm)

                            PreviewGraphicThumbnail(
                                url: previewURL,
                                onPreview: { onPreview?(previewURL) },
                                isRegenerating: isRegeneratingGraphic,
                                onRegenerate: onRegenerateGraphic,
                                maxHeight: storyExpandedMaxHeight - 60
                            )
                            .id("\(previewURL.path)-\(graphicVersion)")
                            .padding(Spacing.md)

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: storyExpandedMaxHeight)
                        .background(Color(red: 0.10, green: 0.09, blue: 0.08))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.md)
                    } else {
                        Text("Friday story will appear here once generated.")
                            .font(.light(12))
                            .foregroundStyle(Color.warmMid)
                            .padding(.horizontal, Spacing.xl)
                            .padding(.vertical, Spacing.md)
                    }

                    if let onImportFridayClips {
                        Button(action: onImportFridayClips) {
                            Label("Import Clips…", systemImage: "film")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.roseGold)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.xs)
                    }
                    if fridayRegenStartedAt != nil {
                        PipelineStatusView(startedAt: fridayRegenStartedAt)
                            .padding(.horizontal, Spacing.xl)
                            .padding(.bottom, Spacing.md)
                    }
                    if let err = fridayRegenerateError, FridayReviewDisplay.isInsufficientClipsError(err) {
                        BrandBanner(
                            icon: "exclamationmark.triangle",
                            message: "Not enough usable clips for an auto-cut reel. Import more, or skip clips and keep the story-only post.",
                            style: .error,
                            actions: [
                                BrandBannerAction(label: "Import more clips", action: { onImportFridayClips?() }),
                                BrandBannerAction(label: "Skip clips, keep story-only", action: { onSkipFridayClips?() }),
                            ]
                        )
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.md)
                    }

                } else if day == .tuesday, let reelURL = splitPreviewURL {
                    // ── Tuesday: Instagram mockup (reel inside) left, controls right
                    HStack(alignment: .top, spacing: 0) {

                        // Left: mockup centred in its column; reel fills card at 9:16
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Spacer(minLength: 0)
                                InstagramMockup(
                                    photoURL: nil,
                                    videoURL: reelURL,
                                    videoVersion: graphicVersion,
                                    dayLabel: day.displayName,
                                    caption: caption.caption,
                                    hashtags: caption.hashtags,
                                    cardWidth: tuesdayReelCardWidth,
                                    isReelDay: true,
                                    onRegenerate: onRegenerateGraphic,
                                    onReviseCaption: { showingRevision = true },
                                    onSwapAudio: onSwapReelAudio,
                                    onUploadAudio: onUploadReelAudio,
                                    onChangePhotos: onChangeReelPhotos,
                                    onChangeBW: onChangeBW,
                                    onRemoveBW: onRemoveBW,
                                    hasBW: postingDay?.bwPhotoPath != nil,
                                    isRegenerating: isRegeneratingGraphic
                                )
                                .id("tuesday-reel-\(graphicVersion)")
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 16)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Divider()

                        // Right: caption editing controls, vertically centered
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer(minLength: 0)
                            VStack(alignment: .leading, spacing: Spacing.md) {
                                ReviewTextArea(label: "Caption", text: $caption.caption, minHeight: 60)
                                    .frame(maxHeight: 120)

                                HStack(spacing: Spacing.sm) {
                                    Spacer()
                                    Text("\(caption.caption.count) chars")
                                        .font(.system(size: 10))
                                        .foregroundStyle(caption.caption.count > 2200 ? Color.roseDeep : Color.warmMid)
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(caption.caption, forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.warmMid)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy caption")
                                }

                                HashtagsEditor(hashtags: $caption.hashtags)

                                if !caption.altTexts.isEmpty {
                                    AltTextsSection(altTexts: $caption.altTexts)
                                }

                                if showingRevision {
                                    RevisionPanel(
                                        feedbackText: $feedbackText,
                                        saveToBrandVoice: $saveToBrandVoice,
                                        isRevising: isRevising,
                                        error: revisionError,
                                        onApply: { applyRevision() },
                                        onCancel: {
                                            showingRevision = false
                                            feedbackText = ""
                                            saveToBrandVoice = false
                                            revisionError = nil
                                        }
                                    )
                                } else {
                                    HStack(spacing: Spacing.md) {
                                        Button("Revise with feedback…") { showingRevision = true }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.roseGold)
                                        if undoCaption != nil {
                                            Button("Restore previous") {
                                                caption = undoCaption!
                                                undoCaption = nil
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.warmMid)
                                        }
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.bottom, Spacing.md)

                } else if splitPreviewURL != nil {
                    // ── Split layout: captions left, preview right ───────────────
                    HStack(alignment: .top, spacing: 0) {

                        // Left: Instagram mockup + caption editing controls
                        // Wrapped in ScrollView so the fixed-size mockup + controls
                        // can't force the whole card taller than the screen budget.
                        ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Spacer(minLength: 0)
                                InstagramMockup(
                                    photoURL: postingDay?.photoPaths.first,
                                    photoURLs: (day == .wednesday || isCollageCarouselDay) ? (postingDay?.photoPaths ?? []) : [],
                                    videoURL: day == .thursday ? previewPaths?["reel"].flatMap({ URL(fileURLWithPath: $0) }) : nil,
                                    videoVersion: graphicVersion,
                                    dayLabel: day.displayName,
                                    caption: caption.caption,
                                    hashtags: caption.hashtags,
                                    cardWidth: mockupWidth,
                                    isReelDay: day == .thursday,
                                    onRegenerate: onRegenerateGraphic,
                                    onReviseCaption: { showingRevision = true },
                                    onNewLayout: (isCollageCarouselDay || day == .thursday) ? onNewLayout : nil,
                                    onSwapAudio: day == .thursday ? onSwapReelAudio : nil,
                                    onUploadAudio: day == .thursday ? onUploadReelAudio : nil,
                                    onChangePhotos: day == .thursday ? onChangeReelPhotos : (isCollageCarouselDay ? onChangeCollagePhotos : nil),
                                    currentReelLength: day == .thursday ? reelLength : nil,
                                    onChangeReelLength: day == .thursday ? onChangeReelLength : nil,
                                    isRegenerating: isRegeneratingGraphic
                                )
                                .id("\(day.rawValue)-mockup-\(graphicVersion)")
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Spacing.xl)
                            .padding(.top, 16)

                            // Editing controls below the mockup
                            VStack(alignment: .leading, spacing: Spacing.md) {
                            ReviewTextArea(label: "Caption", text: $caption.caption, minHeight: 60)

                            HStack(spacing: Spacing.sm) {
                                Spacer()
                                Text("\(caption.caption.count) chars")
                                    .font(.system(size: 10))
                                    .foregroundStyle(caption.caption.count > 2200 ? Color.roseDeep : Color.warmMid)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(caption.caption, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.warmMid)
                                }
                                .buttonStyle(.plain)
                                .help("Copy caption")
                            }

                            HashtagsEditor(hashtags: $caption.hashtags)

                            if !caption.altTexts.isEmpty {
                                AltTextsSection(altTexts: $caption.altTexts)
                            }

                            if showingRevision {
                                RevisionPanel(
                                    feedbackText: $feedbackText,
                                    saveToBrandVoice: $saveToBrandVoice,
                                    isRevising: isRevising,
                                    error: revisionError,
                                    onApply: { applyRevision() },
                                    onCancel: {
                                        showingRevision = false
                                        feedbackText = ""
                                        saveToBrandVoice = false
                                        revisionError = nil
                                    }
                                )
                            } else {
                                HStack(spacing: Spacing.md) {
                                    Button("Revise with feedback…") { showingRevision = true }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.roseGold)
                                    if undoCaption != nil {
                                        Button("Restore previous") {
                                            caption = undoCaption!
                                            undoCaption = nil
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.warmMid)
                                    }
                                }
                            }
                        }  // inner editing-controls VStack
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.md)
                    }  // outer left column VStack
                    }  // ScrollView
                    .frame(maxWidth: .infinity, maxHeight: storyExpandedMaxHeight)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        // Mockup width = min(column width − padding, screen-proportional cap)
                        min(max(proxy.size.width - Spacing.xl * 2, 200), storyMockupMaxWidth)
                    } action: { newWidth in
                        mockupWidth = newWidth
                    }

                        Divider()

                        // Right: preview — same dark card for all days
                        if let previewURL = splitPreviewURL {
                            VStack(spacing: 0) {
                                Text(splitPreviewLabel)
                                    .font(.system(size: 9, weight: .medium))
                                    .tracking(0.8)
                                    .foregroundStyle(Color.warmMid.opacity(0.55))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.top, Spacing.sm)

                                if splitPreviewIsCollage, let offsets = collageCropOffsets {
                                    let layoutURL = previewURL.deletingLastPathComponent()
                                        .appendingPathComponent(
                                            previewURL.deletingPathExtension().lastPathComponent + "_layout.json")
                                    CollagePreviewThumbnail(
                                        url: previewURL,
                                        layoutURL: layoutURL,
                                        cropOffsets: offsets,
                                        cellOverride: collageCellOverride ?? .constant(nil),
                                        onPreview: { onPreview?(previewURL) },
                                        isRegenerating: isRegeneratingGraphic,
                                        onRegenerate: onRegenerateGraphic,
                                        onChangePhotos: onChangeCollagePhotos,
                                        photoURLs: postingDay?.photoPaths ?? []
                                    )
                                    .padding(Spacing.md)

                                    if let onChooseLayout {
                                        Button(action: onChooseLayout) {
                                            Label("Choose layout…", systemImage: "square.grid.2x2")
                                                .font(.system(size: 12, weight: .medium))
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.roseGold)
                                        .disabled(isRegeneratingGraphic)
                                        .padding(.bottom, Spacing.xs)
                                    }

                                    // Draggable photo thumbnails for swapping cells
                                    if let pd = postingDay, !pd.photoPaths.isEmpty {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 8) {
                                                ForEach(pd.photoPaths, id: \.self) { photoURL in
                                                    ReviewThumb(url: photoURL) { onPreview?(photoURL) }
                                                        .onDrag { NSItemProvider(object: photoURL.path as NSString) }
                                                }
                                            }
                                            .padding(.horizontal, Spacing.md)
                                            .padding(.vertical, 4)
                                        }
                                    }
                                } else if splitPreviewIsReel {
                                    if day == .thursday,
                                       let pngURL = thursdayEditorURL,
                                       let layoutURL = thursdayReelLayoutURL,
                                       let offsets = reelCropOffsets {
                                        ReelStripPreviewThumbnail(
                                            url: pngURL,
                                            layoutURL: layoutURL,
                                            cropOffsets: offsets,
                                            isRegenerating: isRegeneratingGraphic,
                                            onRegenerate: onRegenerateGraphic,
                                            onNewLayout: onNewLayout,
                                            onSwapAudio: onSwapReelAudio,
                                            onUploadAudio: onUploadReelAudio,
                                            onChangePhotos: onChangeReelPhotos,
                                            onSwapPhotos: onSwapReelPhotos,
                                            currentReelLength: reelLength,
                                            onChangeReelLength: onChangeReelLength,
                                            maxHeight: storyExpandedMaxHeight - 60
                                        )
                                        .id("\(pngURL.path)-\(graphicVersion)")
                                        .padding(Spacing.md)
                                    } else if day == .thursday {
                                        VStack(spacing: 10) {
                                            ProgressView().controlSize(.small).tint(.white)
                                            Text(isBuildingThursdayEditor ? "Preparing editor…" : "Loading…")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.8))
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .padding(Spacing.md)
                                    } else {
                                    ReelPreviewPlayer(
                                        url: previewURL,
                                        version: graphicVersion,
                                        onRegenerate: onRegenerateGraphic,
                                        isRegenerating: isRegeneratingGraphic
                                    )
                                    .id("\(previewURL.path)-\(graphicVersion)")
                                    .aspectRatio(9/16, contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: expandedCardMinHeight)
                                    .overlay(alignment: .topTrailing) {
                                        if onRegenerateGraphic != nil || onSwapReelAudio != nil || onUploadReelAudio != nil || onChangeReelPhotos != nil {
                                            Menu {
                                                if let onRegenerate = onRegenerateGraphic {
                                                    Button {
                                                        onRegenerate()
                                                    } label: {
                                                        Label(isRegeneratingGraphic ? "Regenerating…" : "Regenerate reel", systemImage: "arrow.clockwise")
                                                    }
                                                    .disabled(isRegeneratingGraphic)
                                                }
                                                if let onNewLayout {
                                                    Button {
                                                        onNewLayout()
                                                    } label: {
                                                        Label("New layout (re-roll)", systemImage: "shuffle")
                                                    }
                                                    .disabled(isRegeneratingGraphic)
                                                }
                                                if let onChange = onChangeReelPhotos {
                                                    Button {
                                                        onChange()
                                                    } label: {
                                                        Label("Change photos", systemImage: "photo.on.rectangle.angled")
                                                    }
                                                    .disabled(isRegeneratingGraphic)
                                                }
                                                if let onSwap = onSwapReelAudio {
                                                    Button {
                                                        onSwap()
                                                    } label: {
                                                        Label("New Jamendo audio", systemImage: "music.note")
                                                    }
                                                    .disabled(isRegeneratingGraphic)
                                                }
                                                if let onUpload = onUploadReelAudio {
                                                    Button {
                                                        onUpload()
                                                    } label: {
                                                        Label("Upload my own audio", systemImage: "square.and.arrow.down")
                                                    }
                                                    .disabled(isRegeneratingGraphic)
                                                }
                                            } label: {
                                                Image(systemName: "ellipsis")
                                                    .font(.system(size: 13, weight: .medium))
                                                    .foregroundStyle(Color.white.opacity(0.9))
                                                    .padding(8)
                                                    .background(Color.black.opacity(0.4))
                                                    .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                                            }
                                            .menuStyle(.borderlessButton)
                                            .menuIndicator(.hidden)
                                            .fixedSize()
                                            .padding(10)
                                        }
                                    }
                                    .padding(Spacing.md)
                                    }
                                } else {
                                    PreviewGraphicThumbnail(
                                        url: previewURL,
                                        onPreview: { onPreview?(previewURL) },
                                        isRegenerating: isRegeneratingGraphic,
                                        onRegenerate: onRegenerateGraphic,
                                        maxHeight: storyExpandedMaxHeight - 60
                                    )
                                    .id("\(previewURL.path)-\(graphicVersion)")
                                    .padding(Spacing.md)
                                }

                                if day == .thursday, let coverURL {
                                    CoverSlotView(
                                        coverURL: coverURL,
                                        rationale: coverRationale,
                                        isRegenerating: isCoverRegenerating,
                                        regenStartedAt: coverRegenStartedAt,
                                        onPreview: { onPreview?(coverURL) },
                                        onRegenerate: onRegenerateCover,
                                        onChooseOverride: onChooseCoverOverride,
                                        maxHeight: 160
                                    )
                                    .padding(.horizontal, Spacing.md)
                                }

                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, maxHeight: storyExpandedMaxHeight)
                            .background(Color(red: 0.10, green: 0.09, blue: 0.08))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                            .padding(.horizontal, Spacing.xl)
                            .padding(.vertical, Spacing.md)
                        }
                    }
                    .frame(maxHeight: storyExpandedMaxHeight)
                    .padding(.bottom, Spacing.md)

                } else {
                    // ── Stacked layout: days with no generated preview yet ────────
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        if day == .tuesday,
                           (postingDay?.rawPhotoPath == nil || postingDay?.editedPhotoPath == nil),
                           previewPaths?["reel"] == nil {
                            // Inline RAW/Edited upload when reel inputs are missing
                            InlineReelPhotoAssignment(
                                rawPhoto: inlineRawPhoto,
                                editedPhoto: inlineEditedPhoto,
                                bwPhoto: inlineBWPhoto,
                                isRegenerating: isRegeneratingGraphic,
                                onPickRaw: { onPickInlineRaw?() },
                                onPickEdited: { onPickInlineEdited?() },
                                onPickBW: { onPickInlineBW?() },
                                onClearBW: { onClearInlineBW?() },
                                onGenerate: {
                                    if let raw = inlineRawPhoto, let edited = inlineEditedPhoto {
                                        onAssignReelPhotos?(raw, edited, inlineBWPhoto)
                                    }
                                }
                            )
                        } else if let pd = postingDay {
                            ReviewMediaStrip(
                                day: day,
                                postingDay: pd,
                                previewPaths: previewPaths,
                                isRegenerating: isRegeneratingGraphic,
                                graphicVersion: graphicVersion,
                                onPreview: onPreview,
                                onRegenerate: onRegenerateGraphic,
                                onChangeBW: onChangeBW,
                                onRemoveBW: onRemoveBW,
                                onChangeCollagePhotos: onChangeCollagePhotos,
                                collageCropOffsets: collageCropOffsets,
                                collageCellOverride: collageCellOverride
                            )
                        }

                        ReviewTextArea(label: "Caption", text: $caption.caption, minHeight: 80)

                        HStack(spacing: Spacing.sm) {
                            Spacer()
                            Text("\(caption.caption.count) chars")
                                .font(.system(size: 10))
                                .foregroundStyle(caption.caption.count > 2200 ? Color.roseDeep : Color.warmMid)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(caption.caption, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.warmMid)
                            }
                            .buttonStyle(.plain)
                            .help("Copy caption")
                        }

                        HashtagsEditor(hashtags: $caption.hashtags)

                        if !caption.altTexts.isEmpty {
                            AltTextsSection(altTexts: $caption.altTexts)
                        }

                        if showingRevision {
                            RevisionPanel(
                                feedbackText: $feedbackText,
                                saveToBrandVoice: $saveToBrandVoice,
                                isRevising: isRevising,
                                error: revisionError,
                                onApply: { applyRevision() },
                                onCancel: {
                                    showingRevision = false
                                    feedbackText = ""
                                    saveToBrandVoice = false
                                    revisionError = nil
                                }
                            )
                        } else {
                            HStack(spacing: Spacing.md) {
                                Button("Revise with feedback…") { showingRevision = true }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.roseGold)
                                if undoCaption != nil {
                                    Button("Restore previous") {
                                        caption = undoCaption!
                                        undoCaption = nil
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.warmMid)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.md)
                }
            }

            RoseGoldDivider(opacity: 0.3)
        }
    }

    private func applyRevision() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let snapshot = caption
        isRevising = true
        revisionError = nil
        let shouldSave = saveToBrandVoice
        Task {
            do {
                try await onRevise(trimmed)
                if shouldSave {
                    try? PythonBridge.shared.appendBrandVoiceNote(trimmed)
                }
                await MainActor.run {
                    undoCaption = snapshot
                    isRevising = false
                    showingRevision = false
                    feedbackText = ""
                    saveToBrandVoice = false
                }
            } catch {
                await MainActor.run {
                    isRevising = false
                    revisionError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Revision panel

private struct RevisionPanel: View {
    @Binding var feedbackText: String
    @Binding var saveToBrandVoice: Bool
    let isRevising: Bool
    let error: String?
    let onApply: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("FEEDBACK FOR REVISION")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.roseGold)

            TextField("e.g. make it shorter, add @dciny, don't mention the scene label", text: $feedbackText)
                .focused($focused)
                .font(.system(size: 12))
                .foregroundStyle(Color.warmDark)
                .focusEffectDisabled()
                .padding(.horizontal, 8)
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
                .disabled(isRevising)
                .onAppear { focused = true }

            Toggle(isOn: $saveToBrandVoice) {
                Text("Save this feedback to brand voice for all future events")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warmMid)
            }
            .toggleStyle(.checkbox)
            .disabled(isRevising)

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.sm) {
                if isRevising {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.roseGold)
                    Text("Revising…")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                } else {
                    Button("Apply") { onApply() }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmMid)
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.roseGold.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.roseGold.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Blog Section

private struct BlogSection: View {
    @Binding var blog: BlogOutput
    var photoCount: Int = 0
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRevise: (String) async throws -> Void
    var onSwapPhotos: (([URL]) async throws -> Void)? = nil
    @State private var showingPreview = false
    @State private var showingRevision = false
    @State private var feedbackText = ""
    @State private var saveToBrandVoice = false
    @State private var isRevising = false
    @State private var revisionError: String?
    @State private var isSwappingPhotos = false
    @State private var photoSwapError: String?
    @State private var undoBlog: BlogOutput? = nil

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BLOG POST")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                        if !blog.title.isEmpty {
                            Text(blog.title)
                                .font(.light(11))
                                .foregroundStyle(Color.warmMid)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ReviewTextArea(label: "Title", text: $blog.title, minHeight: 36)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("BODY (MARKDOWN)")
                                .font(.system(size: 9, weight: .medium))
                                .tracking(0.8)
                                .foregroundStyle(Color.warmMid)
                            Spacer()
                            Button(showingPreview ? "Edit" : "Preview") {
                                showingPreview.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.roseGold)
                        }
                        if showingPreview {
                            ScrollView {
                                Group {
                                    if let attr = try? AttributedString(markdown: blog.body) {
                                        Text(attr)
                                    } else {
                                        Text(blog.body)
                                    }
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(Color.warmDark)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                            .frame(minHeight: 280)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.sm)
                                    .fill(Color.creamDeep)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Radius.sm)
                                            .strokeBorder(Color.creamEdge, lineWidth: 1)
                                    )
                            )
                        } else {
                            BlogBodyEditor(text: $blog.body)
                        }
                    }

                    if showingRevision {
                        RevisionPanel(
                            feedbackText: $feedbackText,
                            saveToBrandVoice: $saveToBrandVoice,
                            isRevising: isRevising,
                            error: revisionError,
                            onApply: { applyRevision() },
                            onCancel: {
                                showingRevision = false
                                feedbackText = ""
                                saveToBrandVoice = false
                                revisionError = nil
                            }
                        )
                    } else {
                        HStack(spacing: Spacing.md) {
                            Button("Revise with feedback…") { showingRevision = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.roseGold)
                            if onSwapPhotos != nil {
                                if isSwappingPhotos {
                                    HStack(spacing: 4) {
                                        ProgressView().controlSize(.mini).tint(Color.warmMid)
                                        Text("Updating photos…")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.warmMid)
                                    }
                                } else {
                                    Button("Change photos (\(photoCount))…") { pickAndSwapPhotos() }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.warmMid)
                                }
                            }
                            if undoBlog != nil {
                                Button("Restore previous") {
                                    if let prev = undoBlog {
                                        blog = prev
                                        undoBlog = nil
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.warmMid)
                            }
                        }
                        if let err = photoSwapError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.3)
        }
    }

    private func pickAndSwapPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .heic, .image]
        panel.title = "Select Blog Photos"
        panel.message = "Choose photos for the blog post (4–7 recommended)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let snapshot = blog
        isSwappingPhotos = true
        photoSwapError = nil
        Task {
            do {
                try await onSwapPhotos?(urls)
                await MainActor.run {
                    undoBlog = snapshot
                    isSwappingPhotos = false
                }
            } catch {
                await MainActor.run {
                    isSwappingPhotos = false
                    photoSwapError = error.localizedDescription
                }
            }
        }
    }

    private func applyRevision() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let snapshot = blog
        isRevising = true
        revisionError = nil
        let shouldSave = saveToBrandVoice
        Task {
            do {
                try await onRevise(trimmed)
                if shouldSave {
                    try? PythonBridge.shared.appendBrandVoiceNote(trimmed)
                }
                await MainActor.run {
                    undoBlog = snapshot
                    isRevising = false
                    showingRevision = false
                    feedbackText = ""
                    saveToBrandVoice = false
                }
            } catch {
                await MainActor.run {
                    isRevising = false
                    revisionError = error.localizedDescription
                }
            }
        }
    }
}

private struct BlogBodyEditor: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        SpellCheckingTextEditor(text: $text)
            .nsFont(.systemFont(ofSize: 12))
            .nsTextColor(NSColor(Color.warmDark))
            .focused($focused)
            .frame(minHeight: 280)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Color.creamDeep)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(
                                focused ? Color.roseGold : Color.creamEdge,
                                lineWidth: focused ? 1.5 : 1
                            )
                    )
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - Hashtags editor

private struct HashtagsEditor: View {
    @Binding var hashtags: [String]
    @Environment(HashtagStore.self) private var hashtagStore

    // Flat editable text — joined with spaces
    @State private var raw: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Spacing.sm) {
                Text("HASHTAGS")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Color.warmMid)
                Spacer()
                Text("\(hashtags.count)/30")
                    .font(.system(size: 9))
                    .foregroundStyle(hashtags.count > 30 ? Color.roseDeep : Color.warmMid)
                if !hashtagStore.presets.isEmpty {
                    Menu {
                        ForEach(hashtagStore.presets) { preset in
                            Button(preset.name) {
                                var updated = hashtags
                                for tag in preset.tags where !updated.contains(tag) {
                                    updated.append(tag)
                                }
                                hashtags = updated
                                raw = updated.joined(separator: " ")
                            }
                        }
                    } label: {
                        Image(systemName: "tag")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.roseGold)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Apply a hashtag preset")
                }
            }
            // Plain single-line TextField — TextField has its own internal
            // cursor-following scroll for long content, so wrapping it in an
            // outer ScrollView (with a hardcoded 2000pt minWidth) caused the
            // visible scroll-past-end-of-text behavior.
            TextField("#tag1 #tag2 #tag3", text: $raw)
                .focused($focused)
                .font(.system(size: 12))
                .foregroundStyle(Color.warmDark)
                .focusEffectDisabled()
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
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
                .onChange(of: raw) { _, newVal in
                    hashtags = newVal
                        .split(separator: " ")
                        .map { String($0) }
                        .filter { !$0.isEmpty }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused {
                        // Normalize on blur
                        raw = hashtags.joined(separator: " ")
                    }
                }
        }
        .onAppear { raw = hashtags.joined(separator: " ") }
        .onChange(of: hashtags) { _, tags in
            if !focused {
                raw = tags.joined(separator: " ")
            }
        }
    }
}

// MARK: - Alt texts section

private struct AltTextsSection: View {
    @Binding var altTexts: [String]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Text("ALT TEXTS (\(altTexts.count))")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(Color.warmMid)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.warmMid)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(altTexts.indices, id: \.self) { i in
                    AltTextRow(index: i, text: binding(for: i))
                }
            }
        }
    }

    // Bounds-checked binding so a stale row index can never trap in Array._checkSubscript
    // if altTexts shrinks out from under the ForEach.
    private func binding(for i: Int) -> Binding<String> {
        Binding(
            get: { i < altTexts.count ? altTexts[i] : "" },
            set: { if i < altTexts.count { altTexts[i] = $0 } }
        )
    }
}

private struct AltTextRow: View {
    let index: Int
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text("P\(index + 1)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.warmMid)
                .padding(.top, 8)
                .frame(width: 20, alignment: .leading)
            SpellCheckingTextEditor(text: $text)
                .nsFont(.systemFont(ofSize: 11))
                .nsTextColor(NSColor(Color.warmDark))
                .focused($focused)
                .frame(minHeight: 44)
                .padding(6)
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

// MARK: - Shared text area

private struct ReviewTextArea: View {
    let label: String
    @Binding var text: String
    var minHeight: CGFloat = 80
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
            SpellCheckingTextEditor(text: $text)
                .nsFont(.systemFont(ofSize: 12))
                .nsTextColor(NSColor(Color.warmDark))
                .focused($focused)
                .frame(minHeight: minHeight)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(Color.creamDeep)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .strokeBorder(
                                    focused ? Color.roseGold : Color.creamEdge,
                                    lineWidth: focused ? 1.5 : 1
                                )
                        )
                )
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

// MARK: - Media strip for review

private struct ReviewMediaStrip: View {
    let day: DayName
    let postingDay: PostingDay
    var previewPaths: [String: String]? = nil
    var isRegenerating: Bool = false
    var graphicVersion: Int = 0
    var onPreview: ((URL) -> Void)?
    var onRegenerate: (() -> Void)? = nil
    /// When non-nil, the before/after pair shows an "Add / Change B&W" control
    /// (Tuesday only). Picking re-runs the 3-photo treatment for Tuesday + Friday.
    var onChangeBW: (() -> Void)? = nil
    var onRemoveBW: (() -> Void)? = nil
    /// Replace the whole Wednesday collage photo set (review-screen action).
    var onChangeCollagePhotos: (() -> Void)? = nil
    var collageCropOffsets: Binding<[String: CropOffset]>? = nil
    var collageCellOverride: Binding<[CollageCell]?>? = nil
    /// When true, skip the main story/reel/before-after graphic — used by the split
    /// layout's right column so the preview doesn't appear twice.
    var hideMainGraphic: Bool = false

    /// Reel video path for this day (Tuesday / Thursday only).
    private var reelURL: URL? {
        guard let p = previewPaths?["reel"],
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Collage PNG + layout sidecar — any collage day (the "collage" key is only
    /// present for collage-carousel days: Wednesday always, Sun/Mon under balanced).
    private var collageInfo: (url: URL, layoutURL: URL)? {
        guard let p = previewPaths?["collage"],
              FileManager.default.fileExists(atPath: p) else { return nil }
        let url = URL(fileURLWithPath: p)
        let layoutURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_layout.json")
        return (url, layoutURL)
    }

    /// Best still preview graphic path for non-collage days, in priority order.
    private var previewGraphicURL: (url: URL, label: String)? {
        guard let paths = previewPaths else { return nil }
        let priority: [(String, String)] = [
            ("before_after", "BEFORE / AFTER"),
            ("story_cover",  "STORY COVER"),
            ("story",        "STORY"),
        ]
        for (key, label) in priority {
            if let p = paths[key], FileManager.default.fileExists(atPath: p) {
                return (URL(fileURLWithPath: p), label)
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Reel video (Tuesday speed edit / Thursday scroll)
            if !hideMainGraphic, let url = reelURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("REEL")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(Color.warmMid)
                        .padding(.horizontal, Spacing.xl)
                    ReelPreviewPlayer(url: url, version: graphicVersion, onRegenerate: onRegenerate, isRegenerating: isRegenerating)
                        .id("\(url.path)-\(graphicVersion)")
                        .aspectRatio(9/16, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: max(440, (NSScreen.main?.visibleFrame.height ?? 800) * 0.82))
                        .padding(.horizontal, Spacing.xl)
                }
            } else if !hideMainGraphic, reelURL == nil, (day == .tuesday || day == .thursday) {
                // No reel generated yet — offer a button to generate it
                VStack(spacing: Spacing.sm) {
                    Text("No reel generated yet")
                        .font(.light(12))
                        .foregroundStyle(Color.warmMid)
                    if isRegenerating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.roseGold)
                    } else if let onRegenerate {
                        Button("Generate Reel") { onRegenerate() }
                            .buttonStyle(BrandButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.lg)
                .padding(.horizontal, Spacing.xl)
            }

            // Wednesday: interactive collage with per-cell crop controls
            if let (url, layoutURL) = collageInfo {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("COLLAGE")
                            .font(.system(size: 9, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(Color.warmMid)
                        Spacer()
                        Text("Drag photo to reposition · tap to select · drag borders to resize")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.warmMid.opacity(0.7))
                    }
                    .padding(.horizontal, Spacing.xl)

                    if let offsets = collageCropOffsets {
                        CollagePreviewThumbnail(
                            url: url,
                            layoutURL: layoutURL,
                            cropOffsets: offsets,
                            cellOverride: collageCellOverride ?? .constant(nil),
                            onPreview: { onPreview?(url) },
                            isRegenerating: isRegenerating,
                            onRegenerate: onRegenerate,
                            onChangePhotos: onChangeCollagePhotos
                        )
                        // No .id() here — image reload is handled internally via
                        // .task(id: url) and .onChange(of: isRegenerating), so the
                        // view is never destroyed and selectedCellIndex (+ slider) persists.
                        .padding(.horizontal, Spacing.xl)
                    } else {
                        PreviewGraphicThumbnail(
                            url: url,
                            onPreview: { onPreview?(url) },
                            isRegenerating: isRegenerating,
                            onRegenerate: onRegenerate
                        )
                        .id("\(url.path)-\(graphicVersion)")
                        .padding(.horizontal, Spacing.xl)
                    }
                }
            }

            // Other days: still preview graphic (before/after, story cover, story)
            if !hideMainGraphic, let (url, label) = previewGraphicURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(Color.warmMid)
                        .padding(.horizontal, Spacing.xl)

                    PreviewGraphicThumbnail(
                            url: url,
                            onPreview: { onPreview?(url) },
                            isRegenerating: isRegenerating,
                            onRegenerate: onRegenerate
                        )
                        .id("\(url.path)-\(graphicVersion)")
                        .padding(.horizontal, Spacing.xl)
                }
            }

            // Uploaded source photos (all days — plain thumbnails for preview/tap only)
            if !postingDay.photoPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(postingDay.photoPaths, id: \.self) { url in
                            ReviewThumb(url: url) { onPreview?(url) }
                                .onDrag { NSItemProvider(object: url.path as NSString) }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, 2)
                }
            }

            // Before / After pair — Tuesday and Friday. A third B&W after shows
            // when the 3-photo treatment is in use.
            if day == .tuesday || day == .friday {
                let hasBA = postingDay.rawPhotoPath != nil
                    || postingDay.editedPhotoPath != nil
                    || postingDay.bwPhotoPath != nil
                if hasBA {
                    HStack(alignment: .top, spacing: 12) {
                        if let raw = postingDay.rawPhotoPath {
                            LabeledReviewThumb(url: raw, label: "Before") { onPreview?(raw) }
                        }
                        if let edited = postingDay.editedPhotoPath {
                            LabeledReviewThumb(url: edited, label: postingDay.bwPhotoPath != nil ? "Color" : "After") { onPreview?(edited) }
                        }
                        if let bw = postingDay.bwPhotoPath {
                            LabeledReviewThumb(url: bw, label: "B&W") { onPreview?(bw) }
                        }

                        // Add / Change B&W control (Tuesday only — Friday mirrors it).
                        if let onChangeBW {
                            if postingDay.bwPhotoPath == nil {
                                Button { onChangeBW() } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: "plus.circle")
                                            .font(.system(size: 18))
                                        Text("Add B&W")
                                            .font(.system(size: 9))
                                    }
                                    .foregroundStyle(Color.roseGold)
                                    .frame(width: 60, height: 80)
                                    .background(Color.warmFaint.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                                }
                                .buttonStyle(.plain)
                                .disabled(isRegenerating)
                            } else {
                                VStack(spacing: 6) {
                                    Button("Change") { onChangeBW() }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.roseGold)
                                    Button("Remove") { onRemoveBW?() }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.warmMid)
                                }
                                .disabled(isRegenerating)
                                .padding(.top, 4)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                }
            }

            // Tuesday: screen recording
            if day == .tuesday, let rec = postingDay.screenRecordingPath {
                ReviewMediaFileRow(url: rec, icon: "film", label: "Screen recording")
                    .padding(.horizontal, Spacing.xl)
            }

            // Thursday / Tuesday: audio
            if let audio = postingDay.audioPath {
                ReviewMediaFileRow(url: audio, icon: "waveform", label: "Audio")
                    .padding(.horizontal, Spacing.xl)
            }
        }
        .padding(.bottom, Spacing.xs)
    }
}

// MARK: - Friday pipeline status (elapsed time / stall, not a bare spinner)

/// Live elapsed-time status for Friday's clip pipeline (import copy, Stage 1
/// scoring, Stage 2 Claude selection, ffmpeg render). Distinguishes started
/// / still-alive-with-elapsed-time / taking-longer-than-usual so the user
/// never sees a spinner that looks identical whether it's progressing,
/// hung, or dead.
private struct PipelineStatusView: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = PipelineProgressState.state(startedAt: startedAt, now: context.date, failedMessage: nil)
            switch state {
            case .idle, .failed:
                EmptyView()
            case .running(let seconds):
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small).tint(Color.roseGold)
                    Text("Working… \(seconds)s")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmMid)
                }
            case .stalled(let seconds):
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.roseDeep)
                    Text("Still working (\(seconds)s): this is taking longer than usual")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.roseDeep)
                }
            }
        }
    }
}

// MARK: - Friday clip manual override editor

/// Reorder / include-exclude / swap the Friday auto-cut reel's clip
/// selection (#135). Every edit here writes only to fridayClipOverride and
/// re-renders locally via render_friday_override.py - never re-invokes
/// Claude (feedback_collage_edits_no_python_regen). "Re-cut with AI" is the
/// only action that clears the override and re-runs Stage 1 + 2.
private struct FridayClipEditor: View {
    let entries: [ReelClipOverride]
    let hasOverride: Bool
    var onApply: (([ReelClipOverride]) -> Void)? = nil
    var onSwap: ((String) -> Void)? = nil
    var onRecutWithAI: (() -> Void)? = nil

    var body: some View {
        guard !entries.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("CLIPS")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Color.warmMid.opacity(0.55))

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
                        .foregroundStyle(Color.warmMid)

                        Text(URL(fileURLWithPath: entry.clipPath).lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(entry.included ? Color.white : Color.warmMid)
                            .lineLimit(1)
                            .strikethrough(!entry.included)

                        Spacer(minLength: 0)

                        Button(entry.included ? "Exclude" : "Include") { toggleIncluded(index) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.roseGold)

                        if let onSwap {
                            Button("Swap") { onSwap(entry.clipPath) }
                                .buttonStyle(.plain)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.roseGold)
                        }
                    }
                }

                if hasOverride, let onRecutWithAI {
                    Button("Re-cut with AI", action: onRecutWithAI)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmMid)
                        .padding(.top, Spacing.xs)
                }
            }
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
}

//// MARK: - Instagram post mockup

/// Read-only mockup of how the post will look on Instagram.
/// Updates live as the user edits caption / hashtags in the right column.
private struct InstagramMockup: View {
    let photoURL: URL?
    var photoURLs: [URL] = []    // carousel mode: if non-empty, show left/right arrows
    var videoURL: URL? = nil     // reel — shown instead of still photo when set
    /// Bumped on each successful regen — threaded into ReelPreviewPlayer so the
    /// AVPlayer's URL-keyed asset cache is busted even if the file path itself
    /// stays stable (Python overwrites the MP4 in place).
    var videoVersion: Int = 0
    let dayLabel: String   // e.g. "Sunday" — shown as relative post time
    let caption: String
    let hashtags: [String]
    let cardWidth: CGFloat
    /// Reel days use "Regenerate reel" copy and surface the layout / audio / photos
    /// menu items. Non-reel (story) days only get "Regenerate graphic".
    var isReelDay: Bool = false
    var onRegenerate: (() -> Void)? = nil
    var onReviseCaption: (() -> Void)? = nil
    var onNewLayout: (() -> Void)? = nil
    var onSwapAudio: (() -> Void)? = nil
    var onUploadAudio: (() -> Void)? = nil
    var onChangePhotos: (() -> Void)? = nil
    /// Current reel length (scroll seconds) and change handler — drives the
    /// "Reel length" submenu (Thursday scroll reel only). nil hides it.
    var currentReelLength: Double? = nil
    var onChangeReelLength: ((Double) -> Void)? = nil
    /// Optional B&W after controls (Tuesday reel). `hasBW` toggles the label
    /// between "Add" and "Change" and gates the Remove item.
    var onChangeBW: (() -> Void)? = nil
    var onRemoveBW: (() -> Void)? = nil
    var hasBW: Bool = false
    var isRegenerating: Bool = false

    /// Preset reel lengths offered in the menu (scroll seconds, 15–60 range).
    private static let reelLengthPresets: [Int] = [15, 20, 30, 40, 50, 60]

    private var regenerateLabelText: String {
        if isRegenerating { return "Regenerating…" }
        return isReelDay ? "Regenerate reel" : "Regenerate graphic"
    }

    private var menuHasItems: Bool {
        onRegenerate != nil
            || onReviseCaption != nil
            || onNewLayout != nil
            || onSwapAudio != nil
            || onUploadAudio != nil
            || onChangePhotos != nil
            || onChangeReelLength != nil
            || onChangeBW != nil
    }

    @State private var photo: NSImage? = nil
    @State private var carouselIndex: Int = 0

    private var hashtagLine: String {
        hashtags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }.joined(separator: " ")
    }

    private var isCarousel: Bool { photoURLs.count > 1 }

    private var displayedPhotoURL: URL? {
        if isCarousel {
            let idx = min(max(carouselIndex, 0), photoURLs.count - 1)
            return photoURLs[idx]
        }
        return photoURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 9) {
                // Gradient story-ring avatar with real DW logo
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 1.0, green: 0.78, blue: 0.22),
                                     Color(red: 0.98, green: 0.28, blue: 0.50),
                                     Color(red: 0.62, green: 0.18, blue: 0.82)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().fill(Color.white).padding(2)
                    Image("DWAvatar")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                        .padding(3)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text("dwphotony")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.black)
                    Text("Original audio")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.45))
                }

                Spacer()

                if menuHasItems {
                    Menu {
                        if let onRegenerate {
                            Button {
                                onRegenerate()
                            } label: {
                                Label(regenerateLabelText, systemImage: "arrow.clockwise")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onReviseCaption {
                            Button {
                                onReviseCaption()
                            } label: {
                                Label("Revise caption with feedback…", systemImage: "text.bubble")
                            }
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
                        if let onChangeBW {
                            Button {
                                onChangeBW()
                            } label: {
                                Label(hasBW ? "Change B&W edit" : "Add B&W edit", systemImage: "circle.lefthalf.filled")
                            }
                            .disabled(isRegenerating)
                        }
                        if hasBW, let onRemoveBW {
                            Button {
                                onRemoveBW()
                            } label: {
                                Label("Remove B&W edit", systemImage: "minus.circle")
                            }
                            .disabled(isRegenerating)
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
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(white: 0.2))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(white: 0.2))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)

            // ── Photo or reel — fills card width at native aspect ───────────
            // Use explicit dimensions so the card grows vertically to fit the
            // content instead of `scaledToFit` shrinking it when the parent
            // is height-constrained.
            Group {
                if let url = videoURL {
                    // Reel: full 9:16 at card width — card width is already set
                    // to a screen-proportional value so height is controlled.
                    ReelPreviewPlayer(url: url, version: videoVersion, onRegenerate: nil, isRegenerating: isRegenerating)
                        .frame(width: cardWidth, height: cardWidth * 16.0 / 9.0)
                        .overlay {
                            if isRegenerating {
                                ZStack {
                                    Color.black.opacity(0.4)
                                    VStack(spacing: 8) {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                            .controlSize(.large)
                                            .colorScheme(.dark)
                                        Text("Regenerating…")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                        }
                } else if let photo {
                    let aspect = photo.size.width / max(photo.size.height, 1)
                    Image(nsImage: photo)
                        .resizable()
                        .frame(width: cardWidth, height: cardWidth / max(aspect, 0.01))
                        .overlay(alignment: .leading) {
                            if isCarousel && carouselIndex > 0 {
                                CarouselArrow(systemName: "chevron.left") {
                                    carouselIndex -= 1
                                }
                                .padding(.leading, 8)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if isCarousel && carouselIndex < photoURLs.count - 1 {
                                CarouselArrow(systemName: "chevron.right") {
                                    carouselIndex += 1
                                }
                                .padding(.trailing, 8)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if isCarousel {
                                Text("\(carouselIndex + 1)/\(photoURLs.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(Color.black.opacity(0.55))
                                    )
                                    .padding(8)
                            }
                        }
                } else if displayedPhotoURL != nil {
                    Color(white: 0.92)
                        .frame(width: cardWidth, height: cardWidth)
                        .overlay { ProgressView().controlSize(.small) }
                } else {
                    Color(white: 0.92)
                        .frame(width: cardWidth, height: cardWidth)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 28))
                                .foregroundStyle(Color(white: 0.7))
                        }
                }
            }

            // ── Action bar ──────────────────────────────────────────────────
            HStack(spacing: 14) {
                Image(systemName: "heart")
                    .font(.system(size: 25, weight: .light))
                Image(systemName: "bubble.right")
                    .font(.system(size: 23, weight: .light))
                Image(systemName: "paperplane")
                    .font(.system(size: 22, weight: .light))
                Spacer()
                Image(systemName: "bookmark")
                    .font(.system(size: 22, weight: .light))
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 6)

            // ── Likes ────────────────────────────────────────────────────────
            Text("1,021 likes")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 11)
                .padding(.bottom, 5)

            // ── Caption + hashtags ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                if caption.isEmpty && hashtagLine.isEmpty {
                    Text("Caption will appear here…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(white: 0.65))
                        .italic()
                } else {
                    if !caption.isEmpty {
                        (Text("dwphotony ").font(.system(size: 12.5, weight: .semibold))
                         + Text(caption).font(.system(size: 12.5)))
                            .foregroundStyle(Color.black)
                            .lineLimit(4)
                    }
                    if !hashtagLine.isEmpty {
                        Text(hashtagLine)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.07, green: 0.31, blue: 0.78))
                            .lineLimit(2)
                    }
                }

                // View all comments
                Text("View all comments")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.55))

                // Timestamp
                Text(dayLabel.uppercased())
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color(white: 0.6))
                    .kerning(0.3)
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 12)
        }
        .frame(width: cardWidth)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color(white: 0.82), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 2)
        .task(id: displayedPhotoURL) {
            guard let url = displayedPhotoURL else { return }
            // Keep the previous image on screen while loading the next so
            // carousel swaps don't flash a placeholder (and don't reflow the
            // left column via a transient square frame).
            if let loaded = await Task.detached(priority: .userInitiated, operation: {
                NSImage(contentsOf: url)
            }).value {
                photo = loaded
            }
        }
    }
}

private struct CarouselArrow: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(white: 0.2))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cover image (#141)

/// The Instagram grid cover card: thumbnail, AI rationale (or none once a
/// manual override is in effect), a Regenerate button (reuses
/// PreviewGraphicThumbnail's own, no new UI needed), a manual override
/// escape hatch, and an elapsed-timer progress state. Shared by Friday's
/// dual-slot layout and the generic split layout (Thursday) so the two
/// never diverge.
private struct CoverSlotView: View {
    let coverURL: URL
    let rationale: String?
    var isRegenerating: Bool = false
    var regenStartedAt: Date? = nil
    var onPreview: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onChooseOverride: (() -> Void)? = nil
    var maxHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("COVER")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Color.warmMid.opacity(0.55))
                Spacer()
                if let onChooseOverride {
                    Button(action: onChooseOverride) {
                        Text("Choose a different photo…")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.roseGold)
                    .disabled(isRegenerating)
                }
            }
            .padding(.top, Spacing.md)

            PreviewGraphicThumbnail(
                url: coverURL,
                onPreview: { onPreview?() },
                isRegenerating: isRegenerating,
                onRegenerate: onRegenerate,
                maxHeight: maxHeight
            )
            .padding(.top, Spacing.xs)

            if let rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.light(11))
                    .italic()
                    .foregroundStyle(Color.warmMid)
                    .padding(.top, Spacing.xs)
            }

            if regenStartedAt != nil {
                PipelineStatusView(startedAt: regenStartedAt)
                    .padding(.top, Spacing.xs)
            }
        }
    }
}

// MARK: -

// Full-width 9:16 thumbnail for a generated story/collage/before-after graphic.
private struct PreviewGraphicThumbnail: View {
    let url: URL
    let onPreview: () -> Void
    var isRegenerating: Bool = false
    var onRegenerate: (() -> Void)? = nil
    var maxHeight: CGFloat? = nil
    @State private var image: NSImage?

    private var resolvedMaxHeight: CGFloat {
        maxHeight ?? max(440, (NSScreen.main?.visibleFrame.height ?? 800) * 0.82)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.creamDeep
                    .overlay { ProgressView().controlSize(.small).tint(Color.roseGold) }
            }
        }
        .aspectRatio(9/16, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: resolvedMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.creamEdge, lineWidth: 0.5)
        )
        // Dim + spinner while regenerating
        .overlay {
            if isRegenerating {
                ZStack {
                    Color.black.opacity(0.45)
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Regenerating…")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { NSWorkspace.shared.open(url) } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(8)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            if let onRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(8)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                }
                .buttonStyle(.plain)
                .disabled(isRegenerating)
                .help("Regenerate this graphic")
                .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isRegenerating { onPreview() } }
        .task { image = await Task.detached { NSImage(contentsOf: url) }.value }
    }
}

private struct ReviewThumb: View {
    let url: URL
    let onTap: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.creamDeep
                    .overlay { ProgressView().controlSize(.small).tint(Color.roseGold) }
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.creamEdge, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task { image = await Task.detached { NSImage(contentsOf: url) }.value }
    }
}

// MARK: - Collage Interactive Thumbnail

/// Full-width 9:16 collage thumbnail with drag-to-pan, per-cell zoom, and draggable frame dividers.
/// Drag any cell to reposition the photo within it; tap to select and reveal the SIZE slider.
/// Drag a horizontal divider handle to redistribute height between rows;
/// drag a vertical divider handle to redistribute width between adjacent columns.
private struct CollagePreviewThumbnail: View {
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
    @State private var gapColor: Color = Color.creamDeep

    private static let canvasW: Double = 1080
    private static let canvasH: Double = 1920

    private static func sampleGapColor(from nsImage: NSImage?) -> Color {
        guard let nsImage,
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return Color.creamDeep }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let sampled = bitmap.colorAt(x: 4, y: 4),
              let srgb = sampled.usingColorSpace(.sRGB)
        else { return Color.creamDeep }
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
    private var baseCells: [CollageCell] {
        cellOverride.wrappedValue ?? cells
    }

    /// Re-links layout-JSON cell paths to the day's current photo set by
    /// filename. The override is already kept current by MediaReclaim
    /// (PostingDay.rebindingPhotos), so only the JSON-loaded cells need this.
    private func rebasedToCurrentPhotos(_ loaded: [CollageCell]) -> [CollageCell] {
        CollageCell.rebasing(loaded, toCurrentPhotos: photoURLs)
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
                            Color.creamDeep
                                .overlay { ProgressView().controlSize(.small).tint(Color.roseGold) }
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
                        Color.black.opacity(0.45)
                            .overlay {
                                VStack(spacing: 6) {
                                    ProgressView().controlSize(.small).tint(.white)
                                    Text("Regenerating…")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                            }
                    }

                    // No-cells callout — collage was generated before layout JSON existed
                    if cells.isEmpty && cellOverride.wrappedValue == nil && image != nil && !isRegenerating {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.roseGold)
                            Text("Click ↺ below to enable\ncell editing")
                                .font(.system(size: 10, weight: .medium))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.65).clipShape(RoundedRectangle(cornerRadius: 8)))
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
                    .strokeBorder(Color.creamEdge, lineWidth: 0.5)
            )
            .overlay(alignment: .bottomTrailing) {
                Button { openComposited() } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(7)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if let onRegenerate {
                    Button(action: onRegenerate) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(7)
                            .background(Color.black.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    }
                    .buttonStyle(.plain)
                    .disabled(isRegenerating)
                    .help("Regenerate collage with current crop and frame adjustments")
                    .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if let onChangePhotos {
                    Button(action: onChangePhotos) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(7)
                            .background(Color.black.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    }
                    .buttonStyle(.plain)
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
                        .foregroundStyle(Color.warmMid)
                    Slider(value: scaleBinding, in: 0.25...2.5)
                    .tint(Color.roseGold)
                    Image(systemName: "photo.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmMid)
                    if hasAdjust {
                        Button("↺") {
                            var o = cropOffsets[photoKey] ?? CropOffset()
                            o.scale = 1.0
                            cropOffsets[photoKey] = o
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.roseGold)
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
                        .foregroundStyle(Color.roseGold)
                    Text("Frame changes saved — they'll appear in the exported collage")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmMid)
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
            async let img     = Task.detached { NSImage(contentsOf: url) }.value
            async let decoded = Task.detached {
                (try? JSONDecoder().decode([CollageCell].self, from: Data(contentsOf: layoutURL))) ?? []
            }.value
            let (loadedImage, loadedCells) = await (img, decoded)
            let sampledGap = Self.sampleGapColor(from: loadedImage)
            await MainActor.run {
                image = loadedImage
                cells = rebasedToCurrentPhotos(loadedCells)
                gapColor = sampledGap
            }
        }
        // Reload PNG + layout JSON when Python regeneration finishes in-place
        // (same file path, new content — .task(id: url) won't re-fire in this case)
        .onChange(of: isRegenerating) { _, nowRegenerating in
            if !nowRegenerating {
                Task {
                    async let img     = Task.detached { NSImage(contentsOf: url) }.value
                    async let decoded = Task.detached {
                        (try? JSONDecoder().decode([CollageCell].self, from: Data(contentsOf: layoutURL))) ?? []
                    }.value
                    let (loadedImage, loadedCells) = await (img, decoded)
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

// MARK: - Reel strip preview (Thursday)

private struct ReelStripLayout: Decodable {
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
private struct ReelStripPreviewThumbnail: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if swapMode {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.roseGold)
                    Text(swapSourceIdx == nil
                         ? "Tap the photo you want to move"
                         : "Tap the spot you want to swap it with")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.warmDark)
                    Spacer()
                    Button("Cancel") {
                        swapMode = false
                        swapSourceIdx = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseGold)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.roseGold.opacity(0.1))
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
                                Color.creamDeep
                                    .overlay { ProgressView().controlSize(.small).tint(Color.roseGold) }
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
                            Color.black.opacity(0.45)
                                .frame(width: geo.size.width, height: displayH)
                                .overlay {
                                    VStack(spacing: 6) {
                                        ProgressView().controlSize(.small).tint(.white)
                                        Text("Regenerating…")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.white)
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
                    .strokeBorder(Color.creamEdge, lineWidth: 0.5)
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
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(8)
                            .background(Color.black.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(10)
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
                        .foregroundStyle(Color.warmMid)
                    Slider(value: scaleBinding, in: 0.25...2.5)
                        .tint(Color.roseGold)
                    Image(systemName: "photo.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmMid)
                    if hasAdjust {
                        Button("↺") {
                            var o = cropOffsets[photoKey] ?? CropOffset()
                            o.scale = 1.0
                            cropOffsets[photoKey] = o
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.roseGold)
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
                        .foregroundStyle(Color.warmMid)
                    Spacer()
                    if onSwapPhotos != nil && !swapMode {
                        Button {
                            swapMode = true
                            swapSourceIdx = nil
                            selectedCellIndex = nil
                        } label: {
                            Label("Swap photos", systemImage: "arrow.left.arrow.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.roseGold)
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
            async let img = Task.detached { NSImage(contentsOf: url) }.value
            async let decoded = Task.detached {
                (try? JSONDecoder().decode(ReelStripLayout.self, from: Data(contentsOf: layoutURL)))
            }.value
            let (loadedImage, layout) = await (img, decoded)
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
                    async let img = Task.detached { NSImage(contentsOf: url) }.value
                    async let decoded = Task.detached {
                        (try? JSONDecoder().decode(ReelStripLayout.self, from: Data(contentsOf: layoutURL)))
                    }.value
                    let (loadedImage, layout) = await (img, decoded)
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

/// Individual cell overlay inside the collage.
///
/// Mirrors Python's crop_to_fill math exactly so the live SwiftUI preview
/// matches the regenerated PNG with no position jump.
///
/// Python model (crop_to_fill):
///   fill_scale chosen so photo covers both cell dimensions.
///   effective = fill_scale × zoom  (zoom = cropOffset.scale)
///   overflow_x = rendered_w − cell_w
///   left       = overflow_x × (0.5 + ox × 0.5)   → SwiftUI offset_x = −left
///
/// scale ≥ 1 → photo overflows cell; drag to pan.
/// scale < 1 → photo smaller than cell; blur background fades in; no drag.
private struct CollageCellOverlay: View {
    @Binding var cropOffset: CropOffset
    let isSelected: Bool
    var isDragTarget: Bool = false
    let cellW: CGFloat
    let cellH: CGFloat
    let photoURL: URL
    let onTap: () -> Void
    let onDragEnd: () -> Void

    // @State (not @GestureState) so we can reset it explicitly in onEnded — same
    // transaction as the cropOffset write — eliminating the cross-transaction race
    // that caused @GestureState reset to arrive before the binding update, briefly
    // rendering the photo at the old position (visible snap-back).
    @State private var dragTranslation: CGSize = .zero
    @State private var photo: NSImage? = nil

    private var isMoved: Bool { cropOffset.x != 0 || cropOffset.y != 0 || cropOffset.scale != 1.0 }
    private var isFillMode: Bool { CollageGeometry.isFillMode(scale: cropOffset.scale) }
    private var isDragging: Bool { dragTranslation != .zero }

    // MARK: - Photo geometry (mirrors Python's fill_scale logic)

    /// Photo aspect ratio (width / height). Defaults to 1 until the image loads.
    private var photoRatio: CGFloat {
        guard let s = photo?.size, s.height > 0 else { return 1 }
        return s.width / s.height
    }

    /// Rendered size + committed pan offset — shared with the export renderer
    /// via CollageGeometry so the live crop can't drift from the exported one.
    private var placement: (rendered: CGSize, committed: CGSize) {
        CollageGeometry.placement(photoRatio: photoRatio, cellW: cellW, cellH: cellH, offset: cropOffset)
    }

    /// Rendered photo size at the current zoom — same math as Python's effective_scale.
    private var rendered: CGSize { placement.rendered }

    /// Overflow in each axis (≥ 0 when photo overflows; < 0 when photo is smaller).
    private var overflow: CGSize {
        CGSize(width: rendered.width - cellW, height: rendered.height - cellH)
    }

    /// Offset that makes the SwiftUI view show the same crop as the export.
    private var committedOffset: CGSize { placement.committed }

    /// Live offset: committed base + drag translation, but only in axes where the
    /// photo overflows the cell. If overflow is zero in an axis, there's nothing to
    /// pan — adding dragTranslation only makes it jump back on release.
    private var liveOffset: CGSize {
        CGSize(
            width:  committedOffset.width  + (isDragging && overflow.width  > 0 ? dragTranslation.width  : 0),
            height: committedOffset.height + (isDragging && overflow.height > 0 ? dragTranslation.height : 0)
        )
    }

    /// How much the blur background shows: fades from 0 at scale 1 to 1 at scale 0.75.
    private var blurOpacity: Double {
        CollageGeometry.blurOpacity(scale: cropOffset.scale)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // ── Photo canvas ───────────────────────────────────────────────────
            // Canvas draws into a fixed-size texture — anything outside its bounds
            // is never rendered, giving guaranteed clipping without relying on the
            // SwiftUI offset+clipped combo (which can leak when offset is large).
            Canvas { context, size in
                guard let photo = self.photo else {
                    // Opaque placeholder — blocks the base PNG from showing through
                    // while this cell's photo is still loading. Without this, the
                    // uncropped Python PNG bleeds through the transparent canvas, then
                    // the overlay pops to the saved crop offset (visually a jump).
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(.black.opacity(0.85))
                    )
                    return
                }
                let img = Image(nsImage: photo)

                if isFillMode {
                    // Fill mode: draw photo at the current pan/crop position.
                    let drawRect = CGRect(
                        x: liveOffset.width,  y: liveOffset.height,
                        width: rendered.width, height: rendered.height
                    )
                    context.draw(img, in: drawRect)
                } else {
                    // Blur mode: blurred background + centered sharp photo.
                    // Opaque base prevents the underlying collage PNG from bleeding
                    // through the Gaussian filter's semi-transparent edge fringe.
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(CollageGeometry.blurBackgroundColor)
                    )
                    if blurOpacity > 0 {
                        var blurCtx = context
                        blurCtx.addFilter(.blur(radius: CollageGeometry.blurRadius))
                        blurCtx.draw(img, in: CGRect(origin: .zero, size: size))
                        // Darkening scrim proportional to blur opacity
                        context.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .color(.black.opacity(CollageGeometry.scrimDarkness * blurOpacity))
                        )
                    }
                    // Sharp photo placed via liveOffset so drag is visible on any
                    // axis that still overflows even when zoomed out (e.g. landscape
                    // photo in portrait cell at scale 0.9).
                    let drawRect = CGRect(
                        x: liveOffset.width,  y: liveOffset.height,
                        width: rendered.width, height: rendered.height
                    )
                    context.draw(img, in: drawRect)
                }
            }
            .frame(width: cellW, height: cellH)
            .allowsHitTesting(false)

            // ── Selection / drag-target / adjusted-state border ───────────────
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    isDragTarget ? Color.roseGold
                        : (isSelected || isDragging) ? Color.roseGold
                        : (isMoved ? Color.roseGold.opacity(0.5) : Color.clear),
                    lineWidth: isDragTarget ? 3 : (isSelected || isDragging) ? 2 : 1
                )
                .overlay {
                    if isDragTarget {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.roseGold.opacity(0.18))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isMoved && !isSelected && !isDragging && !isDragTarget {
                        Circle().fill(Color.roseGold).frame(width: 7, height: 7).padding(4)
                    }
                }
        }
        .frame(width: cellW, height: cellH)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { val in
                    guard overflow.width > 0 || overflow.height > 0 else { return }
                    // Clamp translation so the photo never exposes the cell boundary.
                    // liveOffset = committedOffset + dragTranslation must stay in [-overflow, 0].
                    let clampedX: CGFloat = overflow.width > 0
                        ? min(-committedOffset.width,  max(-overflow.width  - committedOffset.width,  val.translation.width))
                        : 0
                    let clampedY: CGFloat = overflow.height > 0
                        ? min(-committedOffset.height, max(-overflow.height - committedOffset.height, val.translation.height))
                        : 0
                    dragTranslation = CGSize(width: clampedX, height: clampedY)
                }
                .onEnded { val in
                    // Reset translation FIRST — in the same transaction as the
                    // cropOffset write — so SwiftUI renders exactly once with
                    // dragTranslation=0 and the new committed offset. No snap-back.
                    dragTranslation = .zero
                    let dist = hypot(val.translation.width, val.translation.height)
                    if dist < 5 {
                        onTap()
                    } else if overflow.width > 0 || overflow.height > 0 {
                        // Commit pan only in axes where there's overflow to pan through.
                        // Works in fill mode AND when slightly zoomed out, as long as
                        // the photo still overflows the cell on at least one axis.
                        if overflow.width > 0 {
                            let ovX = Double(overflow.width)
                            cropOffset.x = min(1, max(-1, cropOffset.x - 2 * Double(val.translation.width) / ovX))
                        }
                        if overflow.height > 0 {
                            let ovY = Double(overflow.height)
                            cropOffset.y = min(1, max(-1, cropOffset.y - 2 * Double(val.translation.height) / ovY))
                        }
                        onDragEnd()
                    }
                }
        )
        .task(id: photoURL) {
            photo = nil  // clear stale image before loading so old photo never renders at new crop offset
            photo = await Task.detached { NSImage(contentsOf: photoURL) }.value
        }
    }
}

// MARK: - Collage Divider Model + Helpers

/// A draggable boundary between adjacent collage rows (horizontal) or columns (vertical).
private struct CollageDivider {
    enum Kind { case horizontal, vertical }
    let kind: Kind
    let canvasPos: Int      // boundary position in canvas px: y for H, x for V
    let leading: [Int]      // cell indices on the top / left side of the boundary
    let trailing: [Int]     // cell indices on the bottom / right side
    let minPos: Int         // drag clamp — boundary cannot go below this
    let maxPos: Int         // drag clamp — boundary cannot go above this
    let rowCanvasY: Int     // top of the row (vertical dividers only)
    let rowCanvasH: Int     // height of the row (vertical dividers only)
    let actualGapPx: Int    // true pixel gap to the trailing row — ~8 for normal rows,
                            // ~90 for the strip divider (which should not be dragged or filled)
}

/// Infer all row/column boundaries from a flat list of canvas cells.
private func computeCollageDividers(_ cells: [CollageCell]) -> [CollageDivider] {
    guard cells.count > 1 else { return [] }
    let gap = 8
    let minCellPx = 80  // minimum cell dimension in canvas pixels

    // Group cells into horizontal rows by y-overlap (shared with the export
    // renderer's gap-fill rects so the two agree on row boundaries).
    let rows = CollageGeometry.groupCellsByRow(cells)

    var result: [CollageDivider] = []

    // Horizontal dividers — one between each consecutive row pair
    for i in 0..<rows.count - 1 {
        let above = rows[i], below = rows[i + 1]
        let boundary     = above.map { $0.y + $0.h }.max()!
        let belowTop     = below.map { $0.y }.min()!
        let actualGapH   = belowTop - boundary
        let leadIdx  = above.compactMap { c in cells.firstIndex { $0.photoPath == c.photoPath } }
        let trailIdx = below.compactMap { c in cells.firstIndex { $0.photoPath == c.photoPath } }
        let minPos   = above.map { $0.y }.min()! + minCellPx
        let maxPos   = belowTop + (below.map { $0.h }.min()! - minCellPx) - gap
        result.append(CollageDivider(
            kind: .horizontal, canvasPos: boundary,
            leading: leadIdx, trailing: trailIdx,
            minPos: minPos, maxPos: maxPos,
            rowCanvasY: 0, rowCanvasH: 0,
            actualGapPx: actualGapH
        ))
    }

    // Vertical dividers — one between each horizontally adjacent pair within a row
    for row in rows {
        let sorted  = row.sorted { $0.x < $1.x }
        let rowY    = row.map { $0.y }.min()!
        let rowH    = row.map { $0.y + $0.h }.max()! - rowY
        for i in 0..<sorted.count - 1 {
            let left = sorted[i], right = sorted[i + 1]
            let boundary = left.x + left.w + gap / 2
            let leftIdx  = cells.firstIndex { $0.photoPath == left.photoPath }!
            let rightIdx = cells.firstIndex { $0.photoPath == right.photoPath }!
            let minPos   = left.x + minCellPx + gap / 2
            let maxPos   = right.x + right.w - minCellPx - gap / 2
            result.append(CollageDivider(
                kind: .vertical, canvasPos: boundary,
                leading: [leftIdx], trailing: [rightIdx],
                minPos: minPos, maxPos: maxPos,
                rowCanvasY: rowY, rowCanvasH: rowH,
                actualGapPx: gap
            ))
        }
    }

    return result
}

/// Apply a drag delta (canvas pixels) to cells on both sides of a divider.
private func applyCollageDividerDelta(
    to cells: [CollageCell], divider: CollageDivider, delta: Int
) -> [CollageCell] {
    let clamped = min(max(delta, divider.minPos - divider.canvasPos),
                      divider.maxPos - divider.canvasPos)
    var result = cells
    switch divider.kind {
    case .horizontal:
        // Above cells grow/shrink in height; below cells shift down and shrink/grow.
        for idx in divider.leading  { result[idx].h += clamped }
        for idx in divider.trailing { result[idx].y += clamped; result[idx].h -= clamped }
    case .vertical:
        // Left cells grow/shrink in width; right cells shift right and shrink/grow.
        for idx in divider.leading  { result[idx].w += clamped }
        for idx in divider.trailing { result[idx].x += clamped; result[idx].w -= clamped }
    }
    return result
}

// MARK: - Collage Divider Handle View

/// Thin interactive line drawn across a row/column boundary.
///
/// Drag state is managed entirely inside this view via @GestureState, so the
/// parent never re-renders during the drag. Only the handle itself re-renders
/// on each frame — giving smooth, jank-free dragging regardless of how many
/// CollageCellOverlay views are in the parent.
///
/// The line offsets visually while dragging (clamped to minDelta…maxDelta in
/// display pixels). On gesture end the final delta is passed to `onEnded` so
/// the parent can commit the new cell layout once.
private struct CollageDividerHandle: View {
    let kind: CollageDivider.Kind
    let displayLength: CGFloat   // width (H) or height (V) in display pixels
    let minDelta: CGFloat        // minimum visual offset in display pixels
    let maxDelta: CGFloat        // maximum visual offset in display pixels
    var onEnded: (CGFloat) -> Void   // called once with the final clamped delta

    @GestureState private var liveDelta: CGFloat = 0
    @State private var isHovering = false

    private var isH: Bool { kind == .horizontal }
    private var isDragging: Bool { liveDelta != 0 }
    private var clampedDelta: CGFloat { min(max(liveDelta, minDelta), maxDelta) }

    var body: some View {
        let hitThickness: CGFloat = 20
        ZStack {
            // Wide transparent hit target
            Color.clear
                .frame(
                    width:  isH ? displayLength : hitThickness,
                    height: isH ? hitThickness  : displayLength
                )

            // Visible line — always present; brighter on hover/drag so it persists after release
            Rectangle()
                .fill(isDragging || isHovering
                      ? Color.roseGold.opacity(0.9)
                      : Color.white.opacity(0.6))
                .frame(
                    width:  isH ? displayLength : 2,
                    height: isH ? 2             : displayLength
                )

            // Directional pill — appears on hover or during drag
            if isDragging || isHovering {
                Image(systemName: isH ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isDragging ? Color.roseGold : Color.black.opacity(0.65))
                    .clipShape(Capsule())
            }
        }
        // Visually offset the line during drag — hit area stays at resting position
        .offset(
            x: isH ? 0 : clampedDelta,
            y: isH ? clampedDelta : 0
        )
        .contentShape(
            Rectangle().size(CGSize(
                width:  isH ? displayLength : hitThickness,
                height: isH ? hitThickness  : displayLength
            ))
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .gesture(
            DragGesture(minimumDistance: 2)
                .updating($liveDelta) { val, state, _ in
                    state = isH ? val.translation.height : val.translation.width
                }
                .onEnded { val in
                    let raw = isH ? val.translation.height : val.translation.width
                    onEnded(min(max(raw, minDelta), maxDelta))
                }
        )
    }
}

private struct LabeledReviewThumb: View {
    let url: URL
    let label: String
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ReviewThumb(url: url, onTap: onTap)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(Color.warmMid)
        }
    }
}

private struct ReviewMediaFileRow: View {
    let url: URL
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.roseGold)
            Text(label)
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.roseGold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(Color.creamDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .strokeBorder(Color.creamEdge, lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Reel video preview

private struct ReelPreviewPlayer: NSViewRepresentable {
    let url: URL
    var version: Int = 0
    var onRegenerate: (() -> Void)?
    var isRegenerating: Bool
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let playerView = AVPlayerView()
        playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        playerView.controlsStyle = .inline
        playerView.videoGravity = videoGravity
        playerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(playerView)
        context.coordinator.lastVersion = version
        context.coordinator.lastURL = url
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: container.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // Replace the AVPlayer when the URL changes OR the version bumps. Same
    // URL with new bytes (Python may overwrite the MP4 in place after a
    // regen) needs a fresh AVPlayer because AVFoundation caches by URL.
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let playerView = nsView.subviews.first as? AVPlayerView else { return }
        if context.coordinator.lastURL != url || context.coordinator.lastVersion != version {
            // Tear down the old player explicitly so the underlying AVAsset
            // is released before the new one memory-maps the (now overwritten)
            // file. Without this, AVFoundation can keep serving stale frames
            // even though we replaced the player object.
            playerView.player?.pause()
            playerView.player?.replaceCurrentItem(with: nil)
            playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url)))
            context.coordinator.lastURL = url
            context.coordinator.lastVersion = version
        }
        playerView.videoGravity = videoGravity
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
        var lastVersion: Int = -1
    }
}

// MARK: - Learning suggestion sheet

private struct LearningSuggestionSheet: View {
    let suggestion: String
    let onSave: (String) -> Void
    let onSkip: () -> Void

    @State private var editedSuggestion: String

    init(suggestion: String, onSave: @escaping (String) -> Void, onSkip: @escaping () -> Void) {
        self.suggestion = suggestion
        self.onSave = onSave
        self.onSkip = onSkip
        _editedSuggestion = State(initialValue: suggestion)
    }

    private var trimmed: String {
        editedSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("PATTERN FOUND IN YOUR EDITS")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.roseGold)

                Text("Based on how you revised these captions, there may be something worth adding to your brand voice. Edit the wording below before saving if you want to refine it:")
                    .font(.light(12))
                    .foregroundStyle(Color.warmMid)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SpellCheckingTextEditor(text: $editedSuggestion)
                .nsFont(.systemFont(ofSize: 13))
                .nsTextColor(NSColor(Color.warmDark))
                .padding(Spacing.sm)
                .frame(minHeight: 120, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(Color.roseGold.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md)
                                .strokeBorder(Color.roseGold.opacity(0.2), lineWidth: 1)
                        )
                )

            Text("Adding this will apply to all future caption generation.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)

            HStack(spacing: Spacing.md) {
                Button("Add to brand voice") { onSave(trimmed) }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(trimmed.isEmpty)
                Button("Reset") { editedSuggestion = suggestion }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmMid)
                    .disabled(editedSuggestion == suggestion)
                Spacer()
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmMid)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .background(Color.cream)
    }
}

// MARK: - Full-screen photo overlay

private struct ReviewPhotoOverlay: View {
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
                    .padding(16)
                }
                Spacer()
            }
        }
        .task { image = await Task.detached { NSImage(contentsOf: url) }.value }
    }
}

// MARK: - Inline RAW/Edited photo assignment for reel generation

private struct InlineReelPhotoAssignment: View {
    var rawPhoto: URL?
    var editedPhoto: URL?
    var bwPhoto: URL? = nil
    var isRegenerating: Bool = false
    var onPickRaw: () -> Void
    var onPickEdited: () -> Void
    var onPickBW: () -> Void
    var onClearBW: () -> Void
    var onGenerate: () -> Void

    private var hasAll: Bool { rawPhoto != nil && editedPhoto != nil }

    var body: some View {
        VStack(spacing: Spacing.md) {
            Text("REEL")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Assign the RAW and Edited photos to generate a speed-edit reel.")
                .font(.light(12))
                .foregroundStyle(Color.warmMid)

            HStack(alignment: .top, spacing: Spacing.md) {
                photoSlot(label: "RAW (unedited)", url: rawPhoto, action: onPickRaw)
                photoSlot(label: "Edited", url: editedPhoto, action: onPickEdited)
                VStack(spacing: Spacing.xs) {
                    photoSlot(label: "B&W (optional)", url: bwPhoto, action: onPickBW)
                    if bwPhoto != nil {
                        Button("Remove") { onClearBW() }
                            .buttonStyle(.plain)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.roseGold)
                    }
                }
            }

            if bwPhoto != nil {
                Text("3-photo post: reel reveals color over B&W, Friday shows all three.")
                    .font(.light(10))
                    .foregroundStyle(Color.roseGold.opacity(0.9))
                    .multilineTextAlignment(.center)
            }

            if hasAll {
                if isRegenerating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.roseGold)
                } else {
                    Button("Generate Reel") { onGenerate() }
                        .buttonStyle(BrandButtonStyle())
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }

    @ViewBuilder
    private func photoSlot(label: String, url: URL?, action: @escaping () -> Void) -> some View {
        VStack(spacing: Spacing.xs) {
            Button { action() } label: {
                if let url, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                } else {
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(Color.warmFaint.opacity(0.3))
                        .frame(width: 120, height: 80)
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color.warmMid)
                                Text("Choose")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.warmMid)
                            }
                        }
                }
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.warmMid)
        }
    }
}

// MARK: - Collage layout gallery (#57)

/// Renders several candidate collage layouts for a day and lets the user pick
/// one. The picked layout's seed is stored as the day's collage seed so the
/// final render reproduces it.
private struct CollageLayoutGallery: View {
    let event: Event
    let day: DayName
    var onPick: (Int) -> Void
    var onCancel: () -> Void

    @State private var candidates: [CollageCandidate] = []
    @State private var isLoading = true
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a layout — \(day.displayName)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.warmDark)
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.roseGold)
            }
            .padding(Spacing.lg)

            Divider()

            if isLoading {
                VStack(spacing: Spacing.md) {
                    ProgressView().controlSize(.large).tint(Color.roseGold)
                    Text("Rendering layout options…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmMid)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.roseDeep)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.md) {
                        ForEach(candidates, id: \.seed) { candidate in
                            Button { onPick(candidate.seed) } label: {
                                candidateThumb(candidate)
                            }
                            .buttonStyle(.plain)
                            .help("Use this layout")
                        }
                    }
                    .padding(Spacing.lg)
                }
            }
        }
        .frame(width: 580, height: 660)
        .background(Color.cream)
        .task { await load() }
    }

    @ViewBuilder
    private func candidateThumb(_ candidate: CollageCandidate) -> some View {
        if let img = NSImage(contentsOfFile: candidate.path) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .stroke(Color.warmMid.opacity(0.2), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Color.warmMid.opacity(0.1))
                .frame(height: 220)
        }
    }

    /// Identity of the layout inputs: the day, its photos (in order), and their
    /// crop offsets. When this is unchanged the cached candidates still apply.
    private func fingerprint() -> String {
        guard let pd = event.days[day.rawValue] else { return day.rawValue }
        let count = event.effectivePostingPreset.format(for: day)?.count ?? pd.photoPaths.count
        let parts = pd.photoPaths.prefix(count).map { url -> String in
            let o = pd.collageCropOffsets[url.absoluteString] ?? CropOffset()
            return "\(url.path)|\(o.x),\(o.y),\(o.scale)"
        }
        return ([day.rawValue] + parts).joined(separator: "~")
    }

    private func load() async {
        let fp = fingerprint()
        // Reuse the same options on reopen (issue #61) when nothing changed.
        if let cached = CollageCandidateCache.shared.cached(day: day, fingerprint: fp) {
            candidates = cached
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        do {
            let result = try await PythonBridge.shared.renderCollageCandidates(event: event, day: day)
            candidates = result
            if result.isEmpty {
                error = "Couldn't render layout options. Make sure this day has photos assigned."
            } else {
                CollageCandidateCache.shared.store(day: day, fingerprint: fp, candidates: result)
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
