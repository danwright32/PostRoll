import Foundation
import Observation

enum SidebarMode: String { case events, insights }
enum InsightsSection: String { case overview, posts, orgs }

@MainActor
@Observable
final class AppState {
    var events: [Event] = []
    var selectedEventID: Event.ID?
    var showingNewEvent = false
    /// The list of days whose cached assets predate the current design (#293).
    var showingOutdatedDesigns = false

    /// Set at launch when the running app was built before the newest commit,
    /// so a fix that has already shipped may simply not be in this copy.
    ///
    /// Checked once per launch: it reads the disk and runs git, and the answer
    /// cannot change while the app is open.
    var buildBehind: BuildBehind?
    /// Set at launch when PostRoll cannot reach its code folder, so the app
    /// says so before Dan has picked a day and pressed a button on something
    /// that was never going to run (#652).
    var projectRootProblem: AppPaths.ProjectRootProblem?

    /// Set at launch when the code folder is not on a clean main, so anything
    /// generated runs code that is not what this app was built from (#664).
    ///
    /// A sentence rather than the reading it came from: what the window needs is
    /// the words, and keeping the phrasing in one place stops a second version
    /// of it growing here.
    ///
    /// Kept up to date rather than read once per launch (#668). A checkout moves
    /// while the app is open, because that is when somebody switches branch or
    /// leaves an edit, so a notice read only at launch is silent in the case it
    /// exists for and its silence then reads as an assurance. It is still not
    /// re-derived on every draw, which would put three git calls on the path of
    /// every keystroke (L59): it is refreshed when the app comes forward and
    /// whenever a reading is taken anywhere, which includes the one every
    /// generation takes for its own log.
    ///
    /// Written only through `apply`, so a reading can never set the sentence
    /// without also being able to clear it.
    private(set) var checkoutNotice: String?

    /// What the window says about the code folder, from one reading of it.
    ///
    /// Clearing is as much the job as setting: a checkout put back on a clean
    /// main, or one that could not be read at all, must take the sentence away
    /// rather than leave the previous one standing (L11). The whole point of
    /// re-reading is lost if the notice only ever appears.
    func apply(_ reading: CheckoutRevision.Reading) {
        checkoutNotice = CheckoutNotice.message(for: reading)
    }

    /// Listen for readings taken anywhere, so a run refreshes the notice.
    ///
    /// Idempotent: a window that appears twice must not end up with two
    /// observers on one shared centre. The subscription is held here and removed
    /// when this state goes away, because a notification centre outlives what
    /// registers with it and holds it unowned (L86).
    func watchCheckoutReadings(_ center: NotificationCenter = .default) {
        guard checkoutReadings == nil else { return }
        checkoutReadings = NotificationSubscription(
            center: center, name: CheckoutRevision.readNotification
        ) { [weak self] notification in
            guard let reading = CheckoutRevision.reading(in: notification) else { return }
            // Hopped deliberately: the reading a generation takes is taken on a
            // detached task, so this arrives off the main actor.
            Task { @MainActor in self?.apply(reading) }
        }
    }

    private var checkoutReadings: NotificationSubscription?

    /// Set when events.json existed but its contents could not be decoded.
    /// Shown once as a dismissible alert; the bad file was moved aside, so
    /// starting from an empty list is safe.
    var dataLoadWarning: String?

    /// The backup the corrupt-store alert can put back, when one exists.
    ///
    /// Set alongside `dataLoadWarning`, because a restore anyone can reach only
    /// from a terminal is not a restore path for Dan: five verified-good
    /// generations sat beside the bad file with nothing in the app able to
    /// offer them (#441).
    private(set) var restorableBackup: RestorableBackup?

    /// Set when events.json could not be read at all (a permission denial, an
    /// I/O error). The file is intact and untouched, its contents are unknown,
    /// and saving is refused, so the app must not let the user work in what
    /// looks like an empty library. Shown as a blocking alert with a retry.
    var storeUnavailable: String?

    /// Set the first time a save fails, and kept until one succeeds (#446).
    ///
    /// Not an alert: a failing disk fails every debounced keystroke, and a modal
    /// per keystroke is unusable. A banner that stays put is also the honest
    /// shape, because the condition persists until something changes.
    var saveFailure: String?

    /// An event that has been removed from the list but is still inside its
    /// undo window. Its media is deliberately still on disk.
    private(set) var pendingDeletion: Event?
    private var finalizeDeletionWork: DispatchWorkItem?

    // Analytics navigation
    var sidebarMode: SidebarMode = .events
    var insightsSection: InsightsSection = .overview

    /// Where the events store is read and written.
    ///
    /// A property rather than `EventStore.storeURL` at each call site, so the
    /// test seam below can point a whole AppState at a temp file and exercise the
    /// real save path, including its failures, without being able to reach the
    /// live events.json (L2).
    private let storeURL: URL

    /// Where the media the launch sweeps delete actually lives.
    ///
    /// Threaded rather than each sweep reaching for `AppPaths.root` itself, so a
    /// test can drive the real `loadStore` (including the restore path) against
    /// a temp tree and be structurally unable to delete live photos (L2). The
    /// sweeps below delete files for every event NOT in the list they are given.
    private let layout: AppPaths.Layout

    #if POSTROLL_TESTS
    /// Test seam: an AppState holding exactly these events, with no read of the
    /// on-disk store and none of the launch sweeps. Tests must be structurally
    /// unable to see or rewrite the real events.json, and every sweep below
    /// deletes media based on which events exist.
    ///
    /// Compiled only into the test bundle. The shipping app cannot call this
    /// even by accident, and an accident here would not look like one: it would
    /// open showing an empty library while the real events sat on disk.
    init(events: [Event],
         storeURL: URL = EventStore.storeURL,
         dataRoot: URL = AppPaths.root) {
        self.events = events
        self.storeURL = storeURL
        self.layout = AppPaths.Layout(root: dataRoot)
    }
    #endif

    init() {
        storeURL = EventStore.storeURL
        layout = AppPaths.layout
        // Data lives under AppPaths.root, which is ~/Library/Application Support
        // /PostRoll once the `.migrated` marker is present (the move was done
        // out-of-band, deliberately NOT on launch), otherwise the legacy
        // ~/Documents/PostRoll. No migration runs here.
        loadStore()
    }

    /// Reads the store and, only when what came back is the real event list,
    /// runs the launch sweeps. Every sweep below deletes files or rewrites the
    /// store based on which events exist, so running any of them against a list
    /// we failed to read would delete media for events that are still there.
    /// Also used by the retry button on the store-unavailable alert.
    func loadStore() {
        let loaded = EventStore.load(from: storeURL)
        events = loaded.events
        switch loaded.status {
        case .ok:
            dataLoadWarning = nil
            storeUnavailable = nil
            restorableBackup = nil
        case .corrupt:
            let available = StoreBackups.availableRestore(for: storeURL)
            restorableBackup = {
                guard case .backup(let url) = available else { return nil }
                return RestorableBackup(fileName: url.lastPathComponent,
                                        takenAt: StoreBackups.takenAt(url, of: storeURL))
            }()
            dataLoadWarning = StoreRestoreText.corruptStore(loaded.recoveryMessage,
                                                            offering: available,
                                                            named: restorableBackup)
            storeUnavailable = nil
        case .unreadable:
            dataLoadWarning = nil
            storeUnavailable = loaded.recoveryMessage
            restorableBackup = nil
        }

        guard loaded.isAuthoritative else { return }

        // Sweep: events past OCR review (photosAssigned and beyond) no longer
        // need their program images on disk — OCRReviewView.confirmAndAdvance
        // clears them when the user moves forward. We keep images alive
        // through .ocrDone so the user can press "Back" from OCR review and
        // re-run OCR on the same files (e.g. after re-launching the app).
        var dirty = false
        for i in events.indices where events[i].stage != .created
            && events[i].stage != .programUploaded
            && events[i].stage != .ocrDone
            && !events[i].programImagePaths.isEmpty {
            ProgramImageCleanup.delete(urls: events[i].programImagePaths)
            events[i].programImagePaths = []
            dirty = true
        }

        // Reclaim disk space from shoots archived more than ArchiveCleanup.archiveAgeDays ago.
        if ArchiveCleanup.sweep(events: &events, dataRoot: layout.root) {
            dirty = true
        }

        // Copy any media still referenced from outside app storage (originals
        // picked from ~/Downloads/~/Desktop before the import-copy fix) into the
        // app's folder, so collage edits and exports stop re-triggering the
        // macOS permission prompt on every interaction.
        if MediaReclaim.reclaim(events: &events,
                                photosDir: layout.photosDir,
                                audioDir: layout.audioDir,
                                clipsDir: layout.clipsDir,
                                storageRoot: layout.root) {
            dirty = true
        }

        if dirty { persist() }

        // Reclaim photos/audio copies left behind by deleted events. Only
        // reachable on an authoritative load (guarded above): against an
        // empty or partial events array this would orphan, and delete, every
        // media file on disk.
        sweepOrphanedMedia()

        // Same guard, same reason: the per-event progress files a deleted event
        // leaves behind. Housekeeping rather than space, so that the app has one
        // answer to who clears up per-event scratch files (#235).
        ProgressFileCleanup.sweep(events: events, progressDir: layout.progressDir)
    }

    /// The orphan sweep, against this AppState's data root rather than the
    /// live one. One helper because three call sites ran it and each passed a
    /// different (defaulted) set of folders (L16).
    private func sweepOrphanedMedia(owners: [Event]? = nil) {
        let owning = owners ?? events
        OrphanedMediaCleanup.sweep(events: owning,
                                   photosDir: layout.photosDir,
                                   audioDir: layout.audioDir,
                                   programsDir: layout.programsDir,
                                   clipsDir: layout.clipsDir)
        // The preview folder too (#482). It was the one derived resource a
        // delete left behind, on the machine whose disk has been filled by
        // exactly this class before.
        OrphanedMediaCleanup.sweepPreviewFolders(events: owning,
                                                 previewDir: layout.previewDir)
    }

    /// Put the newest verified-good backup of the store back, for the button on
    /// the corrupt-store alert.
    ///
    /// Reports what actually happened rather than assuming: a restore that
    /// could not write is the moment the person most needs to be told, and a
    /// silent one would leave them looking at the same empty list believing it
    /// had worked (L12).
    @discardableResult
    func restoreLatestBackup() -> StoreBackups.RestoreOutcome {
        let outcome = StoreBackups.restore(store: storeURL, isValid: EventStore.decodes)
        switch outcome {
        case .restored:
            // Through the ordinary load, so the restored list gets the same
            // launch treatment every other list gets, rather than a second
            // path that reads the store its own way.
            loadStore()
        case .noBackup:
            dataLoadWarning = StoreRestoreText.noBackup
            restorableBackup = nil
        case .failed(let reason):
            dataLoadWarning = StoreRestoreText.failed(reason)
        }
        return outcome
    }

    /// Every write of the store goes through here, so what happened to it cannot
    /// be reported by some edit paths and swallowed by others (#446).
    ///
    /// Six call sites wrote the store directly and all six discarded the outcome.
    /// `SaveCallSiteTests` holds this to one place, because fixing five of them
    /// would have left the sixth quietly losing work and nothing about reading
    /// any one of them would have shown which.
    @discardableResult
    private func persist() -> EventStore.SaveOutcome {
        let outcome = EventStore.save(events, to: storeURL)
        record(outcome)
        return outcome
    }

    /// Turn a save outcome into what the window shows.
    ///
    /// `blocked` deliberately raises nothing: it only happens when the store
    /// could not be READ, which already puts a blocking alert on screen with a
    /// retry, and a second notice would say the same thing twice.
    private func record(_ outcome: EventStore.SaveOutcome) {
        switch outcome {
        case .saved:
            saveFailure = nil
        case .blocked:
            break
        case .failed(let reason):
            saveFailure = SaveFailureNotice.message(reason: reason)
        }
    }

    /// Save again now, for the retry on the failure banner. Clears the banner if
    /// it works, and leaves it in place with a fresh reason if it does not.
    func retrySave() {
        storeWriter.flush()
        persist()
    }

    /// Coalesces per-keystroke saves. Owned here rather than by the review
    /// screen, which remounts whenever Dan switches events and would take a
    /// pending write down with it.
    ///
    /// `lazy` so the closure can report back: the whole point of #446 is that the
    /// debounced write was the one save whose outcome could reach nothing at all.
    /// The report runs inline when the write already happens on the main thread,
    /// which is every path except the writer's own deinit, so a flush and its
    /// banner land together rather than a frame apart.
    /// `@ObservationIgnored` because it is machinery rather than UI state, and
    /// because @Observable cannot generate tracking for a lazy property that
    /// captures self at all.
    @ObservationIgnored
    private lazy var storeWriter = DebouncedStoreWriter<[Event]> { [weak self, url = storeURL] events in
        let outcome = EventStore.save(events, to: url)
        if Thread.isMainThread {
            MainActor.assumeIsolated { self?.record(outcome) }
        } else {
            Task { @MainActor in self?.record(outcome) }
        }
    }

    func addEvent(_ event: Event) {
        events.append(event)
        selectedEventID = event.id
        persist()
    }

    func updateEvent(_ event: Event) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
        // Any pending text edit is written first, so an immediate structural
        // save can never land ahead of the typing that preceded it.
        storeWriter.flush()
        persist()
    }

    /// Same as `updateEvent`, but the DISK write is coalesced (#91, #197).
    ///
    /// For per-keystroke edits (caption, blog body, notes). The in-memory
    /// `events` array is updated immediately, exactly as `updateEvent` does, so
    /// every reader still sees the current text; only the serialisation of the
    /// whole store is deferred to a pause in typing. Typing a blog body used to
    /// cost hundreds of full store writes, scaling with how many events exist
    /// rather than with the size of the edit.
    func updateEventDebounced(_ event: Event) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
        storeWriter.schedule(events)
    }

    /// Write any pending text edit now.
    ///
    /// Every path that ends an editing session calls this: navigating away,
    /// generating, exporting, quitting. A debounce that loses the last sentence
    /// would be worse than the cost it saves.
    func flushPendingWrites() {
        storeWriter.flush()
    }

    /// Removes the event and starts its undo window. Its media stays on disk
    /// until the window closes, so Undo restores a working event rather than
    /// one whose photos were deleted a second earlier.
    func deleteEvent(id: Event.ID) {
        guard let event = events.first(where: { $0.id == id }) else { return }
        // Only one undo is ever offered, so an earlier pending delete is now
        // final and its media can go.
        finalizePendingDeletion()

        events.removeAll { $0.id == id }
        if selectedEventID == id { selectedEventID = nil }
        persist()
        pendingDeletion = event

        // Anything else the delete orphaned is reclaimed now; the event itself
        // still counts as an owner of its files until the window closes.
        sweepOrphanedMedia(
            owners: DeletionPolicy.mediaOwners(events: events, pendingDeletion: event)
        )

        let work = DispatchWorkItem { [weak self] in self?.finalizePendingDeletion() }
        finalizeDeletionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DeletionPolicy.undoWindow, execute: work)
    }

    /// Puts back the event that is still inside its undo window, media intact.
    func undoDelete() {
        finalizeDeletionWork?.cancel()
        finalizeDeletionWork = nil
        guard let event = pendingDeletion else { return }
        pendingDeletion = nil
        addEvent(event)
    }

    /// Ends the undo window: the event is gone for good, so its media is
    /// reclaimed. Safe to call when nothing is pending. If the app quits first,
    /// the sweep at next launch reclaims the files instead.
    func finalizePendingDeletion() {
        finalizeDeletionWork?.cancel()
        finalizeDeletionWork = nil
        guard pendingDeletion != nil else { return }
        pendingDeletion = nil
        sweepOrphanedMedia()
    }

    /// Duplicate an event: copies metadata and OCR result, clears photos and
    /// generated content, sets stage to the first step that needs fresh work.
    @discardableResult
    func duplicateEvent(id: Event.ID) -> Event.ID? {
        guard let original = events.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.days = [:]
        copy.blogPhotoPaths = []
        copy.weekResult = nil
        copy.exportPath = nil
        // Resume from the earliest stage that requires new input
        if original.ocrReviewDone {
            copy.stage = .photosAssigned
        } else if original.ocrResult != nil {
            copy.stage = .ocrDone
        } else if !original.programImagePaths.isEmpty {
            copy.stage = .programUploaded
        } else {
            copy.stage = .created
        }
        events.append(copy)
        selectedEventID = copy.id
        persist()
        return copy.id
    }
}
