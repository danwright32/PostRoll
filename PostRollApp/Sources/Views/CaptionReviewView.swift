import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct CaptionReviewView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(HashtagStore.self) private var hashtagStore

    @State private var result: WeekGenerationResult
    @State private var expanded: ReviewSection? = .caption(DayName.allCases.first!)
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

    // Learning flow
    @State private var isAnalyzingEdits = false
    @State private var learningSuggestion: String? = nil
    @State private var showLearnSheet = false

    // Preview graphics generation
    @State private var isGeneratingGraphics = false
    @State private var regeneratingDays: Set<DayName> = []
    @State private var graphicVersions: [DayName: Int] = [:]

    // Collage crop offsets (separate from carousel) — keyed by day rawValue then photo URL absoluteString
    @State private var dayCollageCropOffsets: [String: [String: CropOffset]] = [:]
    // Thursday reel crop offsets — same shape, independent storage so reels and collages don't fight
    @State private var dayReelCropOffsets: [String: [String: CropOffset]] = [:]
    // Collage cell layout overrides — keyed by day rawValue; nil entry = use Python layout
    @State private var dayCollageCellOverrides: [String: [CollageCell]] = [:]

    // Thursday reel editor — built eagerly in the background on view appear so the
    // PNG + layout JSON are ready by the time the user expands the Thursday card.
    @State private var thursdayEditorURL: URL? = nil
    @State private var isBuildingThursdayEditor: Bool = false

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
                        CaptionSection(
                            day: day,
                            postingDay: event.days[day.rawValue],
                            previewPaths: event.previewMediaPaths[day.rawValue],
                            caption: captionBinding(day),
                            isExpanded: expanded == section,
                            onToggle: { expanded = expanded == section ? nil : section },
                            onRevise: { feedback in
                                try await reviseCaption(day: day, feedback: feedback)
                            },
                            onPreview: { previewURL = $0 },
                            isRegeneratingGraphic: regeneratingDays.contains(day),
                            graphicVersion: graphicVersions[day] ?? 0,
                            onRegenerateGraphic: { regenerateGraphic(day: day) },
                            onSwapReelAudio: { swapReelAudio(day: day) },
                            collageCropOffsets: day == .wednesday ? collageOffsetsBinding(day) : nil,
                            collageCellOverride: day == .wednesday ? collageCellOverrideBinding(day) : nil,
                            reelCropOffsets: day == .thursday ? reelOffsetsBinding(day) : nil,
                            thursdayEditorURL: day == .thursday ? thursdayEditorURL : nil,
                            isBuildingThursdayEditor: day == .thursday ? isBuildingThursdayEditor : false
                        )
                        .disabled(isRegenerating)
                    }

                    if result.blog != nil {
                        BlogSection(
                            blog: blogBinding,
                            isExpanded: expanded == .blog,
                            onToggle: { expanded = expanded == .blog ? nil : .blog },
                            onRevise: { feedback in
                                try await reviseBlog(feedback: feedback)
                            }
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
        .sheet(isPresented: $showLearnSheet) {
            if let suggestion = learningSuggestion {
                LearningSuggestionSheet(
                    suggestion: suggestion,
                    onSave: {
                        try? PythonBridge.shared.appendBrandVoiceNote(suggestion)
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
    }

    // MARK: - Bindings

    private func collageOffsetsBinding(_ day: DayName) -> Binding<[String: CropOffset]> {
        Binding(
            get: { dayCollageCropOffsets[day.rawValue] ?? [:] },
            set: { dayCollageCropOffsets[day.rawValue] = $0; save() }
        )
    }

    private func reelOffsetsBinding(_ day: DayName) -> Binding<[String: CropOffset]> {
        Binding(
            get: { dayReelCropOffsets[day.rawValue] ?? [:] },
            set: { dayReelCropOffsets[day.rawValue] = $0; save() }
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

    private func regenerateAll() async {
        isRegenerating = true
        regenerateError = nil
        do {
            let newResult = try await PythonBridge.shared.runWeekGeneration(event: event)
            result = newResult
            mergeGlobalTags()
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
            if let paths = try? await PythonBridge.shared.runPreviewGeneration(event: event),
               !paths.isEmpty {
                await MainActor.run {
                    var ev = event
                    ev.previewMediaPaths = paths
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
        regeneratingDays.insert(day)
        Task {
            _ = try? await PythonBridge.shared.runSwapReelAudio(event: event, day: day)
            await MainActor.run {
                // Bump the version so SwiftUI rebuilds AVPlayer with the updated file.
                graphicVersions[day] = (graphicVersions[day] ?? 0) + 1
                regeneratingDays.remove(day)
            }
        }
    }

    private func regenerateGraphic(day: DayName) {
        // Always read the CURRENT event from AppState — not self.event.
        // self.event is captured by value in the closure that calls this function and
        // may be stale (pre-save snapshot). appState is a reference type so .events
        // always reflects the latest write from save().
        guard let live = appState.events.first(where: { $0.id == event.id }) else { return }
        var eventSnapshot = live

        // For Wednesday, lock the collage seed before the first regen so Python
        // always produces the same grid layout when only crop offsets change.
        if day == .wednesday,
           eventSnapshot.days[DayName.wednesday.rawValue]?.collageSeed == nil {
            var pd = eventSnapshot.days[DayName.wednesday.rawValue] ?? PostingDay(day: .wednesday)
            pd.collageSeed = Int.random(in: 1...999_999_999)
            eventSnapshot.days[DayName.wednesday.rawValue] = pd
            appState.updateEvent(eventSnapshot)  // persist so future sessions reuse same layout
        }

        regeneratingDays.insert(day)
        Task {
            if let newPaths = try? await PythonBridge.shared.runPreviewGeneration(
                event: eventSnapshot, days: [day.rawValue]
            ), let dayPaths = newPaths[day.rawValue], !dayPaths.isEmpty {
                await MainActor.run {
                    var ev = event
                    ev.previewMediaPaths[day.rawValue] = dayPaths
                    appState.updateEvent(ev)
                    graphicVersions[day] = (graphicVersions[day] ?? 0) + 1
                }
            }
            await MainActor.run { regeneratingDays.remove(day) }
        }
    }

    // MARK: - Caption revision

    private func reviseCaption(day: DayName, feedback: String) async throws {
        guard let current = result[day] else { return }
        let revised = try await PythonBridge.shared.runCaptionRevision(
            event: event,
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
            event: event,
            feedback: feedback,
            currentBlog: current
        )
        result.blog = revised
        save()
    }

    // MARK: - Persistence

    private func save() {
        var ev = event
        ev.weekResult = result
        for (dayKey, offsets) in dayCollageCropOffsets {
            if var pd = ev.days[dayKey] {
                pd.collageCropOffsets = offsets
                ev.days[dayKey] = pd
            }
        }
        for (dayKey, offsets) in dayReelCropOffsets {
            if var pd = ev.days[dayKey] {
                pd.reelCropOffsets = offsets
                ev.days[dayKey] = pd
            }
        }
        for (dayKey, cells) in dayCollageCellOverrides {
            if var pd = ev.days[dayKey] {
                pd.collageCellOverride = cells
                ev.days[dayKey] = pd
            }
        }
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
        var ev = event
        ev.weekResult = result
        for (dayKey, offsets) in dayCollageCropOffsets {
            if var pd = ev.days[dayKey] {
                pd.collageCropOffsets = offsets
                ev.days[dayKey] = pd
            }
        }
        for (dayKey, offsets) in dayReelCropOffsets {
            if var pd = ev.days[dayKey] {
                pd.reelCropOffsets = offsets
                ev.days[dayKey] = pd
            }
        }
        for (dayKey, cells) in dayCollageCellOverrides {
            if var pd = ev.days[dayKey] {
                pd.collageCellOverride = cells
                ev.days[dayKey] = pd
            }
        }
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
    var onSwapReelAudio: (() -> Void)? = nil
    var collageCropOffsets: Binding<[String: CropOffset]>? = nil
    var collageCellOverride: Binding<[CollageCell]?>? = nil
    var reelCropOffsets: Binding<[String: CropOffset]>? = nil
    var thursdayEditorURL: URL? = nil
    var isBuildingThursdayEditor: Bool = false

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
        // Tuesday only needs its reel — the before/after story is covered on Friday
        let keys: [String] = day == .tuesday
            ? ["reel"]
            : ["reel", "before_after", "story_cover", "story"]
        for key in keys {
            if let p = paths[key], FileManager.default.fileExists(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
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

    private var splitPreviewIsCollage: Bool { day == .wednesday }

    private var splitPreviewLabel: String {
        if day == .wednesday { return "COLLAGE" }
        guard let paths = previewPaths else { return "PREVIEW" }
        if paths["reel"] != nil && splitPreviewIsReel { return "REEL" }
        if paths["before_after"] != nil { return "BEFORE / AFTER" }
        if paths["story_cover"] != nil { return "STORY COVER" }
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
                .contentShape(Rectangle())
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                if day == .friday {
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
                                    dayLabel: day.displayName,
                                    caption: caption.caption,
                                    hashtags: caption.hashtags,
                                    cardWidth: tuesdayReelCardWidth,
                                    onRegenerate: onRegenerateGraphic,
                                    onSwapAudio: onSwapReelAudio,
                                    isRegenerating: isRegeneratingGraphic
                                )
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
                                    photoURLs: day == .wednesday ? (postingDay?.photoPaths ?? []) : [],
                                    dayLabel: day.displayName,
                                    caption: caption.caption,
                                    hashtags: caption.hashtags,
                                    cardWidth: mockupWidth
                                )
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
                                        onRegenerate: onRegenerateGraphic
                                    )
                                    .padding(Spacing.md)

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
                                            onSwapAudio: onSwapReelAudio,
                                            maxHeight: storyExpandedMaxHeight - 60
                                        )
                                        .id("\(pngURL.path)-\(graphicVersion)")
                                        .padding(Spacing.md)
                                    } else if day == .thursday {
                                        // Parent kicked off the build eagerly on view appear;
                                        // fall through to a loading placeholder until it lands.
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
                                            onRegenerate: onRegenerateGraphic,
                                            isRegenerating: isRegeneratingGraphic
                                        )
                                        .id("\(previewURL.path)-\(graphicVersion)")
                                        .aspectRatio(9/16, contentMode: .fit)
                                        .frame(maxWidth: .infinity, maxHeight: expandedCardMinHeight)
                                        .overlay(alignment: .topTrailing) {
                                            if onRegenerateGraphic != nil || onSwapReelAudio != nil {
                                                Menu {
                                                    if let onRegenerate = onRegenerateGraphic {
                                                        Button {
                                                            onRegenerate()
                                                        } label: {
                                                            Label(isRegeneratingGraphic ? "Regenerating…" : "Regenerate reel", systemImage: "arrow.clockwise")
                                                        }
                                                        .disabled(isRegeneratingGraphic)
                                                    }
                                                    if let onSwap = onSwapReelAudio {
                                                        Button {
                                                            onSwap()
                                                        } label: {
                                                            Label("Swap audio only", systemImage: "music.note")
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
                        if let pd = postingDay {
                            ReviewMediaStrip(
                                day: day,
                                postingDay: pd,
                                previewPaths: previewPaths,
                                isRegenerating: isRegeneratingGraphic,
                                graphicVersion: graphicVersion,
                                onPreview: onPreview,
                                onRegenerate: onRegenerateGraphic,
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
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRevise: (String) async throws -> Void
    @State private var showingPreview = false
    @State private var showingRevision = false
    @State private var feedbackText = ""
    @State private var saveToBrandVoice = false
    @State private var isRevising = false
    @State private var revisionError: String?
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
                .contentShape(Rectangle())
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 14)
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
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.3)
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
        TextEditor(text: $text)
            .focused($focused)
            .font(.system(size: 12))
            .foregroundStyle(Color.warmDark)
            .focusEffectDisabled()
            .frame(minHeight: 280)
            .scrollContentBackground(.hidden)
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
            ScrollView(.horizontal, showsIndicators: false) {
                TextField("#tag1 #tag2 #tag3", text: $raw)
                    .focused($focused)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmDark)
                    .focusEffectDisabled()
                    .textFieldStyle(.plain)
                    // Wide enough for ~30 hashtags; the ScrollView reveals them via swipe
                    .frame(minWidth: 2000, maxWidth: .infinity, alignment: .leading)
            }
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
                    AltTextRow(index: i, text: $altTexts[i])
                }
            }
        }
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
            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 11))
                .foregroundStyle(Color.warmDark)
                .focusEffectDisabled()
                .frame(minHeight: 44)
                .scrollContentBackground(.hidden)
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
            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 12))
                .foregroundStyle(Color.warmDark)
                .focusEffectDisabled()
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
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

    /// Collage PNG + layout sidecar — Wednesday only.
    private var collageInfo: (url: URL, layoutURL: URL)? {
        guard day == .wednesday,
              let p = previewPaths?["collage"],
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
                    ReelPreviewPlayer(url: url, onRegenerate: onRegenerate, isRegenerating: isRegenerating)
                        .id("\(url.path)-\(graphicVersion)")
                        .aspectRatio(9/16, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: max(440, (NSScreen.main?.visibleFrame.height ?? 800) * 0.82))
                        .padding(.horizontal, Spacing.xl)
                }
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
                            onRegenerate: onRegenerate
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

            // Before / After pair — Tuesday and Friday
            if day == .tuesday || day == .friday {
                let hasBA = postingDay.rawPhotoPath != nil || postingDay.editedPhotoPath != nil
                if hasBA {
                    HStack(spacing: 12) {
                        if let raw = postingDay.rawPhotoPath {
                            LabeledReviewThumb(url: raw, label: "Before") { onPreview?(raw) }
                        }
                        if let edited = postingDay.editedPhotoPath {
                            LabeledReviewThumb(url: edited, label: "After") { onPreview?(edited) }
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

//// MARK: - Instagram post mockup

/// Read-only mockup of how the post will look on Instagram.
/// Updates live as the user edits caption / hashtags in the right column.
private struct InstagramMockup: View {
    let photoURL: URL?
    var photoURLs: [URL] = []    // carousel mode: if non-empty, show left/right arrows
    var videoURL: URL? = nil     // reel — shown instead of still photo when set
    let dayLabel: String   // e.g. "Sunday" — shown as relative post time
    let caption: String
    let hashtags: [String]
    let cardWidth: CGFloat
    var onRegenerate: (() -> Void)? = nil
    var onSwapAudio: (() -> Void)? = nil
    var isRegenerating: Bool = false

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
                // Gradient story-ring avatar
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 1.0, green: 0.78, blue: 0.22),
                                     Color(red: 0.98, green: 0.28, blue: 0.50),
                                     Color(red: 0.62, green: 0.18, blue: 0.82)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().fill(Color.white).padding(2)
                    ZStack {
                        Circle().fill(Color(red: 0.14, green: 0.11, blue: 0.10))
                        Text("DW")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
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

                if onRegenerate != nil || onSwapAudio != nil {
                    Menu {
                        if let onRegenerate {
                            Button {
                                onRegenerate()
                            } label: {
                                Label(isRegenerating ? "Regenerating…" : "Regenerate reel", systemImage: "arrow.clockwise")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onSwapAudio {
                            Button {
                                onSwapAudio()
                            } label: {
                                Label("Swap audio only", systemImage: "music.note")
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
                    ReelPreviewPlayer(url: url, onRegenerate: nil, isRegenerating: isRegenerating)
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
            Text("1,847 likes")
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
                            var newCells = baseCells
                            let currentPath = newCells[idx].photoPath
                            guard droppedPath != currentPath else { return }
                            if let otherIdx = newCells.firstIndex(where: { $0.photoPath == droppedPath }),
                               otherIdx != idx {
                                newCells[otherIdx].photoPath = currentPath
                            }
                            newCells[idx].photoPath = droppedPath
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
                Button { NSWorkspace.shared.open(url) } label: {
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

            // "Apply frame changes" — appears only when the user has dragged a divider
            // and committed a cell override that hasn't been baked into the PNG yet.
            if cellOverride.wrappedValue != nil {
                HStack {
                    Text("Frame layout changed")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmMid)
                    Spacer()
                    if let onRegenerate {
                        Button("Apply frame changes") { onRegenerate() }
                            .buttonStyle(BrandButtonStyle())
                            .disabled(isRegenerating)
                    }
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
                cells = loadedCells
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
                        cells = loadedCells
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
    var onSwapAudio: (() -> Void)? = nil
    var maxHeight: CGFloat = 600

    @State private var image: NSImage?
    @State private var cells: [CollageCell] = []
    @State private var stripW: CGFloat = 1080
    @State private var stripH: CGFloat = 1920
    @State private var selectedCellIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                            if !isRegenerating { selectedCellIndex = nil }
                        }

                        ForEach(Array(cells.enumerated()), id: \.0) { idx, cell in
                            let photoKey = URL(fileURLWithPath: cell.photoPath).absoluteString
                            CollageCellOverlay(
                                cropOffset: Binding(
                                    get: { cropOffsets[photoKey] ?? CropOffset() },
                                    set: { cropOffsets[photoKey] = $0 }
                                ),
                                isSelected: selectedCellIndex == idx,
                                cellW: CGFloat(cell.w) * sx,
                                cellH: CGFloat(cell.h) * sx,
                                photoURL: URL(fileURLWithPath: cell.photoPath),
                                onTap: { selectedCellIndex = (selectedCellIndex == idx) ? nil : idx },
                                onDragEnd: { selectedCellIndex = idx }
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
                if onRegenerate != nil || onSwapAudio != nil {
                    Menu {
                        if let onRegenerate {
                            Button {
                                onRegenerate()
                            } label: {
                                Label(isRegenerating ? "Regenerating…" : "Regenerate reel", systemImage: "arrow.clockwise")
                            }
                            .disabled(isRegenerating)
                        }
                        if let onSwapAudio {
                            Button {
                                onSwapAudio()
                            } label: {
                                Label("Swap audio only", systemImage: "music.note")
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
    private var isFillMode: Bool { cropOffset.scale >= 1.0 }
    private var isDragging: Bool { dragTranslation != .zero && isFillMode }

    // MARK: - Photo geometry (mirrors Python's fill_scale logic)

    /// Photo aspect ratio (width / height). Defaults to 1 until the image loads.
    private var photoRatio: CGFloat {
        guard let s = photo?.size, s.height > 0 else { return 1 }
        return s.width / s.height
    }

    /// Rendered photo size at the current zoom — same math as Python's effective_scale.
    private var rendered: CGSize {
        let zoom = CGFloat(max(0.25, cropOffset.scale))
        if photoRatio > cellW / cellH {          // landscape photo in portrait cell
            return CGSize(width: cellH * photoRatio * zoom, height: cellH * zoom)
        } else {                                  // portrait / square photo in any cell
            return CGSize(width: cellW * zoom,   height: cellW / photoRatio * zoom)
        }
    }

    /// Overflow in each axis (≥ 0 when photo overflows; < 0 when photo is smaller).
    private var overflow: CGSize {
        CGSize(width: rendered.width - cellW, height: rendered.height - cellH)
    }

    // MARK: - Committed pan offset (Python formula)

    /// Offset that makes the SwiftUI view show the same crop as Python.
    /// Fill mode (overflow > 0): left = overflow × (0.5 + ox × 0.5) → offset = −left
    /// Blur mode (overflow ≤ 0): center the smaller photo over the blur background.
    private var committedOffset: CGSize {
        let cw = overflow.width > 0
            ? -overflow.width  * (0.5 + CGFloat(cropOffset.x) * 0.5)
            : (cellW - rendered.width)  / 2
        let ch = overflow.height > 0
            ? -overflow.height * (0.5 + CGFloat(cropOffset.y) * 0.5)
            : (cellH - rendered.height) / 2
        return CGSize(width: cw, height: ch)
    }

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
        max(0, min(1, (1.0 - Double(cropOffset.scale)) * 4))
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
                    if blurOpacity > 0 {
                        var blurCtx = context
                        blurCtx.addFilter(.blur(radius: 14))
                        blurCtx.draw(img, in: CGRect(origin: .zero, size: size))
                        // Darkening scrim proportional to blur opacity
                        context.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .color(.black.opacity(0.3 * blurOpacity))
                        )
                    }
                    // Sharp photo centered in the cell (smaller than cell in blur mode)
                    let centeredRect = CGRect(
                        x: committedOffset.width,  y: committedOffset.height,
                        width: rendered.width,      height: rendered.height
                    )
                    context.draw(img, in: centeredRect)
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
                    guard isFillMode && (overflow.width > 0 || overflow.height > 0) else { return }
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
                    } else if isFillMode {
                        // Commit pan only in axes where there's overflow to pan through.
                        // new_ox = old_ox − 2×drag_x / overflow_x  (ensures committedOffset
                        // equals the position the photo was at when the finger lifted)
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
                    // scale < 1: drag ignored — photo can't pan when smaller than cell
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

    // Group cells into horizontal rows by y-overlap
    let byY = cells.sorted { $0.y < $1.y }
    var rows: [[CollageCell]] = []
    var current: [CollageCell] = [byY[0]]
    for cell in byY.dropFirst() {
        if cell.y < (current.map { $0.y + $0.h }.max() ?? 0) {
            current.append(cell)
        } else {
            rows.append(current)
            current = [cell]
        }
    }
    rows.append(current)

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
    var onRegenerate: (() -> Void)?
    var isRegenerating: Bool
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let playerView = AVPlayerView()
        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .inline
        playerView.videoGravity = videoGravity
        playerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: container.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let playerView = nsView.subviews.first as? AVPlayerView else { return }
        let currentURL = (playerView.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            playerView.player = AVPlayer(url: url)
        }
        playerView.videoGravity = videoGravity
    }
}

// MARK: - Learning suggestion sheet

private struct LearningSuggestionSheet: View {
    let suggestion: String
    let onSave: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("PATTERN FOUND IN YOUR EDITS")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.roseGold)

                Text("Based on how you revised these captions, there may be something worth adding to your brand voice:")
                    .font(.light(12))
                    .foregroundStyle(Color.warmMid)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(suggestion)
                .font(.system(size: 13))
                .foregroundStyle(Color.warmDark)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                Button("Add to brand voice") { onSave() }
                    .buttonStyle(BrandButtonStyle())
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmMid)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420)
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
