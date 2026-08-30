import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers

struct CaptionReviewView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(HashtagStore.self) private var hashtagStore

    /// The two shared stores this screen reads while it DRAWS (#937).
    ///
    /// Injected so the screen can be rendered for review. `AccountBook` holds
    /// real follower counts for real accounts and this screen both reads and
    /// records into it, so drawing it reached Dan's numbers (L2, L222).
    /// `PreviewGraphicsManager` is in memory, and shared state a run before
    /// could have left something in (L205).
    ///
    /// Deliberately NOT seamed here: `PythonBridge` and `NotificationService`.
    /// Every use of those is inside an async action, which no render runs, and
    /// neither is a store this screen READS to decide what to draw. Naming the
    /// line rather than leaving it to be inferred (L129).
    let accounts: AccountBook
    let previews: PreviewGraphicsManager

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
    @State private var showRegenerateConfirm = false
    /// Why this screen refused what was just asked: a file that would not copy
    /// into app storage, a photo selection too small to build a collage from, or
    /// a day already rebuilding (#728). View state, and rightly: each is decided
    /// synchronously, before the next redraw, and none of it outlives a glance
    /// because the action never started.
    ///
    /// Nothing that goes across to Python writes here any more. Those runs are
    /// owned by `captionWork` (#718) and `graphics` (#721), because they outlive
    /// this screen, and so must whatever they have to say about a failure: five
    /// of them shared one field here, so whichever failed last erased the
    /// reason before it, and one that failed after an event switch left nothing
    /// at all (L53, L148).
    @State private var refusedAction: String?
    /// A rebuild refused because that day was already rebuilding (#728).
    ///
    /// Its own field rather than sharing `refusedAction`, for the reason the
    /// per-day failures got their own rows in #721: these two are cleared by
    /// different things. This one stops being true the moment that day is free,
    /// so a granted rebuild takes it away. The other is about a file that would
    /// not copy or a set of photos too small to lay out, which a rebuild
    /// starting says nothing about, and clearing it on a grant destroyed the
    /// half of a partly failed batch that nothing else reports: importing five
    /// clips where two fail to copy records that and then rebuilds with the
    /// three that landed (L47).
    ///
    /// A second String rather than one field carrying its own kind, so both
    /// stay the shape `LongWorkOwnershipTests` looks for: it finds a screen's
    /// message state by TYPE, and a struct here would put both of these outside
    /// the rule that stops a long run's failure being written into view state.
    @State private var refusedRebuild: String?

    /// Owns the whole-week regeneration, so neither the run nor what it has to
    /// say about a halt dies with this screen (#718).
    @Environment(CaptionWorkManager.self) private var captionWork

    private var isRegenerating: Bool {
        captionWork.isRunning(event.id, .regenerateWeek)
    }
    /// The banner from a week run that stopped early.
    ///
    /// The last refused action used to share this, with the run's outcome
    /// winning, on the reasoning that the run is the one that costs money to
    /// rediscover. That is true and it made every refusal AFTERWARDS silent, so
    /// a control that declined looked broken and pressing it again was the only
    /// diagnosis available (#731, L148). They are independent things and get a
    /// row each.
    private var weekRunFailure: String? {
        captionWork.outcome(for: event.id, .regenerateWeek)?.failure
    }

    /// Claim a day's rebuild slot BEFORE anything is written for it, or refuse.
    ///
    /// `beginDayRegen` answers whether that day is already rebuilding, and two
    /// runs are two subprocesses writing one MP4. Four of the five callers on
    /// this screen used to throw the answer away (#728). Honouring it after the
    /// write would be no better: the event would carry new photos, a fresh seed
    /// or a cleared audio track with nothing rendered to match, which is a reel
    /// that silently disagrees with the screen. So the claim comes first and the
    /// write happens only once it is granted.
    ///
    /// `days` is a list because two actions rebuild Tuesday and Friday from one
    /// shared write, and the manager claims those together or not at all.
    ///
    /// A refusal says which day is busy rather than doing nothing visible: a
    /// control that silently declines leaves pressing it again as the only
    /// diagnosis available (L148).
    @discardableResult
    private func claimRebuild(_ days: [DayName],
                              writing change: (inout Event) -> Void = { _ in }) -> Bool {
        guard graphics.beginDayRegen(days, for: event.id) else {
            let busy = graphics.regeneratingDays(event.id)
            refusedRebuild = DayRebuildRefusal.message(for: days.filter { busy.contains($0) })
            return false
        }
        // A day that was busy is not busy any more, so the refusal that said so
        // is taken away: set on the branch above, cleared here, in the one funnel
        // every rebuild goes through. Which of the two slots that means is
        // decided by DayRebuildRefusal, where it can be asserted, rather than
        // here where the first version of it was wrong and untestable.
        (refusedAction, refusedRebuild) = DayRebuildRefusal.afterRebuildGranted(
            action: refusedAction, rebuild: refusedRebuild)
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        change(&ev)
        appState.updateEvent(ev)
        return true
    }

    /// What the per-day rebuilds and cover rebuilds have left to say, each on
    /// its own row so none can erase another (#721). Read from the manager that
    /// owns those runs, so a failure that arrived while Dan was elsewhere is
    /// still here when he comes back.
    private var dayRebuildNotices: [CaptionReviewDayNotice] {
        graphics.dayFailures(for: event.id).map {
            CaptionReviewDayNotice(id: $0.day.rawValue, message: $0.reason)
        }
    }

    private var coverRebuildNotices: [CaptionReviewDayNotice] {
        graphics.coverFailures(for: event.id).map {
            CaptionReviewDayNotice(id: $0.day.rawValue, message: $0.reason)
        }
    }

    enum ReviewSection: Equatable {
        case caption(DayName)
        case blog
    }

    init(event: Event,
         accounts: AccountBook = .shared,
         previews: PreviewGraphicsManager = .shared) {
        self.event = event
        self.accounts = accounts
        self.previews = previews
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

    // Learning flow. The PASS belongs to `captionWork` (#718): it is a paid
    // Claude call, and its three outcomes used to live here, so pressing "Looks
    // good" and then clicking another event lost the answer entirely, week
    // unadvanced and nothing said.
    //
    // What stays here is what the screen does with the answer, because two of
    // the three are a sheet and an alert.
    @State private var learningSuggestion: String? = nil
    @State private var showLearnSheet = false
    /// Set when the learn-from-edits pass could not be run at all (#526). Its
    /// own field rather than a shared one, so a failed review cannot be read as
    /// a failed export or erase some other notice (L53).
    @State private var learningFailure: String? = nil

    private var isAnalyzingEdits: Bool {
        captionWork.isRunning(event.id, .learnFromEdits)
    }

    // Preview graphics generation
    // Preview-graphic runs are owned by PreviewGraphicsManager, not this view:
    // EventDetailView remounts the screen via .id(event.id) on every event
    // switch, which used to discard this state while the Task kept running, so
    // coming back auto-started a second writer and showed no progress (#75).
    private var graphics: PreviewGraphicsManager { previews }
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

                    // Above the day list (#1007). This screen shows what the
                    // layout produced, day by day, and could not change it: the
                    // control was on the Export screen only, which is past the
                    // point where the result is being read.
                    PostingLayoutControl(event: event, defaults: AppPreferences.store, previews: previews)
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
                            onRevise: { feedback, saveNote in
                                captionWork.startRevisingCaption(
                                    eventID: event.id, day: day, feedback: feedback,
                                    saveToBrandVoice: saveNote, appState: appState)
                            },
                            isRevising: captionWork.isRunning(event.id, .reviseCaption(day)),
                            revisionError: revision(day)?.failure,
                            brandVoiceError: revision(day)?.noteFailure,
                            undoCaption: revision(day)?.previousCaption,
                            onUndoRevision: { undoRevision(day: day) },
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
                            fridayFailure: day == .friday
                                ? graphics.dayFailure(.friday, for: event.id) : nil,
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
                                        refusedAction = ImportFailureText.message([error])
                                    }
                                }
                            } : nil
                        )
                        .disabled(isRegenerating)
                        // Take up the caption a revision wrote underneath this
                        // screen (#718). One day, because Dan is very often
                        // editing another while it runs and the whole draft
                        // would take those edits with it.
                        .onChange(of: captionWork.isRunning(event.id, .reviseCaption(day))) {
                            adoptRevisedDay(day)
                        }

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
                            onRevise: { feedback, saveNote in
                                captionWork.startRevisingBlog(
                                    eventID: event.id, feedback: feedback,
                                    saveToBrandVoice: saveNote, appState: appState)
                            },
                            onSwapPhotos: { urls in
                                captionWork.startSwappingBlogPhotos(
                                    eventID: event.id, urls: urls, appState: appState)
                            },
                            isRevising: captionWork.isRunning(event.id, .reviseBlog),
                            revisionError: blogRevision?.failure,
                            brandVoiceError: blogRevision?.noteFailure,
                            isSwappingPhotos: captionWork.isRunning(event.id, .swapBlogPhotos),
                            photoSwapError: photoSwap?.failure,
                            undoBlog: blogRevision?.previousBlog ?? photoSwap?.previousBlog,
                            onUndoBlogChange: { undoBlogChange() }
                        )
                        // Take up whatever a blog run wrote underneath this
                        // screen (#718).
                        .onChange(of: captionWork.isRunning(event.id, .reviseBlog)) {
                            adoptStoredBlog()
                        }
                        .onChange(of: captionWork.isRunning(event.id, .swapBlogPhotos)) {
                            adoptStoredBlog()
                        }
                        .disabled(isRegenerating)
                    }

                // Every notice this screen shows below the content, in its own
                // view taking plain values, so the days that need a moved file or
                // a dead run to reach can be rendered and measured (#396).
                CaptionReviewNotices(
                    regenerateError: weekRunFailure,
                    refusal: refusedAction,
                    rebuildRefusal: refusedRebuild,
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
                    },
                    dayRebuildFailures: dayRebuildNotices,
                    coverRebuildFailures: coverRebuildNotices,
                    onDismissRefusal: { refusedAction = nil },
                    onDismissRebuildRefusal: { refusedRebuild = nil },
                    onDismissDayFailure: { day in
                        graphics.clearDayFailure(day, for: event.id)
                    },
                    onDismissCoverFailure: { day in
                        graphics.clearCoverFailure(day, for: event.id)
                    }
                )
                .padding(.horizontal, Spacing.xl)

                if isRegenerating {
                    // Names the day or blog pass the run is actually on, so a
                    // process that died is distinguishable from one that is
                    // three minutes into a Claude call (#95, #96).
                    LongRunIndicator(label: "Regenerating captions…",
                                     startedAt: captionWork.startedAt(event.id, .regenerateWeek),
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
                                     startedAt: captionWork.startedAt(event.id, .learnFromEdits))
                        .padding(Spacing.xl)
                } else {
                    actionBar(.ready(graphicsError: graphics.failure(for: event.id)))
                }
            }
            }
            .background(PaintedSurfaces.page)
            .onAppear {
                mergeGlobalTags()
                // A pass that finished while Dan was on another screen still
                // has an answer waiting (#718).
                learningSettled()
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
            // Take up the week a regeneration wrote underneath this screen
            // (#718). The draft here is written OUT on every edit and only
            // reloaded when a different event is selected, so nothing brought a
            // change to the stored week back IN. Without this the run saved
            // three to six paid minutes of output, the screen went on showing
            // the older draft so the run looked as though it had done nothing,
            // and the next keystroke persisted that draft back over it. That is
            // #518 on the programme screen, where it did not merely read as a
            // failed save, it became one.
            .onChange(of: captionWork.isRunning(event.id, .regenerateWeek)) {
                adoptStoredWeekIfNeeded()
            }
            .onChange(of: captionWork.isRunning(event.id, .learnFromEdits)) {
                learningSettled()
            }
            .alert("Regenerate all captions?", isPresented: $showRegenerateConfirm) {
                Button("Regenerate", role: .destructive) {
                    regenerateAll()
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
                stats: accounts.stats(for: target.handle),
                onSave: { followers, likes, comments in
                    accounts.record(handle: target.handle, followers: followers,
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

    // MARK: - Global hashtag merge

    /// Fold the tags that go on every post into the draft when the screen
    /// opens.
    ///
    /// Through `GlobalTagMerge`, the same decision `CaptionWorkManager` applies
    /// to a freshly generated week, so an existing week and a regenerated one
    /// cannot end up with different tags (L41).
    private func mergeGlobalTags() {
        var week = result
        guard GlobalTagMerge.apply(hashtagStore.globalTags, to: &week,
                                   for: liveEvent) else { return }
        result = week
        save()
    }

    // MARK: - Revisions

    private func revision(_ day: DayName) -> CaptionWorkManager.Outcome? {
        captionWork.outcome(for: event.id, .reviseCaption(day))
    }

    /// Bring a revised day into the draft this screen shows.
    ///
    /// One day, not the week: Dan is very often editing another day while a
    /// revision runs, and replacing the whole draft would take those edits with
    /// it. That is why the manager writes one day too.
    private func adoptRevisedDay(_ day: DayName) {
        guard let stored = liveEvent.weekResult?[day], stored != result[day] else { return }
        result[day] = stored
    }

    /// Put back the caption as it stood before the last revision.
    ///
    /// Written to the STORED event rather than through the day's binding: the
    /// revision it undoes was written there too, and an undo that only changed
    /// the draft would be reversed by the next thing that read the store (L14).
    private func undoRevision(day: DayName) {
        guard let previous = revision(day)?.previousCaption else { return }
        guard var live = appState.events.first(where: { $0.id == event.id }),
              var week = live.weekResult else { return }
        week[day] = previous
        live.weekResult = week
        appState.updateEvent(live)
        result[day] = previous
        // The offer goes with it, so Restore cannot be pressed twice and put
        // back a caption that is already there.
        captionWork.clearOutcome(for: event.id, .reviseCaption(day))
    }

    // MARK: - The blog's two runs

    private var blogRevision: CaptionWorkManager.Outcome? {
        captionWork.outcome(for: event.id, .reviseBlog)
    }
    private var photoSwap: CaptionWorkManager.Outcome? {
        captionWork.outcome(for: event.id, .swapBlogPhotos)
    }

    private func adoptStoredBlog() {
        guard let stored = liveEvent.weekResult?.blog, stored != result.blog else { return }
        result.blog = stored
    }

    /// Put back the blog as it stood before the last revision or photo swap.
    ///
    /// Written to the STORED event, because that is where the change it undoes
    /// was written; an undo that only changed the draft would be reversed by
    /// the next read (L14). Whichever of the two ran most recently is the one
    /// with an outcome, so there is one Restore rather than two competing ones.
    private func undoBlogChange() {
        let job: CaptionWorkManager.Job = blogRevision?.previousBlog != nil
            ? .reviseBlog : .swapBlogPhotos
        guard let previous = captionWork.outcome(for: event.id, job)?.previousBlog
        else { return }
        guard var live = appState.events.first(where: { $0.id == event.id }),
              var week = live.weekResult else { return }
        week.blog = previous
        live.weekResult = week
        appState.updateEvent(live)
        result.blog = previous
        captionWork.clearOutcome(for: event.id, job)
    }

    private func regenerateAll() {
        // Handed over and let go of. This screen is `.id(event.id)` tagged, so
        // it is destroyed on every event switch, and it used to be holding the
        // only copy of the run's progress and of the banner a halted run leaves
        // behind (#718, #262).
        captionWork.startRegeneratingWeek(eventID: event.id, appState: appState,
                                          globalHashtags: hashtagStore.globalTags)
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
        //
        // Computed here and written only once the day is claimed (#728). The
        // clear used to be persisted first, so a swap refused because Tuesday
        // was already rebuilding left the reel with no audio and no run to fetch
        // any.
        let live = appState.events.first(where: { $0.id == event.id }) ?? event
        let (cleared, previousAudio) = ReelAudioSwap.clearingAudio(in: live, day: day)
        guard claimRebuild([day], writing: { $0 = cleared }) else { return }
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
                    graphics.failDayRegen(
                        day, for: event.id,
                        reason: "\(day.displayName) audio swap failed: "
                              + "\(error.localizedDescription)")
                }
            }
        }
    }

    /// Set the Thursday scroll reel length and re-render it. The number of
    /// frames depends on `scrollDuration`, so a full regenerate is required
    /// (regenerateGraphic reads the updated value from the live event).
    private func changeReelLength(day: DayName, to seconds: Double) {
        let live = appState.events.first(where: { $0.id == event.id }) ?? event
        guard live.days[day.rawValue]?.scrollDuration != seconds else { return }
        regenerateGraphic(day: day) { ev in
            var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
            pd.scrollDuration = seconds
            ev.days[day.rawValue] = pd
        }
    }

    /// Copies one picked file into app storage, or reports the failure and
    /// returns nil. Every picker on this screen goes through it: a path outside
    /// app storage loses read access on the next launch and dies outright if the
    /// user renames the folder (#77, #145), and silently persisting it on a
    /// failed copy is what made that invisible (#179).
    private func storedPick(_ url: URL) -> URL? {
        let outcome = ImportedPicks.copy([url])
        if let message = outcome.failureMessage { refusedAction = message }
        return outcome.stored.first
    }

    /// Batch form of `storedPick`: keeps what copied, reports what didn't.
    private func storedPicks(_ urls: [URL]) -> [URL] {
        let outcome = ImportedPicks.copy(urls)
        if let message = outcome.failureMessage { refusedAction = message }
        return outcome.stored
    }

    private func uploadReelAudio(day: DayName, url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        // Copy to a stable location: this path is persisted on the event and
        // reused by later regenerations, so it cannot live in the temp
        // directory (macOS purges it). Fail loudly if the copy fails; the
        // persisted path is only valid when the copy succeeded.
        // Claimed before the copy, so a refused upload leaves nothing behind:
        // no orphan file in app storage and no audio path pointing at one
        // (#728).
        guard claimRebuild([day]) else { return }

        let dir = AppPaths.audioDir
        let dest = dir.appendingPathComponent("upload_\(UUID().uuidString)_\(url.lastPathComponent)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            // Release the slot that was claimed for a run now not happening.
            // Holding it would leave this day unable to rebuild ever again.
            graphics.endDayRegen(day, for: event.id)
            refusedAction = "Couldn't copy the audio file: \(error.localizedDescription)"
            return
        }

        // Persist the audio path on the event so regeneration reuses it. After
        // the claim, so the path and the run that renders it arrive together.
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
        pd.audioPath = dest
        ev.days[day.rawValue] = pd
        appState.updateEvent(ev)

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
                    graphics.failDayRegen(
                        day, for: event.id,
                        reason: "\(day.displayName) audio upload failed: "
                              + "\(error.localizedDescription)")
                }
            }
        }
    }

    private func assignReelPhotosAndGenerate(raw: URL, edited: URL, bw: URL?) {
        // Save the RAW + Edited photos to the event model for Tuesday (and Friday).
        // `bw` is the optional B&W after; when set it flips both the Tuesday reel
        // and the Friday graphic into the 3-photo treatment. When nil it clears
        // any previously assigned B&W.
        // One write covering two days, so both are claimed together or neither
        // is: Friday carrying the new photos with the old graphic still rendered
        // is exactly the half-landed state to avoid (#728).
        guard claimRebuild([.tuesday, .friday], writing: { ev in
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
        }) else { return }

        // Now generate the reel for Tuesday and the Friday before/after story.
        // Both slots are already claimed, so these render rather than claim
        // again, which would refuse its own caller.
        renderClaimedDay(.tuesday)
        renderClaimedDay(.friday)
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
            regenerateGraphic(day: .thursday) { ev in
                var thu = ev.days[DayName.thursday.rawValue] ?? PostingDay(day: .thursday)
                thu.photoPaths = picks.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
                ev.days[DayName.thursday.rawValue] = thu
            }
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
        if !failures.isEmpty { refusedAction = ImportFailureText.message(failures) }
        // Every pick failed to copy: nothing was imported, so don't kick off a
        // render that would produce the same reel as before (#179).
        guard !copied.isEmpty else { return }

        regenerateGraphic(day: .friday) { ev in
            let fri = ev.days[DayName.friday.rawValue] ?? PostingDay(day: .friday)
            ev.days[DayName.friday.rawValue] = fri.addingClips(copied)
        }
    }

    /// Reorder/include-exclude edit to the Friday clip selection (#135).
    /// Writes only to fridayClipOverride and re-renders locally via
    /// render_friday_override.py - never re-invokes Claude
    /// (feedback_collage_edits_no_python_regen).
    /// `togglingTitleCard` folds the mute into the same claimed write. It used
    /// to be persisted by the caller first, so a toggle refused because Friday
    /// was already rebuilding left the card muted with the unmuted reel still on
    /// screen (#728).
    private func applyFridayOverride(_ override: [ReelClipOverride],
                                    togglingTitleCard: Bool = false) {
        guard claimRebuild([.friday], writing: { ev in
            if togglingTitleCard {
                ev.days[DayName.friday.rawValue]?.titleCardMuted.toggle()
            }
            ev.days[DayName.friday.rawValue]?.fridayClipOverride = override
        }) else { return }
        Task {
            do {
                let liveEvent = appState.events.first(where: { $0.id == event.id }) ?? event
                let render = try await PythonBridge.shared.runRenderFridayOverride(event: liveEvent)
                await MainActor.run {
                    guard let render else {
                        graphics.failDayRegen(
                            .friday, for: event.id,
                            reason: "Friday reel edit couldn't be applied: no reel to update")
                        return
                    }
                    graphics.endDayRegen(.friday, for: event.id)
                    // A reel that came back with no title says so here (#824).
                    // Passed even when nil, which is what clears the note from
                    // the last render: a warning that outlives the thing it was
                    // about is worse than none, because it is now false.
                    recordMediaOutcome(day: .friday, error: nil,
                                       warning: render.titleCardSkipped)
                    var current = appState.events.first(where: { $0.id == event.id }) ?? liveEvent
                    var paths = current.previewMediaPaths[DayName.friday.rawValue] ?? [:]
                    paths["reel"] = render.reelPath
                    current.previewMediaPaths[DayName.friday.rawValue] = paths
                    appState.updateEvent(current)
                    graphicVersions[.friday] = (graphicVersions[.friday] ?? 0) + 1
                }
            } catch {
                await MainActor.run {
                    graphics.failDayRegen(
                        .friday, for: event.id,
                        reason: "Friday reel edit failed: \(error.localizedDescription)")
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
        let live = appState.events.first(where: { $0.id == event.id }) ?? event
        guard let fri = live.days[DayName.friday.rawValue] else { return }
        applyFridayOverride(fri.effectiveFridayOverride, togglingTitleCard: true)
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
            refusedAction = ImportFailureText.message([error])
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
        regenerateGraphic(day: .friday) { ev in
            ev.days[DayName.friday.rawValue]?.fridayClipOverride = nil
        }
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
        // The banner this answers is Friday's own rebuild failure, which now
        // lives with the run that produced it (#721).
        graphics.clearDayFailure(.friday, for: event.id)
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
            refusedAction = message
            return
        }

        let picks = storedPicks(panel.urls)
        guard !picks.isEmpty else { return }
        guard regenerateGraphic(day: day, persisting: { ev in
            var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
            pd.photoPaths = picks.sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending
            }
            // Crop offsets and the cell layout are keyed to the old photo paths,
            // so discard them for a clean rebuild from the new set.
            pd.collageCropOffsets = [:]
            pd.collageCellOverride = nil
            ev.days[day.rawValue] = pd
        }) else { return }

        // Keep the in-memory editor state in sync so the live overlay doesn't
        // reference photos that no longer exist. Only once the rebuild is
        // actually going: clearing it for a refused rebuild would drop Dan's
        // crops while the old photos stay on the event (#728).
        dayCollageCropOffsets[day.rawValue] = [:]
        dayCollageCellOverrides.removeValue(forKey: day.rawValue)
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
                                 stats: { accounts.stats(for: $0) },
                                 asOf: suggestionsAsOf,
                                 notes: [accounts.recoveryNote].compactMap { $0 })
    }

    private func applyCollageLayout(day: DayName, seed: Int) {
        guard regenerateGraphic(day: day, persisting: { ev in
            var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
            pd.collageSeed = seed
            pd.collageCellOverride = nil
            ev.days[day.rawValue] = pd
        }) else { return }
        dayCollageCellOverrides.removeValue(forKey: day.rawValue)
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

    /// Claim the day, persist what the rebuild is for, and render it.
    ///
    /// `persisting` carries the caller's own write: the new photos, the new clip
    /// list, the new reel length. It used to be persisted by the caller BEFORE
    /// this was called, so a rebuild refused because that day was already
    /// running left the event describing a graphic nobody was making (#728).
    /// Nothing here writes until the claim is granted.
    ///
    /// Returns false when the day was refused, so a caller with in-memory state
    /// to keep in step knows not to.
    @discardableResult
    private func regenerateGraphic(day: DayName, newLayout: Bool = false,
                                   persisting change: (inout Event) -> Void = { _ in }) -> Bool {
        // Always read the CURRENT event from AppState — not self.event.
        // self.event is captured by value in the closure that calls this function and
        // may be stale (pre-save snapshot). appState is a reference type so .events
        // always reflects the latest write from save().
        guard appState.events.contains(where: { $0.id == event.id }) else { return false }

        guard claimRebuild([day], writing: { ev in
            change(&ev)
            // For a collage day, lock the collage seed before the first regen so
            // Python always produces the same grid layout when only crop offsets
            // change. When `newLayout` is true, force a fresh seed regardless.
            if isCollageDay(day), newLayout || ev.days[day.rawValue]?.collageSeed == nil {
                var pd = ev.days[day.rawValue] ?? PostingDay(day: day)
                pd.collageSeed = Int.random(in: 1...999_999_999)
                // Drop any per-cell overrides: they are keyed to the previous layout.
                pd.collageCellOverride = nil
                ev.days[day.rawValue] = pd
            }
            if day == .thursday, newLayout {
                var pd = ev.days[DayName.thursday.rawValue] ?? PostingDay(day: .thursday)
                pd.reelSeed = Int.random(in: 1...999_999_999)
                ev.days[DayName.thursday.rawValue] = pd
            }
        }) else { return false }

        renderClaimedDay(day, newLayout: newLayout)
        return true
    }

    /// Render a day whose slot is ALREADY claimed.
    ///
    /// Split from the claim because two actions claim Tuesday and Friday
    /// together and then render both, and a second claim in here would refuse
    /// its own caller.
    private func renderClaimedDay(_ day: DayName, newLayout: Bool = false) {
        let eventSnapshot = appState.events.first(where: { $0.id == event.id }) ?? event
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
                switch outcome {
                case .failure(let error):
                    graphics.failDayRegen(
                        day, for: event.id,
                        reason: "\(day.displayName) regeneration failed: "
                              + "\(error.localizedDescription)")
                case .success(let result):
                    graphics.endDayRegen(day, for: event.id)
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
            // The pipeline's own text, not a sentence wrapped around it: the
            // marker it uses for the cases with a remedy has to survive to the
            // card that offers one (#730). The manager builds the wording.
            graphics.failDayRegen(day, for: event.id, pipelineError: pyError)
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
            graphics.failDayRegen(
                day, for: event.id,
                reason: "\(day.displayName) regeneration produced no output")
        }
    }

    /// Record (or clear) a day's graphics failure on the live event, so the asset
    /// screen's failure list reflects the latest attempt from either screen.
    @MainActor
    private func recordMediaOutcome(day: DayName, error: String?, warning: String? = nil) {
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        // The recording itself is on the model (#824), so the rule that a note
        // is CLEARED when the next render has nothing to say is one rule rather
        // than one per screen. Recorded alongside the error rather than folded
        // into it: a day that rendered without an optional photo used to report
        // as a failed regeneration, which was simply untrue (#265).
        guard ev.recordMediaOutcome(day: day.rawValue, error: error, warning: warning)
        else { return }
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
                switch outcome {
                case .failure(let error):
                    graphics.failCoverRegen(
                        day, for: event.id,
                        reason: "\(day.displayName) cover regeneration failed: "
                              + "\(error.localizedDescription)")
                case .success(let result):
                    graphics.endCoverRegen(day, for: event.id)
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

    // MARK: - Persistence

    /// Persist on a pause in typing rather than on every keystroke.
    ///
    /// The in-memory event is updated immediately either way, so nothing reads
    /// stale text; only the whole-store serialisation waits (#91, #197).
    private func saveDebounced() {
        guard !captionWork.isRunning(event.id, .regenerateWeek) else { return }
        appState.updateEventDebounced(mergedEvent())
    }

    private func save() {
        // Never while a regeneration is in flight. The draft on screen predates
        // the week that run is about to write, so persisting it now would put
        // the older captions back over three to six paid minutes of output
        // (#718, the same rule as #518 on the programme screen).
        guard !captionWork.isRunning(event.id, .regenerateWeek) else { return }
        appState.updateEvent(mergedEvent())
    }

    /// Bring a week written underneath this screen into the draft it shows.
    ///
    /// The decision is `DraftRefresh`, shared with the programme review screen,
    /// so the rule and this call site cannot disagree about when it is safe.
    private func adoptStoredWeekIfNeeded() {
        let live = liveEvent
        guard DraftRefresh.shouldAdopt(
                stored: live.weekResult, draft: result,
                isRunning: captionWork.isRunning(event.id, .regenerateWeek))
        else { return }
        result = live.weekResult ?? result
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
        captionWork.startLearningFromEdits(eventID: event.id, appState: appState)
    }

    /// Act on the learn-from-edits pass once it has finished.
    ///
    /// Driven by the run ending AND by the screen appearing, because the run
    /// outlives the screen now: the answer to a pass Dan started before
    /// clicking another event is waiting for him when he comes back, rather
    /// than having been thrown away with the view (#718).
    ///
    /// The three outcomes stay apart (#526, L11): a pass that FAILED is not a
    /// pass with nothing to add, and only the second of those may advance the
    /// week silently.
    private func learningSettled() {
        guard !isAnalyzingEdits else { return }
        guard let outcome = captionWork.outcome(for: event.id, .learnFromEdits)
        else { return }
        // Taken once. Left in place it would fire again on every redraw, and
        // re-advance a week Dan had navigated back into.
        captionWork.clearOutcome(for: event.id, .learnFromEdits)

        switch LearnFromEditsOutcome.decide(suggestion: outcome.suggestion,
                                            failure: outcome.failure) {
        case .offerSuggestion(let s):
            learningSuggestion = s
            showLearnSheet = true
        case .advance:
            finalizeAdvance()
        case .reportFailure(let message):
            learningFailure = message
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
