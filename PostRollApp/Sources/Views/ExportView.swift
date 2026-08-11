import SwiftUI

struct ExportView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(ExportManager.self) private var exportManager
    @Environment(GenerationManager.self) private var genManager

    @State private var showingFolderPicker = false
    @State private var lastExportFolder: URL? = nil
    @State private var pendingSingleDay: DayName? = nil
    /// A layout the user picked that needs confirmation before it rebuilds posts (#71).
    @State private var pendingPreset: PostingPreset? = nil

    /// What the last export left in its folder (#247). Held in state and read
    /// on appear rather than computed in `body`, because it touches the disk
    /// and `body` runs on every redraw.
    @State private var exportFolderStatus: ExportFolderStatus = .neverExported

    /// Accounts Dan keeps tagging whose audience figures are missing or old
    /// (#289), or nil when there is nothing worth saying.
    ///
    /// Here because the export screen is somewhere he passes every week anyway.
    /// The freshness flag already existed, but only on the collaborator panel of
    /// a day that has been expanded, so an account could go stale in March and
    /// nothing said so until he happened to scroll to a post that tagged them.
    ///
    /// Held in state rather than computed in `body`, which runs on every redraw:
    /// this walks every event's tag list, and a derivation whose cost scales
    /// with the whole collection does not belong on the redraw path (L91).
    @State private var recurringAccounts: [RecurringAccounts.Attention] = []

    /// The account whose numbers form is open, if any. The banner is the only
    /// way in for these: the collaborator list is built from day and per-photo
    /// tags, so a venue or org handle can never appear there, and those are
    /// exactly the accounts the banner names.
    @State private var editingRecurringAccount: RecurringAccounts.Attention? = nil

    /// Export progress is owned app-scoped by ExportManager so it survives this
    /// view being torn down on an event switch (`.id(event.id)` remount) and
    /// drives the sidebar "Exporting…" pill. `nil` run = the ready screen.
    private var run: ExportManager.Run? { exportManager.run(for: event.id) }
    private var mediaElapsed: Int { run?.elapsedSeconds ?? 0 }
    private var estimatedMediaSeconds: Double? { run?.estimatedMediaSeconds }

    private var result: WeekGenerationResult? { event.weekResult }

    /// Per-day rebuilds in flight for this event. The review screen already
    /// consulted these before offering Approve & Export (#89); this screen's own
    /// buttons did not, which left a second route to an export holding the
    /// pre-rebuild file (#225).
    private var regeneratingDays: Set<DayName> {
        PreviewGraphicsManager.shared.regeneratingDays(event.id)
    }

    /// What the export is waiting for, or nil when it can run. Shown rather than
    /// just disabling the button, because a control that greys out with no
    /// explanation reads as broken.
    private var exportBlockedReason: String? {
        ExportReadiness.blockedReason(regeneratingDays: regeneratingDays)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                EventHeader(event: event, subtitle: "Export")
                    .padding([.horizontal, .top], Spacing.xl)
                    .padding(.bottom, Spacing.md)

                switch run?.phase {
                case .none:
                    readyContent
                case .exportingText:
                    progressContent(label: "Exporting captions & blog…")
                case .generatingMedia(let folder):
                    mediaProgressContent(folder: folder)
                case .done(let folder, let mediaError, let mediaWarning):
                    doneContent(folder: folder, mediaError: mediaError, mediaWarning: mediaWarning)
                case .failed(let msg):
                    errorContent(msg)
                }
            }
        }
        .background(Color.cream)
        .onAppear {
            if let path = UserDefaults.standard.string(forKey: "lastExportFolder") {
                let candidate = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    lastExportFolder = candidate
                }
            }
            exportFolderStatus = ExportFolderStatus.of(event)
            refreshRecurringAccounts()
        }
        // Re-read when this export finishes, and when the recorded folder
        // changes, so the banner is never a claim about a previous run.
        .onChange(of: run?.phase) { _, _ in
            exportFolderStatus = ExportFolderStatus.of(event)
            // An export is what adds accounts to the book, so the answer can
            // have changed by the time one finishes.
            refreshRecurringAccounts()
        }
        .onChange(of: event.exportPath) { _, _ in
            exportFolderStatus = ExportFolderStatus.of(event)
        }
        .sheet(item: $editingRecurringAccount) { target in
            AccountNumbersSheet(
                handle: target.handle,
                stats: AccountBook.shared.stats(for: target.handle),
                onSave: { followers, likes, comments in
                    AccountBook.shared.record(handle: target.handle, followers: followers,
                                              likes: likes, comments: comments, on: Date())
                    editingRecurringAccount = nil
                    // The banner is a claim about the book, so it has to stop
                    // making it the moment the number lands. Without this the
                    // account Dan just counted keeps asking to be counted.
                    refreshRecurringAccounts()
                },
                onCancel: { editingRecurringAccount = nil }
            )
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let dest = urls.first {
                let scopedDay = pendingSingleDay
                pendingSingleDay = nil
                lastExportFolder = dest
                exportManager.start(eventID: event.id, to: dest, onlyDay: scopedDay,
                                    appState: appState, regeneratingDays: regeneratingDays)
            } else {
                pendingSingleDay = nil
            }
        }
        .confirmationDialog(
            pendingPreset.map { "Switch this event to the \($0.displayName) layout?" } ?? "",
            isPresented: Binding(
                get: { pendingPreset != nil },
                set: { if !$0 { pendingPreset = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingPreset {
                Button("Switch and rebuild") {
                    applyPreset(pendingPreset)
                    self.pendingPreset = nil
                }
                Button("Cancel", role: .cancel) { self.pendingPreset = nil }
            }
        } message: {
            Text(pendingPresetRebuildMessage)
        }
    }

    // MARK: - States

    /// Recompute which returning accounts need numbers. Cheap enough at this
    /// cadence (arriving at the screen, and an export finishing) and far too
    /// expensive on every redraw.
    private func refreshRecurringAccounts() {
        let book = AccountBook.shared
        recurringAccounts = RecurringAccounts.needingAttention(
            events: appState.events,
            stats: { book.stats(for: $0) },
            asOf: Date())
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            StageBackButton(label: "Back to caption review") {
                // Live read, never the captured prop, which is a snapshot from
                // when this screen was built and reverts anything saved since (#103).
                if let ev = EventStageTransition.applying(
                        .captionsReviewed, toEventWithID: event.id, in: appState.events) {
                    appState.updateEvent(ev)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.sm)

            BrandBanner(
                icon: "folder",
                message: "Exports captions and blog draft, then generates story images, Wednesday collage, Thursday scroll reel, Friday before/after, and Tuesday speed edit reel (where inputs are provided). Requires ffmpeg for reels."
            )
            .padding(.horizontal, Spacing.xl)

            // What the LAST export left behind, read from its manifest (#247).
            // The moment an unfinished folder is worth knowing about is here,
            // coming back to the event, not when Dan is already in Finder
            // wondering why a day is empty. Shown only when there is something
            // wrong: a banner on every visit to a good export is how a real
            // warning stops being read.
            if let message = exportFolderStatus.message, exportFolderStatus.needsAttention {
                BrandBanner(icon: "exclamationmark.triangle", message: message, style: .warning)
                    .padding(.horizontal, Spacing.xl)
            }

            // Only accounts that keep coming back (#289). Dan tags most people
            // once and never again, so asking for numbers on all of them would
            // bury the few whose figures the ranking actually leans on. Not a
            // warning: nothing here is broken, and an ordinary week must not
            // arrive looking like a problem.
            // Every account it names carries its own way in, because there is
            // nowhere else to send Dan: the collaborator list is built from day
            // and per-photo tags, so a venue or org handle cannot appear there.
            if let message = RecurringAccounts.summary(recurringAccounts) {
                BrandBanner(
                    icon: "person.2",
                    message: message,
                    actions: RecurringAccounts.actionable(recurringAccounts).map { item in
                        BrandBannerAction(label: "Add @\(item.handle)") {
                            editingRecurringAccount = item
                        }
                    }
                )
                .padding(.horizontal, Spacing.xl)
            }

            presetPicker
                .padding(.horizontal, Spacing.xl)

            ExportSummaryCard(event: event, result: result) { day in
                if let dest = lastExportFolder {
                    exportManager.start(eventID: event.id, to: dest, onlyDay: day,
                                        appState: appState, regeneratingDays: regeneratingDays)
                } else {
                    pendingSingleDay = day
                    showingFolderPicker = true
                }
            }
            .padding(.horizontal, Spacing.xl)
            // A per-day re-export is the same copy step, so it is stale for the
            // same reason while that day is rebuilding (#225).
            .disabled(exportBlockedReason != nil)

            VStack(alignment: .trailing, spacing: Spacing.sm) {
                if let last = lastExportFolder {
                    HStack {
                        Spacer()
                        Button("Export to \"\(last.lastPathComponent)\"") {
                            exportManager.start(eventID: event.id, to: last,
                                                appState: appState, regeneratingDays: regeneratingDays)
                        }
                            .buttonStyle(BrandButtonStyle())
                    }
                    HStack {
                        Spacer()
                        // Clear any single-day scope left behind by a cancelled
                        // picker: the completion handler never fires on cancel,
                        // and a stale value would silently turn this full
                        // export into a single-day one.
                        Button("Choose different folder…") {
                            pendingSingleDay = nil
                            showingFolderPicker = true
                        }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.roseGold)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Choose Destination…") {
                            pendingSingleDay = nil
                            showingFolderPicker = true
                        }
                            .buttonStyle(BrandButtonStyle())
                    }
                }
                if let exportBlockedReason {
                    HStack(spacing: Spacing.xs) {
                        Spacer()
                        ProgressView().controlSize(.small).tint(Color.roseGold)
                        Text("\(exportBlockedReason) before exporting, so the folder gets the new files rather than the previous ones.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.warmDark.opacity(0.8))
                    }
                }
            }
            .padding(Spacing.xl)
            .disabled(isRegenerating || exportBlockedReason != nil)
        }
    }

    private var isRegenerating: Bool { genManager.isRunning(event.id) }

    /// This event's effective posting layout (its override, or the app wide
    /// default). Read live from AppState so it reflects the latest write.
    private var effectivePreset: PostingPreset {
        (appState.events.first(where: { $0.id == event.id }) ?? event).effectivePostingPreset
    }

    /// Posting layout for THIS event. Switching it sets a per-event override and
    /// rebuilds Sunday/Monday/Wednesday (their captions and media change) so the
    /// affected days are regenerated. The default for new events lives in Settings.
    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.md) {
                Text("Posting layout")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.warmDark)
                Picker("Posting layout", selection: Binding(
                    get: { effectivePreset },
                    set: { requestPresetChange($0) }
                )) {
                    ForEach(PostingPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .disabled(isRegenerating)
            }
            if isRegenerating {
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small).tint(Color.roseGold)
                    Text("Rebuilding Sunday, Monday, and Wednesday for the new layout…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmDark.opacity(0.8))
                }
            } else {
                Text(effectivePreset == .balanced
                     ? "This event: Sunday, Monday, and Wednesday each post a 4 photo carousel with a collage story."
                     : "This event: Sunday and Monday post a single photo; Wednesday posts a 10 photo carousel with a collage story.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmDark.opacity(0.7))
            }
        }
    }

    /// Plain-language list of what a pending layout switch will rebuild.
    private var pendingPresetRebuildMessage: String {
        guard let pendingPreset,
              let ev = appState.events.first(where: { $0.id == event.id }) else { return "" }
        let days = pendingPreset.affectedDays(in: ev).map { $0.displayName }
        let list = ListFormatter.localizedString(byJoining: days)
        return "This rebuilds \(list) (captions and images) for this event."
    }

    /// Handle a picker selection. Switching the layout rebuilds the governed
    /// days, so confirm first when there are posts to rebuild (#71); when nothing
    /// would rebuild (no photos yet), just set the override silently.
    private func requestPresetChange(_ newValue: PostingPreset) {
        guard let ev = appState.events.first(where: { $0.id == event.id }),
              newValue != ev.effectivePostingPreset else { return }
        if newValue.affectedDays(in: ev).isEmpty {
            applyPreset(newValue)
        } else {
            pendingPreset = newValue
        }
    }

    /// Set this event's layout override and regenerate the days it governs. Their
    /// previews are cleared first so a failed regen can't leave the export copying
    /// stale assets from the previous layout.
    private func applyPreset(_ newValue: PostingPreset) {
        guard var ev = appState.events.first(where: { $0.id == event.id }),
              newValue != ev.effectivePostingPreset else { return }
        ev.postingPresetOverride = newValue

        let affected = newValue.affectedDays(in: ev).map { $0.rawValue }
        for day in affected { ev.previewMediaPaths.removeValue(forKey: day) }
        appState.updateEvent(ev)

        if !affected.isEmpty {
            genManager.start(eventID: event.id, retryDays: Set(affected), appState: appState,
                             regenerateGraphics: true)
        }
    }

    private func progressContent(label: String) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer().frame(height: Spacing.xl)
            ProgressView()
                .controlSize(.large)
                .tint(Color.roseGold)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.warmDark)
            // An elapsed clock even on the fast phase: without one this screen
            // is a spinner that reads the same at two seconds and at two
            // minutes, so a stuck text export looks exactly like a quick one
            // (#95). The tracker already counts it.
            HStack(spacing: Spacing.xs) {
                Image(systemName: "timer")
                    .font(.system(size: 11))
                Text(mediaElapsedFormatted)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(Color.warmMid)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    private func mediaProgressContent(folder: URL) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer().frame(height: Spacing.xl)
            ProgressView()
                .controlSize(.large)
                .tint(Color.roseGold)
            Text("Generating visual assets…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.warmDark)

            // Elapsed clock vs estimated total — mirrors the first generation
            // screen. The estimate is content-aware: copying approved previews
            // is near-instant, regenerating reels takes minutes.
            HStack(spacing: Spacing.xs) {
                Image(systemName: "timer")
                    .font(.system(size: 11))
                Text(mediaElapsedFormatted)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                if let est = estimatedMediaSeconds {
                    Text("/ \(TimingStore.formatClock(est))")
                        .font(.light(12))
                }
            }
            .foregroundStyle(Color.warmMid)

            Text("Approved previews copy instantly. Reels take longer only when they need regenerating.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            // Let user skip media generation if they just want the text
            Button("Skip, text export only") {
                exportManager.skipMedia(eventID: event.id)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.warmMid)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    private var mediaElapsedFormatted: String {
        String(format: "%d:%02d", mediaElapsed / 60, mediaElapsed % 60)
    }

    private func doneContent(folder: URL, mediaError: String?, mediaWarning: String?) -> some View {
        VStack(spacing: Spacing.lg) {
            // A route back into the event, matching the ready screen. Without
            // it a finished export trapped the event: the detail pane routes on
            // the stage, the stage is .exported, so this was the only reachable
            // screen and the only way out was quitting the app (#182).
            HStack {
                StageBackButton(label: "Back to caption review") {
                    exportManager.clear(eventID: event.id)
                    if let ev = EventStageTransition.applying(
                            .captionsReviewed, toEventWithID: event.id, in: appState.events) {
                        appState.updateEvent(ev)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.xl)

            Spacer().frame(height: Spacing.lg)

            // An export that lost files is not a completed export, so it does
            // not get the checkmark, the word "complete", or the claim that the
            // event is archived: none of those were true and all three read as
            // success (#79).
            let incomplete = mediaError != nil

            Image(systemName: incomplete ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(incomplete ? Color.roseDeep : Color.roseGold.opacity(0.7))
                .padding(.top, Spacing.xl)

            Text(incomplete ? "Export incomplete" : "Export complete")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.warmDark)

            Text(folder.lastPathComponent)
                .font(.light(12))
                .foregroundStyle(Color.warmMid)

            RoseGoldDivider()
                .frame(width: 80)

            if let mediaErr = mediaError {
                // The message is whatever actually failed. It used to append
                // "Check that ffmpeg is installed" to every cause, which sends
                // the diagnosis somewhere unrelated for a missing photo.
                BrandBanner(
                    icon: "exclamationmark.triangle",
                    message: "The captions and blog were exported. \(mediaErr)",
                    style: .error
                )
                .frame(maxWidth: 400)
            }

            // An input that was missing while the day rendered anyway. Said out
            // loud, because a file that has moved is worth knowing about, and
            // deliberately NOT as an error: the folder is complete and the
            // event is archived (#265).
            if let mediaWarn = mediaWarning {
                BrandBanner(
                    icon: "info.circle",
                    message: mediaWarn,
                    style: .warning
                )
                .frame(maxWidth: 400)
            }

            Text(incomplete
                 ? "This event has NOT been archived, so nothing is on the clock to be cleaned up. Fix what's listed above and export again."
                 : "This event is now archived. Use the archive button in the sidebar to revisit it.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            HStack(spacing: Spacing.md) {
                Button("Open in Finder") { NSWorkspace.shared.open(folder) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.roseGold)
                Button("Done") {
                    exportManager.clear(eventID: event.id)
                    appState.selectedEventID = nil
                }
                .buttonStyle(BrandButtonStyle())
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            BrandBanner(icon: "exclamationmark.triangle", message: message, style: .error)
                .padding(.horizontal, Spacing.xl)
            HStack {
                Spacer()
                Button("Try Again") { exportManager.clear(eventID: event.id) }
                    .buttonStyle(BrandButtonStyle())
            }
            .padding(Spacing.xl)
        }
    }

}

// MARK: - Export summary card

private struct ExportSummaryCard: View {
    let event: Event
    let result: WeekGenerationResult?
    let onExportDay: (DayName) -> Void

    private var daysWithContent: [DayName] {
        DayName.allCases.filter { day in
            if result?[day] != nil { return true }
            if day == .friday, let pd = event.days[day.rawValue],
               (pd.rawPhotoPath != nil || pd.editedPhotoPath != nil || !pd.photoPaths.isEmpty) {
                return true
            }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(daysWithContent, id: \.self) { day in
                ExportDayRow(day: day, caption: result?[day]) {
                    onExportDay(day)
                }
            }
            if result?.blog != nil {
                Divider().background(Color.creamEdge)
                ExportBlogRow(blog: result?.blog)
            }
        }
        .padding(Spacing.md)
        .background(Color.creamDeep)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.creamEdge, lineWidth: 1)
        )
    }
}

private struct ExportDayRow: View {
    let day: DayName
    let caption: DayCaption?
    let onExportJustThisDay: () -> Void

    private var summary: String {
        if day == .friday { return "Before / after story" }
        guard let c = caption?.caption, !c.isEmpty else { return "" }
        return String(c.prefix(60)) + (c.count > 60 ? "…" : "")
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(day.displayName.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.0)
                .foregroundStyle(Color.warmMid)
                .frame(width: 70, alignment: .leading)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.roseGold)
            Text(summary)
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
                .lineLimit(1)
            Spacer(minLength: Spacing.sm)
            Button("Export just this day", action: onExportJustThisDay)
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Color.roseGold)
        }
    }
}

private struct ExportBlogRow: View {
    let blog: BlogOutput?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text("BLOG")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.0)
                .foregroundStyle(Color.warmMid)
                .frame(width: 70, alignment: .leading)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.roseGold)
            Text(blog?.title ?? "Draft")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
                .lineLimit(1)
        }
    }
}

// EventExporter moved to Sources/Services/EventExporter.swift so it can be unit
// tested without pulling in this SwiftUI view.
