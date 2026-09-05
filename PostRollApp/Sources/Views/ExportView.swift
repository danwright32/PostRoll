import SwiftUI

struct ExportView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(ExportManager.self) private var exportManager
    @Environment(GenerationManager.self) private var genManager

    /// The two shared stores this screen reads and writes (#937).
    ///
    /// Injected so the screen can be drawn for review. `AccountBook` is the
    /// stronger reason of the two: it is a file of real follower counts for
    /// real accounts, and rendering this screen read it and could write it
    /// (L2, L222). `PreviewGraphicsManager` is in memory, and injected for the
    /// same reason `TimingStore` is: a shared one holds whatever the run before
    /// left, so which days are shown as rebuilding would come and go with test
    /// order (L205).
    ///
    /// Every use, reads and writes both, rather than only the ones a render
    /// reaches: a screen given a fake book that still recorded into the real
    /// one would be holding two books (L173).
    var accounts: AccountBook = .shared
    var previews: PreviewGraphicsManager = .shared

    @State private var showingFolderPicker = false
    /// The separate picker for saying where a finished export was filed (#1110).
    /// Its own flag rather than sharing `showingFolderPicker`, which starts an
    /// export on whatever is chosen.
    @State private var showingRelocatePicker = false
    /// The folder THIS event may be re-exported to without asking, or nil.
    ///
    /// Scoped to the event rather than remembered app wide (#1048). Read from
    /// the event's own record on appear and after every export, so a new show
    /// starts with nothing offered and the picker is the only way forward,
    /// which is what stops one show being exported over another's folder.
    @State private var reusableFolder: URL? = nil
    @State private var pendingSingleDay: DayName? = nil
    /// A layout the user picked that needs confirmation before it rebuilds posts (#71).

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
    /// Read live from AppState so it reflects the latest write, not the copy
    /// this view was handed: the posting layout switch writes through AppState,
    /// and the export gate has to judge what the event says NOW.
    private var live: Event {
        appState.events.first(where: { $0.id == event.id }) ?? event
    }

    private var regeneratingDays: Set<DayName> {
        previews.regeneratingDays(event.id)
    }

    /// What the export is waiting for, or nil when it can run. Shown rather than
    /// just disabling the button, because a control that greys out with no
    /// explanation reads as broken.
    private var exportBlockedReason: String? {
        ExportReadiness.blockedReason(for: live, preset: live.effectivePostingPreset,
                                      regeneratingDays: regeneratingDays)
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
                case .cancelling:
                    cancellingContent
                case .cancelled:
                    cancelledContent
                }
            }
        }
        .background(PaintedSurfaces.page)
        .onAppear {
            reusableFolder = ExportFolderStatus.rememberedFolder(for: event)
            exportFolderStatus = ExportFolderStatus.of(event)
            refreshRecurringAccounts()
        }
        // Re-read when this export finishes, and when the recorded folder
        // changes, so the banner is never a claim about a previous run.
        .onChange(of: run?.phase) { _, _ in
            exportFolderStatus = ExportFolderStatus.of(event)
            // The finishing run is what records the folder on the event, so the
            // button offering it has to be re-derived here rather than left
            // holding what was true when the screen was built (L14).
            reusableFolder = ExportFolderStatus.rememberedFolder(for: event)
            // An export is what adds accounts to the book, so the answer can
            // have changed by the time one finishes.
            refreshRecurringAccounts()
        }
        .onChange(of: event.exportPath) { _, _ in
            exportFolderStatus = ExportFolderStatus.of(event)
            reusableFolder = ExportFolderStatus.rememberedFolder(for: event)
        }
        .sheet(item: $editingRecurringAccount) { target in
            AccountNumbersSheet(
                handle: target.handle,
                // The address the research step checked for this account, off
                // this event's own performers (#987). A recurring account from
                // another event carries none here, and falls back to the
                // address built from the handle.
                checkedProfileURL: ProfileLink.checkedProfile(
                    for: target.handle, in: event.ocrResult?.performers ?? []),
                stats: accounts.stats(for: target.handle),
                onSave: { followers, likes, comments, isPrivate, neverInvite,
                          accepted, declined in
                    accounts.record(handle: target.handle, followers: followers,
                                              likes: likes, comments: comments,
                                              isPrivate: isPrivate,
                                              neverInvite: neverInvite,
                                              acceptedInvites: accepted,
                                              declinedInvites: declined, on: Date())
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
            isPresented: $showingRelocatePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let picked = urls.first,
                  // Refuses a folder that is not there either, rather than
                  // swapping one record the app cannot find for another (L5).
                  let moved = ExportFolderRelocation.applying(
                      picked, toEventWithID: event.id, in: appState.events)
            else { return }
            appState.updateEvent(moved)
            // The banner is a claim about where the folder is, so it has to
            // stop making it the moment the answer changes. `onChange(of:
            // event.exportPath)` cannot see this: `event` is the snapshot this
            // screen was built with, not the record just written.
            exportFolderStatus = ExportFolderStatus.of(moved)
            reusableFolder = ExportFolderStatus.rememberedFolder(for: moved)
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let dest = urls.first {
                let scopedDay = pendingSingleDay
                pendingSingleDay = nil
                // Deliberately NOT set here. A chosen folder becomes this
                // event's folder by the export RECORDING it, so a run that
                // never finished cannot leave a one-click button pointing at
                // somewhere this show was never actually written (L12).
                exportManager.start(eventID: event.id, to: dest, onlyDay: scopedDay,
                                    appState: appState, regeneratingDays: regeneratingDays)
            } else {
                pendingSingleDay = nil
            }
        }
    }

    // MARK: - States

    /// Recompute which returning accounts need numbers. Cheap enough at this
    /// cadence (arriving at the screen, and an export finishing) and far too
    /// expensive on every redraw.
    private func refreshRecurringAccounts() {
        let book = accounts
        // Scoped to THIS event (#1012, #1013). Recurrence is still counted
        // across the library; only the answer is narrowed to what this event
        // tags, so a church export stops naming a concert hall it has never
        // tagged.
        //
        // Read live from the store rather than from the captured prop, which is
        // a snapshot from when the screen was built and would miss a tag added
        // since. Falling back to the prop when the id is not in the store is
        // the same event either way, just possibly a tag behind, which is a far
        // smaller wrong than reverting to the whole library.
        let live = appState.events.first { $0.id == event.id } ?? event
        recurringAccounts = RecurringAccounts.needingAttention(
            events: appState.events,
            taggedOn: live,
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
            // Style and icon come from the status rather than being written
            // here (#1110). Written here, they said "fault" for a folder Dan
            // had simply filed away, which was every export he has.
            if let message = exportFolderStatus.message,
               let banner = ExportFolderBanner.of(exportFolderStatus) {
                BrandBanner(
                    icon: banner.icon, message: message, style: banner.style,
                    // Only the lost-track case has somewhere to go that is not
                    // "export again", and its message names this button, so the
                    // two are decided together rather than in two places (L41).
                    actions: {
                        guard case .lostTrack = exportFolderStatus else { return [] }
                        return [BrandBannerAction(label: "Point PostRoll at it again") {
                            showingRelocatePicker = true
                        }]
                    }()
                )
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

            PostingLayoutControl(event: event, defaults: AppPreferences.store, previews: previews)
                .padding(.horizontal, Spacing.xl)

            ExportSummaryCard(event: event, result: result) { day in
                if let dest = reusableFolder {
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
                if let last = reusableFolder {
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
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
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
                        ProgressView().controlSize(.small).tint(PaintedSurfaces.iconAccent)
                        Text("\(exportBlockedReason) before exporting, so the folder gets the new files rather than the previous ones.")
                            .font(.system(size: 12))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
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

    private func progressContent(label: String) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer().frame(height: Spacing.xl)
            ProgressView()
                .controlSize(.large)
                .tint(PaintedSurfaces.iconAccent)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PaintedSurfaces.bodyText)
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
            .foregroundStyle(PaintedSurfaces.secondaryText)
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
                .tint(PaintedSurfaces.iconAccent)
            Text("Generating visual assets…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PaintedSurfaces.bodyText)

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
            .foregroundStyle(PaintedSurfaces.secondaryText)

            Text("Approved previews copy instantly. Reels take longer only when they need regenerating.")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            // Two buttons meaning opposite things, so they are worded to be
            // unmistakable rather than merely different (#1047). Skip finishes
            // the export with less in it; cancel means this export does not
            // happen. Until the second existed, the first was the only control
            // on this screen and read to Dan as a way out of a run he did not
            // want, which it is not.
            HStack(spacing: Spacing.md) {
                Button("Skip, text export only") {
                    exportManager.skipMedia(eventID: event.id)
                }
                .buttonStyle(BrandOutlineButtonStyle())
                Button("Cancel export") {
                    exportManager.cancel(eventID: event.id)
                }
                .buttonStyle(BrandOutlineButtonStyle())
            }
            Text("Cancel throws the whole run away. Nothing is written and your "
                 + "previous export stays where it is.")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    private var mediaElapsedFormatted: String {
        String(format: "%d:%02d", mediaElapsed / 60, mediaElapsed % 60)
    }

    /// The finished-export screen. Its own view taking plain values, so it can
    /// be rendered and measured outside the running app (#393).
    private func doneContent(folder: URL, mediaError: String?, mediaWarning: String?) -> some View {
        ExportDoneSummary(
            folderName: folder.lastPathComponent,
            mediaError: mediaError,
            mediaWarning: mediaWarning,
            onBack: {
                exportManager.clear(eventID: event.id)
                if let ev = EventStageTransition.applying(
                        .captionsReviewed, toEventWithID: event.id, in: appState.events) {
                    appState.updateEvent(ev)
                }
            },
            onOpenFolder: { NSWorkspace.shared.open(folder) },
            onDone: {
                exportManager.clear(eventID: event.id)
                appState.selectedEventID = nil
            }
        )
    }

    /// Cancel has been accepted and the work is winding down (#1047).
    ///
    /// Its own screen because the subprocess takes a moment to die, and the
    /// three states have to be tellable apart at a glance: running, winding
    /// down, and stopped. A screen that jumped straight from the spinner to
    /// "cancelled" would claim ffmpeg had exited before it had.
    private var cancellingContent: some View {
        VStack(spacing: Spacing.lg) {
            Spacer().frame(height: Spacing.xl)
            ProgressView()
                .controlSize(.large)
                .tint(PaintedSurfaces.iconAccent)
            Text("Cancelling…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PaintedSurfaces.bodyText)
            Text("Stopping the generation. Nothing has been written to your "
                 + "export folder, and the previous export is still there.")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    /// The run was abandoned. Not an error screen: nothing went wrong.
    private var cancelledContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            BrandBanner(icon: "xmark.circle",
                        message: "Export cancelled. Nothing was written, and "
                               + "your previous export is still where it was.",
                        style: .info)
                .padding(.horizontal, Spacing.xl)
            HStack {
                Spacer()
                Button("Back to export") { exportManager.clear(eventID: event.id) }
                    .buttonStyle(BrandButtonStyle())
            }
            .padding(Spacing.xl)
        }
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

    /// The same implementation the review screen uses (#458). A week with no
    /// result at all has no days, which is what an empty list says.
    private var daysWithContent: [DayName] {
        result?.daysWithContent(in: event) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(daysWithContent, id: \.self) { day in
                ExportDayRow(day: day, caption: result?[day]) {
                    onExportDay(day)
                }
            }
            if result?.blog != nil {
                Divider().background(PaintedSurfaces.edgeRule)
                ExportBlogRow(blog: result?.blog)
            }
        }
        .padding(Spacing.md)
        .background(PaintedSurfaces.deepPage)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)
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
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .frame(width: 70, alignment: .leading)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PaintedSurfaces.iconAccent)
            Text(summary)
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .lineLimit(1)
            Spacer(minLength: Spacing.sm)
            Button("Export just this day", action: onExportJustThisDay)
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(PaintedSurfaces.pageAccentText)
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
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .frame(width: 70, alignment: .leading)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PaintedSurfaces.iconAccent)
            Text(blog?.title ?? "Draft")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .lineLimit(1)
        }
    }
}

// EventExporter moved to Sources/Services/EventExporter.swift so it can be unit
// tested without pulling in this SwiftUI view.
