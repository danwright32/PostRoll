import SwiftUI
import AppKit


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
    /// Start a revision. It is not awaited and nothing is returned: this row is
    /// destroyed on every event switch, and it used to be holding the only copy
    /// of the run's progress, its error and the caption to undo to (#718).
    let onRevise: (String, Bool) -> Void
    /// The run's state, read from `CaptionWorkManager` by the screen above.
    var isRevising: Bool = false
    var revisionError: String? = nil
    /// The revision landed and only the brand voice note did not (#462). Its
    /// own value rather than a second meaning for `revisionError`, which would
    /// say the revision failed when it did not (L53).
    var brandVoiceError: String? = nil
    /// The caption as it stood before the last revision, so Restore is offered
    /// after the screen has been rebuilt (L97).
    var undoCaption: DayCaption? = nil
    var onUndoRevision: (() -> Void)? = nil
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
    /// Friday's own rebuild failure, read from the manager that owns that run,
    /// so the card can show the fail-loud "< 3 usable clips" banner with its two
    /// escape hatches instead of relying on the generic top-of-screen error
    /// text (#135). It used to be the screen's one shared error string, which
    /// any other day's failure could overwrite between the run and the reading
    /// (#721, L53).
    ///
    /// The whole failure rather than its sentence, so the decision below reads
    /// the pipeline's marker (#730).
    var fridayFailure: PreviewGraphicsManager.DayFailure? = nil
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

    // What Dan is typing is this row's business; the run it starts is not.
    @State private var showingRevision = false
    @State private var feedbackText = ""
    @State private var saveToBrandVoice = false
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
                                    onToggleTitleCard: onToggleFridayTitleCard,
                                    isRegenerating: isRegeneratingGraphic
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
                    if FridayReviewDisplay.offersInsufficientClipsEscape(fridayFailure) {
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
                                                onUndoRevision?()
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
                                            onUndoRevision?()
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
                                        onUndoRevision?()
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
        // The panel is closed by the run finishing, not by the press that
        // started it: this row no longer knows when the work is done, and
        // clearing on the press would throw away the text a failed brand voice
        // note still needs (#462, #718).
        .onChange(of: isRevising) { revisionSettled() }
    }

    /// Hand the feedback over and let go of it.
    ///
    /// Nothing is awaited. The panel stays open while it runs so the spinner
    /// and any failure have somewhere to appear, and it is closed by
    /// `revisionSettled` below once the run has finished cleanly.
    private func applyRevision() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRevise(trimmed, saveToBrandVoice)
    }

    /// Clear the composer once a revision has finished with nothing left to say.
    ///
    /// Held open on a failed brand voice note, because the note IS the text in
    /// this panel and clearing it is what threw it away (#462).
    private func revisionSettled() {
        guard !isRevising, brandVoiceError == nil else { return }
        guard revisionError == nil else { return }
        showingRevision = false
        feedbackText = ""
        saveToBrandVoice = false
    }
}

// MARK: - Revision panel

struct RevisionPanel: View {
    @Binding var feedbackText: String
    @Binding var saveToBrandVoice: Bool
    let isRevising: Bool
    let error: String?
    /// The revision landed and only the brand voice note did not (#462). Its
    /// own field rather than a second meaning for `error`, which would say the
    /// revision failed when it did not.
    var brandVoiceError: String? = nil
    /// What this panel needs to draw a real progress indicator instead of an
    /// indefinite spinner (#1128). Optional and absent by default, because the
    /// caption revision path it was written for has no progress file: only the
    /// blog revision writes one, so only that caller supplies this.
    struct Progress {
        let eventID: UUID
        let startedAt: Date?
        let run: LongRunIndicator.Run
        var estimate: String? = nil
    }
    var progress: Progress? = nil
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
                .textFieldStyle(.plain)
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
                if isRevising, let progress {
                    LongRunIndicator(label: "Revising…",
                                     startedAt: progress.startedAt,
                                     eventID: progress.eventID,
                                     run: progress.run,
                                     estimate: progress.estimate)
                } else if isRevising {
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
