import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers

struct CaptionReviewView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(HashtagStore.self) private var hashtagStore

    @State private var result: WeekGenerationResult
    @State private var expanded: ReviewSection? = nil
    /// How many separate events have tagged each account (#289). Held in state
    /// because it walks every event's tag list and `body` runs on every redraw.
    @State private var taggedEventCounts: [String: Int] = [:]
    /// Which account's numbers form is open (#279, #280).
    @State private var editingAccount: EditingAccount? = nil
    /// The instant the collaborator suggestions are judged fresh or stale
    /// against. Held rather than read from `Date()` in the body, so the panel
    /// does not recompute on every redraw.
    @State private var suggestionsAsOf = Date()
    @State private var isRegenerating = false
    /// When the current whole-week regeneration started. Set and cleared with
    /// `isRegenerating` so the indicator can show elapsed time and, past the
    /// silence threshold, a stalled state instead of an endless spinner (#95).
    @State private var regenerateStartedAt: Date? = nil
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

    /// One implementation, on the model, so this screen and the export screen
    /// cannot disagree about which days a week has (#458).
    var daysWithContent: [DayName] { result.daysWithContent(in: event) }

    @State private var previewURL: URL? = nil

    // Collage layout gallery (#57). Non-nil → the picker sheet is shown for that day.
    @State private var layoutGalleryTarget: GalleryTarget? = nil

    /// Identifiable wrapper so the layout gallery can drive `.sheet(item:)`.
    struct GalleryTarget: Identifiable {
        let day: DayName
        var id: String { day.rawValue }
    }

    /// Identifiable wrapper so the numbers form can drive `.sheet(item:)`.
    struct EditingAccount: Identifiable {
        let handle: String
        var id: String { AccountBook.key(handle) }
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
    @State private var analyzeStartedAt: Date? = nil
    @State private var learningSuggestion: String? = nil
    @State private var showLearnSheet = false
    /// Set when the learn-from-edits pass could not be run at all (#526). Its
    /// own field rather than a shared one, so a failed review cannot be read as
    /// a failed export or erase some other notice (L53).
    @State private var learningFailure: String? = nil

    // Preview graphics generation
    // Preview-graphic runs are owned by PreviewGraphicsManager, not this view:
    // EventDetailView remounts the screen via .id(event.id) on every event
    // switch, which used to discard this state while the Task kept running, so
    // coming back auto-started a second writer and showed no progress (#75).
    private var graphics: PreviewGraphicsManager { PreviewGraphicsManager.shared }
    private var isGeneratingGraphics: Bool { graphics.isGenerating(event.id) }
    private var regeneratingDays: Set<DayName> { graphics.regeneratingDays(event.id) }

    /// Days whose caption run skipped an unreadable photo (#228), in week order
    /// so the banners do not reshuffle between renders.
    private var daysWithSkippedPhotos: [DayName] {
        guard let result = event.weekResult else { return [] }
        return DayName.allCases.filter { result.warningMessage(for: $0) != nil }
    }
    // When each day's regen started, whether a cover is rebuilding, the built
    // Thursday editor, and the speculative reel pre-render all live on
    // PreviewGraphicsManager now (#456). They were @State, and the
    // .id(event.id) remount #75 proved is a real path discarded every one of
    // them mid-flight: the orphaned encode kept writing the same reel.mp4 the
    // fresh instance started writing, the editor build restarted while its
    // orphan ran, and the elapsed time vanished while the manager-owned
    // spinner survived, which is exactly the indistinct state #135 exists to
    // prevent.
    @State private var graphicVersions: [DayName: Int] = [:]


    // Collage crop offsets (separate from carousel) — keyed by day rawValue then photo URL absoluteString
    @State private var dayCollageCropOffsets: [String: [String: CropOffset]] = [:]
    // Thursday reel crop offsets — same shape, independent storage so reels and collages don't fight
    @State private var dayReelCropOffsets: [String: [String: CropOffset]] = [:]
    // Collage cell layout overrides — keyed by day rawValue; nil entry = use Python layout
    @State private var dayCollageCellOverrides: [String: [CollageCell]] = [:]
    // Friday clip reel manual edits (reorder/include-exclude/trim), keyed by day rawValue
    @State private var dayFridayClipOverride: [String: [ReelClipOverride]] = [:]


    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    EventHeader(event: event, subtitle: "Review Content")
                        .padding([.horizontal, .top], Spacing.xl)
                        .padding(.bottom, Spacing.sm)

                    StageBackButton(label: "Back to generation") {
                        // Live read, never the captured prop, which is a snapshot from
                        // when this screen was built and reverts anything saved since (#103).
                        if let ev = EventStageTransition.applying(
                                .assetsGenerated, toEventWithID: event.id, in: appState.events) {
                            appState.updateEvent(ev)
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.md)

                    CaptionReviewNotices(failedDayCount: result.errorCount)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.md)

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
                            onToggleFridayTitleCard: day == .friday ? { toggleFridayTitleCard() } : nil,
                            fridayRegenStartedAt: day == .friday ? graphics.dayStartedAt(.friday, for: event.id) : nil,
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
                                    if let stored = storedPick(url) { inlineRawPhoto = stored }
                                }
                            } : nil,
                            onPickInlineEdited: day == .tuesday ? {
                                let panel = NSOpenPanel()
                                panel.title = "Select Edited photo"
                                panel.allowedContentTypes = [.image]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    if let stored = storedPick(url) { inlineEditedPhoto = stored }
                                }
                            } : nil,
                            onPickInlineBW: day == .tuesday ? {
                                let panel = NSOpenPanel()
                                panel.title = "Select B&W edit (optional)"
                                panel.allowedContentTypes = [.image]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    if let stored = storedPick(url) { inlineBWPhoto = stored }
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
                            thursdayEditorURL: day == .thursday ? graphics.thursdayEditorURL(event.id) : nil,
                            isBuildingThursdayEditor: day == .thursday ? graphics.isBuildingThursdayEditor(event.id) : false,
                            thursdayEditorFailure: day == .thursday ? graphics.thursdayEditorFailure(event.id) : nil,
                            isCoverRegenerating: graphics.coverRegeneratingDays(event.id).contains(day),
                            coverRegenStartedAt: graphics.coverStartedAt(day, for: event.id),
                            onRegenerateCover: (day == .thursday || day == .friday) ? { regenerateCover(day: day) } : nil,
                            onChooseCoverOverride: (day == .thursday || day == .friday) ? {
                                let panel = NSOpenPanel()
                                panel.title = "Choose a cover photo"
                                panel.allowedContentTypes = [.image]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    // Copy into app storage before persisting: a raw
                                    // ~/Downloads or ~/Desktop URL loses read access on
                                    // next launch (feedback_folder_import_skips_copy),
                                    // the same discipline every other import path here follows.
                                    switch AppPaths.storedPhoto(url) {
                                    case .success(let stored):
                                        regenerateCover(day: day, overrideSource: stored)
                                    case .failure(let error):
                                        // Refuse rather than regenerate off the
                                        // external path, and say so (#179).
                                        regenerateError = ImportFailureText.message([error])
                                    }
                                }
                            } : nil
                        )
                        .disabled(isRegenerating)

                        // Beside the day's section rather than inside it: that
                        // initializer is already at the view builder's
                        // type-check limit, and two more arguments tip it over.
                        // Shown only while the day is open, so a week of
                        // collapsed days is not a wall of rankings (#278).
                        if expanded == section, let picks = collaborators(for: day, in: live) {
                            CollaboratorPanel(result: picks,
                                              eventCounts: taggedEventCounts,
                                              onEditNumbers: beginEditingNumbers)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.bottom, Spacing.md)
                                .disabled(isRegenerating)
                        }
                    }

                    if result.blog != nil {
                        BlogSection(
                            blog: blogBinding,
                            photoCount: event.blogPhotoPaths.count,
                            // Facts about the event, not about the draft, so
                            // they are computed here rather than from `blog`.
                            metadataFields: BlogMeta.copyFields(event: event),
                            isExpanded: expanded == .blog,
                            onToggle: { expanded = expanded == .blog ? nil : .blog },
                            onRevise: { feedback in try await reviseBlog(feedback: feedback) },
                            onSwapPhotos: { urls in try await swapBlogPhotos(urls: urls) }
                        )
                        .disabled(isRegenerating)
                    }

                // Every notice this screen shows below the content, in its own
                // view taking plain values, so the days that need a moved file or
                // a dead run to reach can be rendered and measured (#396).
                CaptionReviewNotices(
                    regenerateError: regenerateError,
                    skippedPhotoNotices: daysWithSkippedPhotos.compactMap { day in
                        event.weekResult?.warningMessage(for: day).map {
                            CaptionReviewDayNotice(id: day.rawValue,
                                                   message: "\(day.displayName): \($0)")
                        }
                    },
                    mediaWarnings: DayName.allCases.compactMap { day in
                        event.mediaWarnings[day.rawValue].map {
                            CaptionReviewDayNotice(id: day.rawValue,
                                                   message: "\(day.displayName): \($0)")
                        }
                    }
                )
                .padding(.horizontal, Spacing.xl)

                if isRegenerating {
                    // Names the day or blog pass the run is actually on, so a
                    // process that died is distinguishable from one that is
                    // three minutes into a Claude call (#95, #96).
                    LongRunIndicator(label: "Regenerating captions…",
                                     startedAt: regenerateStartedAt,
                                     eventID: event.id,
                                     estimate: "~3 to 6 min")
                        .padding(Spacing.xl)
                } else if isGeneratingGraphics {
                    LongRunIndicator(label: "Generating story graphics…",
                                     startedAt: graphics.startedAt(event.id),
                                     eventID: event.id,
                                     run: .media,
                                     estimate: "~1 min")
                        .padding(Spacing.xl)
                } else if let waiting = ExportReadiness.blockedReason(
                            regeneratingDays: regeneratingDays) {
                    // The two states that are not a LongRunIndicator are their own
                    // view taking plain values (#396). The indicator branches
                    // above and below already are one, with their own tests.
                    actionBar(.waitingOnRebuild(reason: waiting))
                } else if isAnalyzingEdits {
                    LongRunIndicator(label: "Reviewing your edits…",
                                     startedAt: analyzeStartedAt)
                        .padding(Spacing.xl)
                } else {
                    actionBar(.ready(graphicsError: graphics.failure(for: event.id)))
                }
            }
            }
            .background(PaintedSurfaces.page)
            .onAppear {
                mergeGlobalTags()
                // Which accounts keep coming back, so the panel can ask for
                // numbers on those and stop competing for attention on the
                // one-offs (#289). Once on arrival: it walks every event's tag
                // list, and the answer only moves when an event is edited.
                taggedEventCounts = RecurringAccounts.eventCounts(events: appState.events)
                if event.previewMediaPaths.isEmpty {
                    generateGraphics()
                } else {
                    prepareThursdayEditor()
                }
            }
            // The screen remounts whenever Dan switches events, so a debounced
            // edit still waiting to be written has to be flushed here (#91).
            .onDisappear {
                appState.flushPendingWrites()
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
                PhotoLightbox(url: url, onDismiss: { previewURL = nil })
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
        .sheet(item: $editingAccount) { target in
            AccountNumbersSheet(
                handle: target.handle,
                stats: AccountBook.shared.stats(for: target.handle),
                onSave: { followers, likes, comments in
                    AccountBook.shared.record(handle: target.handle, followers: followers,
                                              likes: likes, comments: comments, on: Date())
                    // The suggestions are judged against this instant, so
                    // moving it is what makes the panel re-rank on the numbers
                    // just entered rather than keep showing the old order.
                    suggestionsAsOf = Date()
                    editingAccount = nil
                },
                onCancel: { editingAccount = nil }
            )
        }
        // The review of Dan's edits could not be run. Reported rather than
        // skipped past, and it does not block the week: the captions are
        // already saved, so the only thing lost is the note the pass would have
        // proposed. Continuing is his call, taken here rather than made for him
        // by a `try?` (#526).
        .alert("Your edits could not be reviewed",
               isPresented: Binding(get: { learningFailure != nil },
                                    set: { if !$0 { learningFailure = nil } })) {
            Button("Continue to export") {
                learningFailure = nil
                finalizeAdvance()
            }
            Button("Stay here", role: .cancel) { learningFailure = nil }
        } message: {
            Text(learningFailure ?? "")
        }
        .sheet(isPresented: $showLearnSheet) {
            if let suggestion = learningSuggestion {
                LearningSuggestionSheet(
                    suggestion: suggestion,
                    // Returns whether the write happened, so the sheet can
                    // stay open on a failure. It used to discard a suggestion
                    // Dan had just edited by hand, dismiss, and advance the
                    // week, and the only copy of those words was in the sheet
                    // that closed (#462).
                    onSave: { editedSuggestion in
                        do {
                            try PythonBridge.shared.appendBrandVoiceNote(editedSuggestion)
                            showLearnSheet = false
                            finalizeAdvance()
                            return nil
                        } catch {
                            return BrandVoiceSaveText.failed(error.localizedDescription)
                        }
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
    /// The bottom bar, wired to this screen's behaviour. One call site per state
    /// rather than a copy of the closures each time.
    private func actionBar(_ activity: CaptionReviewActivity) -> some View {
        CaptionReviewActionBar(
            activity: activity,
            onRetryGraphics: { generateGraphics() },
            onDismissGraphicsError: { graphics.clearFailure(for: event.id) },
            onRegenerateAll: { showRegenerateConfirm = true },
            onApprove: { advance() }
        )
    }

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
                if day == .thursday { graphics.speculativeReel(for: event.id).schedule(for: liveEvent) }
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
            // Debounced: this fires on every keystroke in the caption and
            // hashtag fields (#91, #197).
            set: { result[day] = $0; saveDebounced() }
        )
    }

    private var blogBinding: Binding<BlogOutput> {
        Binding(
            get: { result.blog ?? BlogOutput() },
            // Debounced for the same reason, and it matters most here: the
            // blog body is the longest thing Dan types.
            set: { result.blog = $0; saveDebounced() }
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
        regenerateStartedAt = Date()
        regenerateError = nil
        do {
            let live = liveEvent
            let newResult = try await PythonBridge.shared.runWeekGeneration(event: live)
            // Persist FIRST, through the store. This is three to six minutes of
            // paid Claude output, and writing it only into this view's @State
            // lost it outright whenever the screen had been remounted by an
            // event switch, while the success notification still fired (#76).
            var ev = appState.events.first(where: { $0.id == event.id }) ?? live
            ev.weekResult = newResult
            appState.updateEvent(ev)
            result = newResult
            mergeGlobalTags()
            NotificationService.shared.notifyRegenerationComplete(eventName: live.name, what: "Captions")
        } catch let halt as WeekGenerationHalted {
            // The run stopped at a usage cap. What it finished is real and paid
            // for, so it is saved over the existing week rather than discarded
            // with the error (#262). The banner says which days survived and
            // where the two ways forward are: a halt shown as a bare red error
            // reads as a crash, and Dan re-runs work he already has.
            regenerateError = keepPartial(halt.week, banner: HaltedWeek.from(halt.week)?.reviewBanner
                                          ?? halt.reason)
        } catch let partial as WeekGenerationFailedWithPartial {
            // The run died with days already generated, usually the 1800s
            // watchdog. Saved for the same reason as a halt: they exist and are
            // paid for. Without this branch the same run started from this
            // screen threw them away while the generation screen kept them.
            regenerateError = keepPartial(partial.week, banner: partial.localizedDescription)
        } catch {
            regenerateError = error.localizedDescription
        }
        isRegenerating = false
        regenerateStartedAt = nil
    }

    /// Save what a run produced before it stopped, and hand back the banner to
    /// show. Shared by the two ways a run can end early (#262).
    @discardableResult
    private func keepPartial(_ week: WeekGenerationResult, banner: String) -> String {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? liveEvent
        ev.weekResult = PartialWeekMerge.applying(week, onto: ev.weekResult)
        appState.updateEvent(ev)
        if let saved = ev.weekResult { result = saved }
        return banner
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

    /// Starts the full preview run, or joins the one already in flight. The
    /// manager refuses a second concurrent run for this event, so an auto-start
    /// after a remount can't put two writers on the same output files (#75).
    private func generateGraphics() {
        graphics.startFullRun(eventID: event.id, appState: appState) {
            // Fresh generation already wrote reel_preview.png as a side effect,
            // this just resolves the URL so the Thursday card is instant when
            // expanded.
            prepareThursdayEditor()
        }
    }

    /// Kick off the Thursday reel still-preview build in the background so the
    /// per-cell editor is ready the moment the user expands Thursday. Safe to
    /// call multiple times: both the built URL and the in-progress guard live
    /// on the manager, so a remount mid-build no longer starts a second one
    /// writing the same PNG and layout JSON while the first is still going
    /// (#456).
    private func prepareThursdayEditor() {
        let eventID = event.id
        guard graphics.thursdayEditorURL(eventID) == nil,
              !graphics.isBuildingThursdayEditor(eventID) else { return }
        let live = appState.events.first(where: { $0.id == eventID }) ?? event
        guard let thurPd = live.days[DayName.thursday.rawValue],
              !thurPd.photoPaths.isEmpty,
              let reelStr = live.previewMediaPaths[DayName.thursday.rawValue]?["reel"] else {
            return
        }
        let expected = URL(fileURLWithPath: reelStr)
            .deletingLastPathComponent()
            .appendingPathComponent("reel_preview.png")
        if FileManager.default.fileExists(atPath: expected.path) {
            graphics.finishThursdayEditorBuild(eventID, url: expected)
            return
        }
        // The guard and the work are claimed together: checking above and
        // claiming here would let two remounts both pass the check.
        guard graphics.beginThursdayEditorBuild(eventID) else { return }
        Task {
            do {
                let built = try await PythonBridge.shared.runBuildReelPreview(event: live)
                await MainActor.run { graphics.finishThursdayEditorBuild(eventID, url: built) }
            } catch {
                await MainActor.run {
                    graphics.failThursdayEditorBuild(eventID, reason: error.localizedDescription)
                }
            }
        }
    }

    private func swapReelAudio(day: DayName) {
        // Clear any uploaded audio so regeneration fetches fresh Jamendo, and
        // hold on to what was cleared: this is persisted BEFORE the fetch that
        // justifies it, so a failed fetch has to put it back (#118).
        let live = appState.events.first(where: { $0.id == event.id }) ?? event
        let (cleared, previousAudio) = ReelAudioSwap.clearingAudio(in: live, day: day)
        appState.updateEvent(cleared)

        graphics.beginDayRegen(day, for: event.id)
        regenerateError = nil
        Task {
            do {
                let swapped = try await PythonBridge.shared.runSwapReelAudio(event: liveEvent, day: day)
                await MainActor.run {
                    // Record which track landed in the reel. Without this the
                    // fetched music has no name anywhere in the app (#262).
                    if let liveNow = appState.events.first(where: { $0.id == event.id }) {
                        appState.updateEvent(ReelAudioSwap.recording(swapped, in: liveNow, day: day))
                    }
                    // Bump the version so SwiftUI rebuilds AVPlayer with the updated file.
                    graphicVersions[day] = (graphicVersions[day] ?? 0) + 1
                    graphics.endDayRegen(day, for: event.id)
                    NotificationService.shared.notifyRegenerationComplete(
                        eventName: liveEvent.name,
                        what: "\(day.displayName) audio"
                    )
                }
            } catch {
                await MainActor.run {
                    graphics.endDayRegen(day, for: event.id)
                    // Put back the uploaded track this swap cleared. Without
                    // it a failed fetch left the event worse than it found it:
                    // the next retry fetched Jamendo instead of using Dan's own
                    // file, and the file became an orphan-sweep candidate on
                    // the next launch (#118). Applied to the LIVE event so an
                    // edit made while the swap ran survives the rollback.
                    if let liveNow = appState.events.first(where: { $0.id == event.id }) {
                        appState.updateEvent(
                            ReelAudioSwap.restoringAudio(previousAudio, in: liveNow, day: day))
                    }
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

    /// Copies one picked file into app storage, or reports the failure and
    /// returns nil. Every picker on this screen goes through it: a path outside
    /// app storage loses read access on the next launch and dies outright if the
    /// user renames the folder (#77, #145), and silently persisting it on a
    /// failed copy is what made that invisible (#179).
    private func storedPick(_ url: URL) -> URL? {
        let outcome = ImportedPicks.copy([url])
        if let message = outcome.failureMessage { regenerateError = message }
        return outcome.stored.first
    }

    /// Batch form of `storedPick`: keeps what copied, reports what didn't.
    private func storedPicks(_ urls: [URL]) -> [URL] {
        let outcome = ImportedPicks.copy(urls)
        if let message = outcome.failureMessage { regenerateError = message }
        return outcome.stored
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

        graphics.beginDayRegen(day, for: event.id)
        regenerateError = nil
        Task {
            do {
                let swapped = try await PythonBridge.shared.runSwapReelAudioWithFile(
                    event: liveEvent, day: day, audioPath: dest.path
                )
                await MainActor.run {
                    if let liveNow = appState.events.first(where: { $0.id == event.id }) {
                        appState.updateEvent(ReelAudioSwap.recording(swapped, in: liveNow, day: day))
                    }
                    graphicVersions[day] = (graphicVersions[day] ?? 0) + 1
                    graphics.endDayRegen(day, for: event.id)
                    NotificationService.shared.notifyRegenerationComplete(
                        eventName: liveEvent.name,
                        what: "\(day.displayName) audio"
                    )
                }
            } catch {
                await MainActor.run {
                    graphics.endDayRegen(day, for: event.id)
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
        guard panel.runModal() == .OK, let url = panel.url,
              let stored = storedPick(url) else { return }
        assignReelPhotosAndGenerate(raw: raw, edited: edited, bw: stored)
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
            guard rawPanel.runModal() == .OK, let picked = rawPanel.url,
                  let rawURL = storedPick(picked) else { return }

            // Step 2: Pick Edited photo
            let editedPanel = NSOpenPanel()
            editedPanel.title = "Select Edited photo"
            editedPanel.allowedContentTypes = [.image]
            editedPanel.allowsMultipleSelection = false
            guard editedPanel.runModal() == .OK, let pickedEdited = editedPanel.url,
                  let editedURL = storedPick(pickedEdited) else { return }

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

            let picks = storedPicks(panel.urls)
            guard !picks.isEmpty else { return }
            var ev = appState.events.first(where: { $0.id == event.id }) ?? event
            var thu = ev.days[DayName.thursday.rawValue] ?? PostingDay(day: .thursday)
            thu.photoPaths = picks.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
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

        var copied: [URL] = []
        var failures: [AppPaths.ImportCopyFailure] = []
        for url in panel.urls {
            switch AppPaths.storedClip(url) {
            case .success(let stored): copied.append(stored)
            case .failure(let error):  failures.append(error)
            }
        }
        if !failures.isEmpty { regenerateError = ImportFailureText.message(failures) }
        // Every pick failed to copy: nothing was imported, so don't kick off a
        // render that would produce the same reel as before (#179).
        guard !copied.isEmpty else { return }

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

        graphics.beginDayRegen(.friday, for: event.id)
        regenerateError = nil
        Task {
            do {
                let liveEvent = appState.events.first(where: { $0.id == event.id }) ?? ev
                let reelPath = try await PythonBridge.shared.runRenderFridayOverride(event: liveEvent)
                await MainActor.run {
                    graphics.endDayRegen(.friday, for: event.id)
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
                    graphics.endDayRegen(.friday, for: event.id)
                    regenerateError = "Friday reel edit failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Title card overlay (plan #148, Phase 3): toggled off without
    /// re-invoking Claude. Freezes the AI's current selection into
    /// fridayClipOverride (if not already overridden) so the existing
    /// override render path picks up the new mute state, same policy as
    /// any other Friday manual edit (feedback_collage_edits_no_python_regen).
    private func toggleFridayTitleCard() {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        guard let fri = ev.days[DayName.friday.rawValue] else { return }
        ev.days[DayName.friday.rawValue]?.titleCardMuted.toggle()
        appState.updateEvent(ev)

        applyFridayOverride(fri.effectiveFridayOverride)
    }

    /// Replace one clip in the Friday override with a freshly picked file.
    private func swapFridayClip(_ oldClipPath: String) {
        let panel = NSOpenPanel()
        panel.title = "Select a replacement video clip"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        let newPath: String
        switch AppPaths.storedClip(picked) {
        case .success(let stored): newPath = stored.path
        case .failure(let error):
            // Refuse the swap rather than pointing the override at a file
            // outside app storage (#179).
            regenerateError = ImportFailureText.message([error])
            return
        }

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

        let picks = storedPicks(panel.urls)
        guard !picks.isEmpty else { return }
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
        pd.photoPaths = picks.sorted {
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

    /// Open the numbers form for one account (#279).
    ///
    /// A method rather than a closure literal at the call site: that
    /// initializer is large enough that one more closure to infer pushes the
    /// view builder past its type-check budget.
    private func beginEditingNumbers(_ handle: String) {
        editingAccount = EditingAccount(handle: handle)
    }

    /// Which of a day's tagged accounts to invite as collaborators (#278).
    ///
    /// A named function rather than an inline call in the body: the view
    /// builder could not type-check the expression inside it.
    private func collaborators(for day: DayName, in live: Event) -> CollaboratorPick.Result? {
        CollaboratorPick.suggest(event: live, day: day,
                                 preset: live.effectivePostingPreset,
                                 stats: { AccountBook.shared.stats(for: $0) },
                                 asOf: suggestionsAsOf,
                                 notes: [AccountBook.shared.recoveryNote].compactMap { $0 })
    }

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
        if day == .thursday { graphics.speculativeReel(for: event.id).schedule(for: liveEvent) }
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

        graphics.beginDayRegen(day, for: event.id)
        regenerateError = nil
        Task {
            // For Thursday, try to adopt a speculative pre-render that was kicked
            // off when the user edited. `newLayout` randomizes the seed, so there's
            // nothing pre-rendered to match — skip straight to a fresh encode.
            if day == .thursday, !newLayout,
               let result = await graphics.speculativeReel(for: event.id).take(matching: eventSnapshot) {
                await MainActor.run {
                    graphics.endDayRegen(day, for: event.id)
                    applyRegenResult(result, day: day)
                }
                return
            }
            // No usable pre-render: make sure no stale speculative encode is still
            // writing the same output file before we start a fresh one.
            if day == .thursday { graphics.speculativeReel(for: event.id).cancelAll() }

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
                graphics.endDayRegen(day, for: event.id)
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
        // Keep the asset screen's failure list in step with what happened here, so
        // a day fixed (or broken again) from the review screen doesn't leave a
        // contradictory message behind on the previous screen.
        recordMediaOutcome(day: day, error: result.errors[day.rawValue],
                           warning: result.warnings[day.rawValue])

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

    /// Record (or clear) a day's graphics failure on the live event, so the asset
    /// screen's failure list reflects the latest attempt from either screen.
    @MainActor
    private func recordMediaOutcome(day: DayName, error: String?, warning: String? = nil) {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        let existingError = ev.mediaErrors[day.rawValue]
        let existingWarning = ev.mediaWarnings[day.rawValue]
        guard existingError != error || existingWarning != warning else { return }
        if let error { ev.mediaErrors[day.rawValue] = error }
        else { ev.mediaErrors.removeValue(forKey: day.rawValue) }
        // Recorded alongside the error rather than folded into it: a day that
        // rendered without an optional photo used to report as a failed
        // regeneration, which was simply untrue (#265).
        if let warning { ev.mediaWarnings[day.rawValue] = warning }
        else { ev.mediaWarnings.removeValue(forKey: day.rawValue) }
        appState.updateEvent(ev)
    }

    /// Regenerate (or manually override) just the day's cover image (#141).
    /// Deliberately does NOT call regenerateGraphic: that would force a full
    /// reel/story regen (for Friday specifically, a real Stage 1/2 recut +
    /// ffmpeg render) just to refresh one thumbnail. Routes to
    /// PythonBridge.runCoverRegeneration instead, the cheap cover-only path.
    private func regenerateCover(day: DayName, overrideSource: URL? = nil) {
        guard let live = appState.events.first(where: { $0.id == event.id }) else { return }
        guard graphics.beginCoverRegen(day, for: event.id) else { return }
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
                graphics.endCoverRegen(day, for: event.id)
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
        var next = revised
        next.applyFindings(revised.findings, checkedBody: revised.body)
        result.blog = next
        save()
    }

    private func swapBlogPhotos(urls: [URL]) async throws {
        guard let current = result.blog else { return }
        let updated = try await PythonBridge.shared.runBlogPhotoSwap(
            currentBody: current.body,
            photoPaths: urls,
            event: liveEvent
        )
        var updatedBlog = current
        updatedBlog.body = updated.body
        updatedBlog.photoCount = urls.count
        // The swap rewrites every alt text, so its checks describe THIS body.
        updatedBlog.applyFindings(updated.findings, checkedBody: updated.body)
        result.blog = updatedBlog
        save()
        // blogPhotoPaths lives outside weekResult — re-read live event so
        // this write lands on top of what save() just persisted.
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.blogPhotoPaths = urls
        appState.updateEvent(ev)
    }

    // MARK: - Persistence

    /// Persist on a pause in typing rather than on every keystroke.
    ///
    /// The in-memory event is updated immediately either way, so nothing reads
    /// stale text; only the whole-store serialisation waits (#91, #197).
    private func saveDebounced() {
        appState.updateEventDebounced(mergedEvent())
    }

    private func save() {
        appState.updateEvent(mergedEvent())
    }

    /// The live event with this screen's local state merged in.
    ///
    /// Always re-read from AppState rather than using the captured `event`
    /// prop, which goes stale the moment anything else writes.
    private func mergedEvent() -> Event {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.weekResult = result
        DayStateMerger.mergeLocalStateIntoDays(
            &ev,
            collageCropOffsets: dayCollageCropOffsets,
            reelCropOffsets: dayReelCropOffsets,
            collageCellOverrides: dayCollageCellOverrides,
            fridayClipOverride: dayFridayClipOverride
        )
        return ev
    }

    private func advance() {
        // Belt and braces with the bar above: a rebuild that starts between
        // the button rendering and the press must not let a stale export
        // through (#89).
        guard ExportReadiness.canExport(regeneratingDays: regeneratingDays) else { return }
        save()
        let hasEdits = DayName.allCases.contains { result[$0]?.wasEdited == true }
        guard hasEdits else {
            finalizeAdvance()
            return
        }
        isAnalyzingEdits = true
        analyzeStartedAt = Date()
        Task {
            // Not `try?`. A pass that FAILED used to return the same nil as one
            // with nothing to say, so a paid Claude call that never ran looked
            // exactly like a model that had no note to add, and the week
            // advanced either way (#526).
            var suggestion: String? = nil
            var failure: String? = nil
            do {
                suggestion = try await PythonBridge.shared.runLearnFromEdits(result: result)
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                isAnalyzingEdits = false
                analyzeStartedAt = nil
                switch LearnFromEditsOutcome.decide(suggestion: suggestion, failure: failure) {
                case .offerSuggestion(let s):
                    learningSuggestion = s
                    showLearnSheet = true
                case .advance:
                    finalizeAdvance()
                case .reportFailure(let message):
                    learningFailure = message
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

/// Internal rather than private so the review sheet can draw it (#645).
///
/// It is the bulk of the caption review pane and reads nothing from the
/// environment, which is what makes it safe to render: the screen around it
/// holds the week's result and would reach the store (L2).
struct CaptionSection: View {
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
    /// Title card overlay (plan #148, Phase 3): toggled off without
    /// re-invoking Claude, same as reorder/include-exclude edits.
    var onToggleFridayTitleCard: (() -> Void)? = nil
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
    /// Why the editor is not there, when a build ran and failed (#456).
    var thursdayEditorFailure: String? = nil
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
    /// A brand voice note that would not write, kept apart from the revision's
    /// own outcome (#462).
    @State private var brandVoiceError: String?
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
        thursdayReelPreviewURL.map(LayoutSidecar.url(for:))
    }

    /// The count, on the collapsed header.
    @ViewBuilder
    private var captionFindingsBadge: some View {
        if let summary = caption.findingsSummary {
            // The wash and the ink from one place, so the count cannot be drawn
            // in the colour of its own capsule again (#600).
            let findings = PaintedSurfaces.captionFindings(stale: caption.findingsAreStale)
            Text(summary)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(findings.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(findings.badge))
                .accessibilityLabel("Caption checks: \(summary)")
        }
    }

    /// The deterministic credit checks from #475, under the caption they
    /// describe.
    ///
    /// Same shape as the blog's panel and for the same reason: these report
    /// rather than repair, so the quoted handle IS the feature. Nothing here
    /// knows the handle that should have been used in place of a guessed one,
    /// and guessing a second time is the exact failure the check exists to
    /// stop. Once Dan edits the caption the checks no longer describe it, so
    /// the panel says so rather than going on naming a handle he has removed.
    @ViewBuilder
    private var captionFindingsPanel: some View {
        if let summary = caption.findingsSummary {
            FindingsPanel(summary: summary,
                          findings: caption.findings,
                          isStale: caption.findingsAreStale,
                          subject: "caption")
        }
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
                        .foregroundStyle(isExpanded ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)

                    if day == .friday {
                        Text("Story only")
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                    } else if !caption.caption.isEmpty {
                        Text(String(caption.caption.prefix(40)) + (caption.caption.count > 40 ? "…" : ""))
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer()
                    // Visible while collapsed, so a caption tagging a handle
                    // nobody offered is not something Dan has to open the day
                    // to discover (#475).
                    captionFindingsBadge
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
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
                    // Which clips the crop gate refused, said out loud on the
                    // screen where Dan is deciding whether the cut is right
                    // (#489). The field carried this all along and nothing read
                    // it.
                    if let cropNote = FridayReviewDisplay.cropNote(plan) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "crop")
                                .font(.system(size: 11))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                            Text(cropNote)
                                .font(.light(11))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.xs)
                    }
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
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
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
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
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
                                captionFindingsPanel
                                HashtagsEditor(hashtags: $caption.hashtags)

                                FridayClipEditor(
                                    entries: postingDay?.effectiveFridayOverride ?? [],
                                    hasOverride: postingDay?.fridayClipOverride != nil,
                                    onApply: onApplyFridayOverride,
                                    onSwap: onSwapFridayClip,
                                    onRecutWithAI: onRecutFridayWithAI,
                                    titleCardMuted: postingDay?.titleCardMuted ?? false,
                                    onToggleTitleCard: onToggleFridayTitleCard
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
                                        brandVoiceError: brandVoiceError,
                                        onApply: { applyRevision() },
                                        onCancel: {
                                            showingRevision = false
                                            feedbackText = ""
                                            saveToBrandVoice = false
                                            revisionError = nil
                                brandVoiceError = nil
                                        }
                                    )
                                } else {
                                    Button("Revise with feedback…") { showingRevision = true }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12))
                                        .foregroundStyle(PaintedSurfaces.pageAccentText)
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
                                .foregroundStyle(PaintedSurfaces.secondaryText)
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
                        .background(PaintedSurfaces.storyPanel)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.md)
                    } else {
                        Text("Friday story will appear here once generated.")
                            .font(.light(12))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            .padding(.horizontal, Spacing.xl)
                            .padding(.vertical, Spacing.md)
                    }

                    // Friday auto-cut clip reel retired (2026-07-09): even after
                    // closing the pacing/crop/title-card gaps, the output still
                    // didn't clear Dan's bar against his own CapCut edit, and he
                    // decided to keep cutting Friday reels externally instead.
                    // The "Import Clips…" entry point is removed so new imports
                    // can't start the auto-cut pipeline; everything downstream
                    // (FridayClipEditor, crop popover, title card toggle, Stage
                    // 1/2/3) is left in place, dormant, not deleted.
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
                                captionFindingsPanel

                                HStack(spacing: Spacing.sm) {
                                    Spacer()
                                    Text("\(caption.caption.count) chars")
                                        .font(.system(size: 10))
                                        .foregroundStyle(caption.caption.count > 2200 ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)
                                    // Says the copy landed, and carries a name for an icon
                                    // that had none (#465, #466).
                                    ClipboardCopyButton(text: caption.caption,
                                                        what: "\(day.displayName) caption")
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
                                        brandVoiceError: brandVoiceError,
                                        onApply: { applyRevision() },
                                        onCancel: {
                                            showingRevision = false
                                            feedbackText = ""
                                            saveToBrandVoice = false
                                            revisionError = nil
                                brandVoiceError = nil
                                        }
                                    )
                                } else {
                                    HStack(spacing: Spacing.md) {
                                        Button("Revise with feedback…") { showingRevision = true }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 12))
                                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                                        if undoCaption != nil {
                                            Button("Restore previous") {
                                                caption = undoCaption!
                                                undoCaption = nil
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 12))
                                            .foregroundStyle(PaintedSurfaces.secondaryText)
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
                        // Wrapped in a scroll view so the fixed-size mockup +
                        // controls can't force the whole card taller than the
                        // screen budget.
                        //
                        // Faded rather than bare, because on a story or collage
                        // day a tall mockup pushes the caption editor, the
                        // hashtags and the revise field below the fold, and
                        // macOS hides the scrollbar until a gesture starts, so
                        // nothing at rest said the column continued (#468, L76).
                        FadingScrollView {
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
                            captionFindingsPanel

                            HStack(spacing: Spacing.sm) {
                                Spacer()
                                Text("\(caption.caption.count) chars")
                                    .font(.system(size: 10))
                                    .foregroundStyle(caption.caption.count > 2200 ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)
                                // Says the copy landed, and carries a name for an icon
                                // that had none (#465, #466).
                                ClipboardCopyButton(text: caption.caption,
                                                    what: "\(day.displayName) caption")
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
                                    brandVoiceError: brandVoiceError,
                                    onApply: { applyRevision() },
                                    onCancel: {
                                        showingRevision = false
                                        feedbackText = ""
                                        saveToBrandVoice = false
                                        revisionError = nil
                                brandVoiceError = nil
                                    }
                                )
                            } else {
                                HStack(spacing: Spacing.md) {
                                    Button("Revise with feedback…") { showingRevision = true }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12))
                                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                                    if undoCaption != nil {
                                        Button("Restore previous") {
                                            caption = undoCaption!
                                            undoCaption = nil
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12))
                                        .foregroundStyle(PaintedSurfaces.secondaryText)
                                    }
                                }
                            }
                        }  // inner editing-controls VStack
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.md)
                    }  // outer left column VStack
                    }  // ScrollView
                    .frame(maxWidth: .infinity, maxHeight: storyExpandedMaxHeight)
                    // The cap is captured rather than read inside: the transform
                    // closure is Sendable, and reading a main-actor property from
                    // one is an error on the Swift the CI Xcode ships. A CGFloat
                    // crosses fine; the property it came from does not.
                    .onGeometryChange(for: CGFloat.self) { [cap = storyMockupMaxWidth] proxy in
                        // Mockup width = min(column width − padding, screen-proportional cap)
                        min(max(proxy.size.width - Spacing.xl * 2, 200), cap)
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
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.top, Spacing.sm)

                                if splitPreviewIsCollage, let offsets = collageCropOffsets {
                                    let layoutURL = LayoutSidecar.url(for: previewURL)
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
                                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                                        .disabled(isRegeneratingGraphic)
                                        .padding(.bottom, Spacing.xs)
                                    }

                                    // Draggable photo thumbnails for swapping cells
                                    if let pd = postingDay, !pd.photoPaths.isEmpty {
                                        FadingScrollView(axis: .horizontal) {
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
                                            // A build that failed is not a slow
                                            // one: spinning here forever is the
                                            // shape #461 was about (L10).
                                            if let failure = thursdayEditorFailure {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(PaintedSurfaces.storyPanelLabel)
                                                Text("The per photo editor could not be prepared. \(Sentence.closed(failure))")
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(PaintedSurfaces.storyPanelDetail)
                                                    .multilineTextAlignment(.center)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            } else {
                                                ProgressView().controlSize(.small).tint(PaintedSurfaces.storyPanelLabel)
                                                Text(isBuildingThursdayEditor ? "Preparing editor…" : "Loading…")
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(PaintedSurfaces.storyPanelDetail)
                                            }
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
                                                    .foregroundStyle(PaintedSurfaces.photoScrimIcon)
                                                    .padding(8)
                                                    .background(PaintedSurfaces.photoScrim)
                                                    .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                                            }
                                            .menuStyle(.borderlessButton)
                                            .menuIndicator(.hidden)
                                            // An icon-only menu trigger with
                                            // no name is a control VoiceOver
                                            // can only call "button" (#465).
                                            .accessibilityLabel("Graphic options")
                                            .help("Graphic options")
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
                            .background(PaintedSurfaces.storyPanel)
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
                        captionFindingsPanel

                        HStack(spacing: Spacing.sm) {
                            Spacer()
                            Text("\(caption.caption.count) chars")
                                .font(.system(size: 10))
                                .foregroundStyle(caption.caption.count > 2200 ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)
                            // Says the copy landed, and carries a name for an icon
                            // that had none (#465, #466).
                            ClipboardCopyButton(text: caption.caption,
                                                what: "\(day.displayName) caption")
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
                                brandVoiceError: brandVoiceError,
                                onApply: { applyRevision() },
                                onCancel: {
                                    showingRevision = false
                                    feedbackText = ""
                                    saveToBrandVoice = false
                                    revisionError = nil
                                brandVoiceError = nil
                                }
                            )
                        } else {
                            HStack(spacing: Spacing.md) {
                                Button("Revise with feedback…") { showingRevision = true }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                                if undoCaption != nil {
                                    Button("Restore previous") {
                                        caption = undoCaption!
                                        undoCaption = nil
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
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
                // The revision has landed. A note that will not write is its own
                // failure and gets its own field: reporting it as the revision
                // failing would tell Dan his edit had not happened when it had
                // (#462, L53).
                var noteFailure: String? = nil
                if shouldSave {
                    do {
                        try PythonBridge.shared.appendBrandVoiceNote(trimmed)
                    } catch {
                        noteFailure = BrandVoiceSaveText
                            .revisionLandedButNoteDidNot(error.localizedDescription)
                    }
                }
                await MainActor.run {
                    undoCaption = snapshot
                    isRevising = false
                    brandVoiceError = noteFailure
                    // Held open on a failed note, because the note is the text
                    // in this sheet and dismissing is what threw it away.
                    showingRevision = (noteFailure != nil)
                    if noteFailure == nil {
                        feedbackText = ""
                        saveToBrandVoice = false
                    }
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
    /// The revision landed and only the brand voice note did not (#462). Its
    /// own field rather than a second meaning for `error`, which would say the
    /// revision failed when it did not.
    var brandVoiceError: String? = nil
    let onApply: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("FEEDBACK FOR REVISION")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(PaintedSurfaces.pageAccentText)

            TextField("e.g. make it shorter, add @dciny, don't mention the scene label", text: $feedbackText)
                .focused($focused)
                .font(.system(size: 12))
                .foregroundStyle(PaintedSurfaces.bodyText)
                .focusEffectDisabled()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(PaintedSurfaces.deepPage)
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
                    .foregroundStyle(PaintedSurfaces.secondaryText)
            }
            .toggleStyle(.checkbox)
            .disabled(isRevising)

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let brandVoiceError {
                Text(brandVoiceError)
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.sm) {
                if isRevising {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PaintedSurfaces.iconAccent)
                    Text("Revising…")
                        .font(.light(11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                } else {
                    Button("Apply") { onApply() }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
            }
        }
        .padding(Spacing.md)
        .background(PaintedSurfaces.reflowPanelFill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(PaintedSurfaces.accentBorder.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Blog Section

private struct BlogSection: View {
    @Binding var blog: BlogOutput
    var photoCount: Int = 0
    /// The SEO description and details block (#284). Passed in rather than
    /// derived from `blog`: they are facts about the event, and they must never
    /// be part of the post body.
    var metadataFields: [BlogMeta.CopyField] = []
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
    /// A brand voice note that would not write, kept apart from the revision's
    /// own outcome (#462).
    @State private var brandVoiceError: String?
    @State private var isSwappingPhotos = false
    @State private var photoSwapError: String?
    @State private var undoBlog: BlogOutput? = nil
    /// Confirms the copy landed. Reset whenever the text changes, so it never
    /// claims the clipboard holds something it no longer does.
    @State private var copiedDraft = false
    /// Which metadata field was last copied, by label. One value rather than
    /// one flag per field, so copying the second cannot leave the first still
    /// claiming the clipboard (#284).
    @State private var copiedMetadata: String? = nil

    /// The SEO description and details block, each with its own copy control
    /// (#284).
    ///
    /// Deliberately below the body and inside its own bordered card, because
    /// the risk runs both ways: leaving these only in the export folder repeats
    /// #205 (the title was generated, stored and shown, and Dan still typed it
    /// by hand, because the surface he copies from carried the body alone), and
    /// pasting them INTO the body is a new way to ship the wrong thing, since a
    /// fact block inside the post reaches the AI round trip (#283).
    @ViewBuilder
    private var metadataPanel: some View {
        if !metadataFields.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("POST METADATA")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Text("Not part of the post. Paste these into the page's own fields, not into the body.")
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(metadataFields, id: \.label) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(field.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(PaintedSurfaces.bodyText)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(field.text, forType: .string)
                                copiedMetadata = field.label
                            } label: {
                                Label(copiedMetadata == field.label ? "Copied" : "Copy",
                                      systemImage: copiedMetadata == field.label
                                                   ? "checkmark" : "doc.on.doc")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                            .help(field.help)
                            .accessibilityLabel("Copy \(field.label)")
                        }
                        Text(field.text)
                            .font(.system(size: 11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(PaintedSurfaces.deepPage)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)
                    )
            )
        }
    }

    /// The deterministic checks from #201. They report rather than rewrite,
    /// so this panel IS the feature: the quoted text is what lets Dan fix each
    /// one. Once he edits the body the checks no longer describe it, so the
    /// panel says so instead of continuing to assert stale findings.
    @ViewBuilder
    private var blogFindingsPanel: some View {
        if let summary = blog.findingsSummary {
            FindingsPanel(summary: summary,
                          findings: blog.findings,
                          isStale: blog.findingsAreStale,
                          subject: "draft")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BLOG POST")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(isExpanded ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)
                        if !blog.title.isEmpty {
                            Text(blog.title)
                                .font(.light(11))
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    // Visible while collapsed, so the checks are not something
                    // Dan has to open the section to discover (#201).
                    if let summary = blog.findingsSummary {
                        // The ink and the wash from one place, which is what
                        // captionFindings exists for: this drew its own summary
                        // in a colour chosen beside the wash it sits on, so the
                        // two could disagree and the measured pair covered
                        // neither (#600, #620).
                        let findings = PaintedSurfaces.captionFindings(
                            stale: blog.findingsAreStale)
                        Text(summary)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(findings.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(findings.badge))
                            .accessibilityLabel("Blog checks: \(summary)")
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    blogFindingsPanel

                    ReviewTextArea(label: "Title", text: $blog.title, minHeight: 36)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("BODY (MARKDOWN)")
                                .font(.system(size: 9, weight: .medium))
                                .tracking(0.8)
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                            Spacer()
                            // One thing to copy, title included (#205). The
                            // title was generated, stored and shown, and Dan
                            // still typed it by hand every time because the
                            // surface he copies from carried the body alone.
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    BlogDraftText.copyText(title: blog.title, body: blog.body),
                                    forType: .string)
                                copiedDraft = true
                            } label: {
                                Label(copiedDraft ? "Copied" : "Copy title + body",
                                      systemImage: copiedDraft ? "checkmark" : "doc.on.doc")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                            .help("Copy the post with its title, ready to paste")

                            Button(showingPreview ? "Edit" : "Preview") {
                                showingPreview.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
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
                                .foregroundStyle(PaintedSurfaces.bodyText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                            .frame(minHeight: 280)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.sm)
                                    .fill(PaintedSurfaces.deepPage)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Radius.sm)
                                            .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)
                                    )
                            )
                        } else {
                            BlogBodyEditor(text: $blog.body)
                        }
                    }

                    metadataPanel

                    if showingRevision {
                        RevisionPanel(
                            feedbackText: $feedbackText,
                            saveToBrandVoice: $saveToBrandVoice,
                            isRevising: isRevising,
                            error: revisionError,
                            brandVoiceError: brandVoiceError,
                            onApply: { applyRevision() },
                            onCancel: {
                                showingRevision = false
                                feedbackText = ""
                                saveToBrandVoice = false
                                revisionError = nil
                                brandVoiceError = nil
                            }
                        )
                    } else {
                        HStack(spacing: Spacing.md) {
                            Button("Revise with feedback…") { showingRevision = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(PaintedSurfaces.pageAccentText)
                            if onSwapPhotos != nil {
                                if isSwappingPhotos {
                                    HStack(spacing: 4) {
                                        ProgressView().controlSize(.mini).tint(PaintedSurfaces.secondaryText)
                                        Text("Updating photos…")
                                            .font(.system(size: 12))
                                            .foregroundStyle(PaintedSurfaces.secondaryText)
                                    }
                                } else {
                                    Button("Change photos (\(photoCount))…") { pickAndSwapPhotos() }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12))
                                        .foregroundStyle(PaintedSurfaces.secondaryText)
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
                                .foregroundStyle(PaintedSurfaces.secondaryText)
                            }
                        }
                        if let err = photoSwapError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(PaintedSurfaces.stateErrorText)
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.3)
        }
        // A stale "Copied" would claim the clipboard holds text that has since
        // changed (#205).
        .onChange(of: blog.body) { copiedDraft = false }
        .onChange(of: blog.title) { copiedDraft = false }
        // Same rule for the metadata: these change when the event's own facts
        // do, not when the draft does, so they watch their own text.
        .onChange(of: metadataFields) { copiedMetadata = nil }
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
        // Copy into app storage before these become the blog's photo paths, so
        // a later render can't fail on a folder the user renamed (#77).
        let outcome = ImportedPicks.copy(panel.urls)
        if let message = outcome.failureMessage { photoSwapError = message }
        let urls = outcome.stored
        guard !urls.isEmpty else { return }
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
                // The revision has landed. A note that will not write is its own
                // failure and gets its own field: reporting it as the revision
                // failing would tell Dan his edit had not happened when it had
                // (#462, L53).
                var noteFailure: String? = nil
                if shouldSave {
                    do {
                        try PythonBridge.shared.appendBrandVoiceNote(trimmed)
                    } catch {
                        noteFailure = BrandVoiceSaveText
                            .revisionLandedButNoteDidNot(error.localizedDescription)
                    }
                }
                await MainActor.run {
                    undoBlog = snapshot
                    isRevising = false
                    brandVoiceError = noteFailure
                    showingRevision = (noteFailure != nil)
                    if noteFailure == nil {
                        feedbackText = ""
                        saveToBrandVoice = false
                    }
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
            .nsTextColor(NSColor(PaintedSurfaces.bodyText))
            .focused($focused)
            .frame(minHeight: 280)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(PaintedSurfaces.deepPage)
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
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Spacer()
                Text("\(hashtags.count)/30")
                    .font(.system(size: 9))
                    .foregroundStyle(hashtags.count > 30 ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)
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
                            .foregroundStyle(PaintedSurfaces.iconAccent)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Apply a hashtag preset")
                    .help("Apply a hashtag preset")
                    .accessibilityLabel("Apply a hashtag preset")
                }
            }
            // Plain single-line TextField — TextField has its own internal
            // cursor-following scroll for long content, so wrapping it in an
            // outer ScrollView (with a hardcoded 2000pt minWidth) caused the
            // visible scroll-past-end-of-text behavior.
            TextField("#tag1 #tag2 #tag3", text: $raw)
                .focused($focused)
                .font(.system(size: 12))
                .foregroundStyle(PaintedSurfaces.bodyText)
                .focusEffectDisabled()
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.xs)
                    .fill(PaintedSurfaces.deepPage)
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
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
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
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .padding(.top, 8)
                .frame(width: 20, alignment: .leading)
            SpellCheckingTextEditor(text: $text)
                .nsFont(.systemFont(ofSize: 11))
                .nsTextColor(NSColor(PaintedSurfaces.bodyText))
                .focused($focused)
                .frame(minHeight: 44)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(PaintedSurfaces.deepPage)
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
                .foregroundStyle(PaintedSurfaces.secondaryText)
            SpellCheckingTextEditor(text: $text)
                .nsFont(.systemFont(ofSize: 12))
                .nsTextColor(NSColor(PaintedSurfaces.bodyText))
                .focused($focused)
                .frame(minHeight: minHeight)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(PaintedSurfaces.deepPage)
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

    /// Which of this day's cached assets predate the current design (#160, #286).
    ///
    /// #160 asked this of the collage alone. The reels and stills went through
    /// the same gallery redesign with no stamp, so a cached scroll reel or
    /// before/after from before it kept rendering the old look indefinitely, and
    /// the reels are the worst case: re-rendering one is expensive enough that
    /// nobody does it speculatively.
    ///
    /// Held in state and read on appear rather than checked in `body`, because
    /// it lists a directory and `body` runs on every redraw. The export screen
    /// took this shape for the same reason (#247); the first version of this row
    /// did not, which is a disk read per redraw for an answer that changes only
    /// when the day is regenerated.
    @State private var staleTemplates: [String] = []

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
        return (url, LayoutSidecar.url(for: url))
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

    /// The folder this day's cached assets live in.
    ///
    /// Taken from a preview path the run itself produced rather than rebuilt
    /// from the event and day, because the folder name is Python's to choose and
    /// a second derivation of it would break silently the first time it changed.
    private var dayFolder: URL? {
        guard let path = previewPaths?.values.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    /// Re-read the day's design stamp. Cheap, and only on the two events that
    /// can change the answer: arriving at the day, and finishing a regeneration
    /// of it.
    private func refreshDesignStaleness() {
        staleTemplates = dayFolder.map { DesignStamp.staleTemplates(in: $0) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Assets cached before the current design were rendered by the old
            // look, and will keep rendering it until this day is regenerated by
            // hand. Nothing surfaced that, so a redesign left old assets in
            // place indefinitely (#160 for the collage, #286 for the rest).
            //
            // Above the previews rather than beside one of them, because it can
            // now name several assets at once and the reels are the ones worth
            // saying it about: re-rendering a reel is expensive enough that
            // nobody does it speculatively, so a stale one survives longest.
            if let message = DesignStamp.staleMessage(for: staleTemplates), let onRegenerate {
                BrandBanner(
                    icon: "clock.arrow.circlepath",
                    message: message,
                    style: .warning,
                    actions: [BrandBannerAction(label: "Regenerate day",
                                                action: onRegenerate)]
                )
                .padding(.horizontal, Spacing.xl)
            }

            // Reel video (Tuesday speed edit / Thursday scroll)
            if !hideMainGraphic, let url = reelURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("REEL")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(PaintedSurfaces.secondaryText)
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
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    if isRegenerating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(PaintedSurfaces.iconAccent)
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
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                        Spacer()
                        Text("Drag photo to reposition · tap to select · drag borders to resize")
                            .font(.system(size: 9))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
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
                        .foregroundStyle(PaintedSurfaces.secondaryText)
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
                FadingScrollView(axis: .horizontal) {
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
                                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                                    .frame(width: 60, height: 80)
                                    .background(PaintedSurfaces.addTreatmentFill)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                                }
                                .buttonStyle(.plain)
                                .disabled(isRegenerating)
                            } else {
                                VStack(spacing: 6) {
                                    Button("Change") { onChangeBW() }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10))
                                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                                    Button("Remove") { onRemoveBW?() }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10))
                                        .foregroundStyle(PaintedSurfaces.secondaryText)
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
            } else if let fetched = postingDay.reelAudioSource {
                // The track a swap fetched, which is not `audioPath` (that only
                // ever holds a file Dan uploaded). Before #262 this was written
                // by Python, read by nobody, and the music in the reel had no
                // name anywhere on screen.
                ReviewMediaFileRow(
                    url: fetched, icon: "waveform",
                    label: postingDay.reelAudioTags.isEmpty
                        ? "Audio"
                        : "Audio (matched on \(postingDay.reelAudioTags))"
                )
                .padding(.horizontal, Spacing.xl)
            }
        }
        .padding(.bottom, Spacing.xs)
        .onAppear { refreshDesignStaleness() }
        // A finished regeneration rewrites the stamp with the current design,
        // so the badge has to go without leaving the screen. graphicVersion is
        // bumped by every completed render of this day.
        .onChange(of: graphicVersion) { _, _ in refreshDesignStaleness() }
        .onChange(of: isRegenerating) { _, running in
            if !running { refreshDesignStaleness() }
        }
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
                    ProgressView().controlSize(.small).tint(PaintedSurfaces.iconAccent)
                    Text("Working… \(seconds)s")
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
            case .stalled(let seconds):
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                    Text("Still working (\(seconds)s): this is taking longer than usual")
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
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
    /// Title card overlay (plan #148, Phase 3): on by default per event,
    /// toggled off here without re-invoking Claude.
    var titleCardMuted: Bool = false
    var onToggleTitleCard: (() -> Void)? = nil

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
private struct FridayClipCropPopover: View {
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
                            colors: [PaintedSurfaces.instagramRingWarm,
                                     PaintedSurfaces.instagramRingPink,
                                     PaintedSurfaces.instagramRingViolet],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().fill(PaintedSurfaces.instagramAvatarRing).padding(2)
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
                        .foregroundStyle(PaintedSurfaces.instagramInk)
                    Text("Original audio")
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.instagramSecondaryText)
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
                            .foregroundStyle(PaintedSurfaces.instagramGlyph)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Post options")
                    .help("Post options")
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.instagramGlyph)
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
                                    PaintedSurfaces.photoScrim
                                    VStack(spacing: 8) {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                            .controlSize(.large)
                                            .colorScheme(.dark)
                                        Text("Regenerating…")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(PaintedSurfaces.photoScrimText)
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
                                CarouselArrow(systemName: "chevron.left",
                                              label: "Previous photo") {
                                    carouselIndex -= 1
                                }
                                .padding(.leading, 8)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if isCarousel && carouselIndex < photoURLs.count - 1 {
                                CarouselArrow(systemName: "chevron.right",
                                              label: "Next photo") {
                                    carouselIndex += 1
                                }
                                .padding(.trailing, 8)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if isCarousel {
                                Text("\(carouselIndex + 1)/\(photoURLs.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(PaintedSurfaces.photoScrimText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(PaintedSurfaces.photoScrim)
                                    )
                                    .padding(8)
                            }
                        }
                } else if displayedPhotoURL != nil {
                    PaintedSurfaces.instagramPlaceholder
                        .frame(width: cardWidth, height: cardWidth)
                        .overlay { ProgressView().controlSize(.small) }
                } else {
                    PaintedSurfaces.instagramPlaceholder
                        .frame(width: cardWidth, height: cardWidth)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 28))
                                .foregroundStyle(PaintedSurfaces.instagramPlaceholderMark)
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
            .foregroundStyle(PaintedSurfaces.instagramInk)
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 6)

            // ── Likes ────────────────────────────────────────────────────────
            Text("1,021 likes")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PaintedSurfaces.instagramInk)
                .padding(.horizontal, 11)
                .padding(.bottom, 5)

            // ── Caption + hashtags ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                if caption.isEmpty && hashtagLine.isEmpty {
                    Text("Caption will appear here…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PaintedSurfaces.instagramCaptionPlaceholder)
                        .italic()
                } else {
                    if !caption.isEmpty {
                        (Text("dwphotony ").font(.system(size: 12.5, weight: .semibold))
                         + Text(caption).font(.system(size: 12.5)))
                            .foregroundStyle(PaintedSurfaces.instagramInk)
                            .lineLimit(4)
                    }
                    if !hashtagLine.isEmpty {
                        Text(hashtagLine)
                            .font(.system(size: 12))
                            .foregroundStyle(PaintedSurfaces.instagramLink)
                            .lineLimit(2)
                    }
                }

                // View all comments
                Text("View all comments")
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.instagramCommentsLine)

                // Timestamp
                Text(dayLabel.uppercased())
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(PaintedSurfaces.instagramDate)
                    .kerning(0.3)
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 12)
        }
        .frame(width: cardWidth)
        .background(PaintedSurfaces.instagramCard)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(PaintedSurfaces.instagramCardEdge, lineWidth: 0.5)
        )
        .shadow(color: PaintedSurfaces.instagramCardShadow, radius: 8, x: 0, y: 2)
        .task(id: displayedPhotoURL) {
            guard let url = displayedPhotoURL else { return }
            // Keep the previous image on screen while loading the next so
            // carousel swaps don't flash a placeholder (and don't reflow the
            // left column via a transient square frame).
            if let loaded = await ImageLoad.read(url).image {
                photo = loaded
            }
        }
    }
}

private struct CarouselArrow: View {
    let systemName: String
    /// What pressing it does, said as a person would: "Previous photo". An
    /// arrow glyph with no name is announced as nothing but "button" (#465).
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PaintedSurfaces.instagramGlyph)
                .frame(width: 26, height: 26)
                .background(Circle().fill(PaintedSurfaces.instagramOverlayButton))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
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
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Spacer()
                if let onChooseOverride {
                    Button(action: onChooseOverride) {
                        Text("Choose a different photo…")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
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
                    .foregroundStyle(PaintedSurfaces.secondaryText)
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
    @State private var load: ImageLoad = .loading

    private var resolvedMaxHeight: CGFloat {
        maxHeight ?? max(440, (NSScreen.main?.visibleFrame.height ?? 800) * 0.82)
    }

    var body: some View {
        Group {
            load.thumbnail(iconSize: 22, labelSize: 11)
        }
        .aspectRatio(9/16, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: resolvedMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 0.5)
        )
        // Dim + spinner while regenerating
        .overlay {
            if isRegenerating {
                ZStack {
                    PaintedSurfaces.photoScrim
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(PaintedSurfaces.photoScrimText)
                        Text("Regenerating…")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(PaintedSurfaces.photoScrimText)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { NSWorkspace.shared.open(url) } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 13))
                    .foregroundStyle(PaintedSurfaces.photoScrimIcon)
                    .padding(8)
                    .background(PaintedSurfaces.photoScrim)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the graphic at full size")
            .help("Open the graphic at full size")
            .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            if let onRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(PaintedSurfaces.photoScrimIcon)
                        .padding(8)
                        .background(PaintedSurfaces.photoScrim)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate the graphic")
                .disabled(isRegenerating)
                .help("Regenerate this graphic")
                .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isRegenerating { onPreview() } }
        .task { load = await ImageLoad.read(url) }
    }
}

private struct ReviewThumb: View {
    let url: URL
    let onTap: () -> Void
    @State private var load: ImageLoad = .loading

    var body: some View {
        Group {
            load.thumbnail()
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task { load = await ImageLoad.read(url) }
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
            async let bytes = ImageLoad.bytes(url)
            async let decoded = Task.detached {
                (try? JSONDecoder().decode(ReelStripLayout.self, from: Data(contentsOf: layoutURL)))
            }.value
            let (loadedBytes, layout) = await (bytes, decoded)
            let loadedImage = loadedBytes.flatMap { NSImage(data: $0) }
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
                    async let bytes = ImageLoad.bytes(url)
                    async let decoded = Task.detached {
                        (try? JSONDecoder().decode(ReelStripLayout.self, from: Data(contentsOf: layoutURL)))
                    }.value
                    let (loadedBytes, layout) = await (bytes, decoded)
                    let loadedImage = loadedBytes.flatMap { NSImage(data: $0) }
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
                            .fill(PaintedSurfaces.dropTargetFill)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isMoved && !isSelected && !isDragging && !isDragTarget {
                        Circle().fill(PaintedSurfaces.dropTargetMarker).frame(width: 7, height: 7).padding(4)
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
            photo = await ImageLoad.read(photoURL).image
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
                    .foregroundStyle(PaintedSurfaces.dragHandleIcon)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isDragging ? PaintedSurfaces.dragHandleActiveFill : PaintedSurfaces.dragHandleFill)
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
                .foregroundStyle(PaintedSurfaces.secondaryText)
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
                .foregroundStyle(PaintedSurfaces.iconAccent)
            Text(label)
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(PaintedSurfaces.pageAccentText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(PaintedSurfaces.deepPage)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Learning suggestion sheet

private struct LearningSuggestionSheet: View {
    let suggestion: String
    /// Returns nil when the note was written, or what to say when it was not.
    /// The sheet stays open on a failure, because the text it holds is the only
    /// copy of what Dan typed (#462).
    let onSave: (String) -> String?
    let onSkip: () -> Void

    @State private var editedSuggestion: String
    @State private var saveError: String?

    init(suggestion: String, onSave: @escaping (String) -> String?, onSkip: @escaping () -> Void) {
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
                    .foregroundStyle(PaintedSurfaces.pageAccentText)

                Text("Based on how you revised these captions, there may be something worth adding to your brand voice. Edit the wording below before saving if you want to refine it:")
                    .font(.light(12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SpellCheckingTextEditor(text: $editedSuggestion)
                .nsFont(.systemFont(ofSize: 13))
                .nsTextColor(NSColor(PaintedSurfaces.bodyText))
                .padding(Spacing.sm)
                .frame(minHeight: 120, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(PaintedSurfaces.noteFieldFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md)
                                .strokeBorder(PaintedSurfaces.accentBorder.opacity(0.2), lineWidth: 1)
                        )
                )

            Text("Adding this will apply to all future caption generation.")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)

            if let saveError {
                Text(saveError)
                    .font(.system(size: 11))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.md) {
                Button("Add to brand voice") { saveError = onSave(trimmed) }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(trimmed.isEmpty)
                Button("Reset") { editedSuggestion = suggestion }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .disabled(editedSuggestion == suggestion)
                Spacer()
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .background(PaintedSurfaces.page)
    }
}

// MARK: - Full-screen photo overlay

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
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Assign the RAW and Edited photos to generate a speed-edit reel.")
                .font(.light(12))
                .foregroundStyle(PaintedSurfaces.secondaryText)

            HStack(alignment: .top, spacing: Spacing.md) {
                photoSlot(label: "RAW (unedited)", url: rawPhoto, action: onPickRaw)
                photoSlot(label: "Edited", url: editedPhoto, action: onPickEdited)
                VStack(spacing: Spacing.xs) {
                    photoSlot(label: "B&W (optional)", url: bwPhoto, action: onPickBW)
                    if bwPhoto != nil {
                        Button("Remove") { onClearBW() }
                            .buttonStyle(.plain)
                            .font(.system(size: 9))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                    }
                }
            }

            if bwPhoto != nil {
                Text("3-photo post: reel reveals color over B&W, Friday shows all three.")
                    .font(.light(10))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                    .multilineTextAlignment(.center)
            }

            if hasAll {
                if isRegenerating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PaintedSurfaces.iconAccent)
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
                        .fill(PaintedSurfaces.addTreatmentFill)
                        .frame(width: 120, height: 80)
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
                                Text("Choose")
                                    .font(.system(size: 10))
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
                            }
                        }
                }
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PaintedSurfaces.secondaryText)
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
                    .foregroundStyle(PaintedSurfaces.bodyText)
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
            }
            .padding(Spacing.lg)

            Divider()

            if isLoading {
                VStack(spacing: Spacing.md) {
                    ProgressView().controlSize(.large).tint(PaintedSurfaces.iconAccent)
                    Text("Rendering layout options…")
                        .font(.system(size: 12))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
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
        .background(PaintedSurfaces.page)
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
                        .stroke(PaintedSurfaces.treatmentTileBorder, lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(PaintedSurfaces.imagePlaceholderFill)
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
