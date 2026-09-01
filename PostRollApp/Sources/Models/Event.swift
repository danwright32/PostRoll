import Foundation

struct Event: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var org: String
    var venue: String
    /// Specific room/hall within the venue (e.g. "Weill Recital Hall" when `venue`
    /// is "Carnegie Hall"). Used only by blog + captions for richer prose; graphics
    /// and reels always show the top-level `venue`.
    var venueContext: String = ""
    var date: Date
    var shootType: ShootType
    var stage: EventStage = .created

    /// Downbeat's id for the show this event was created from, when it came
    /// from a `postroll://` link rather than being typed (#840).
    ///
    /// Per SHOW rather than per booking, so a three night run carries three
    /// distinct ids and makes three distinct events. It is the key a second
    /// click on the same link matches on: with it, clicking again selects this
    /// event and says so; without it, every click would make another event.
    ///
    /// `nil` for every event typed into the sheet by hand, which is every event
    /// that existed before this shipped. A nil must never match another nil.
    var downbeatBookingID: UUID? = nil

    // Program OCR inputs
    var programImagePaths: [URL] = []
    /// A single searchable PDF of the whole program, built from the page scans
    /// at upload time (with an OCR text layer) so it survives ArchiveCleanup
    /// reclaiming the individual `programImagePaths` files post-export.
    var programPDFPath: URL? = nil
    /// Fingerprint of the page set `programPDFPath` was built from. When it no
    /// longer matches the current pages (a page was added/removed/reordered after
    /// the bake), the cached PDF is stale and gets rebuilt on next download.
    var programPDFFingerprint: String? = nil
    var ocrResult: OCRResult?
    var ocrReviewDone: Bool = false
    var eventURL: String = ""  // Optional event page URL — used to enrich OCR data

    // Flags raised by postroll.ai.flag_issues after OCR — items the user
    // should accept or correct before continuing. Cleared once review is done.
    var pendingFlags: [OCRFlag] = []

    /// Human-readable message if the post-OCR flagging step failed (e.g. payload
    /// too large, rate limit). OCR data is still usable; the user just won't
    /// have an auto-flagged review list. Cleared on confirm.
    var pendingFlagsError: String? = nil
    /// Why the Vision spelling cross-check did not run, when it did not (#209).
    /// Its own field rather than sharing `pendingFlagsError`: they are
    /// independent checks, and a pass from one must not erase the other's
    /// failure, or a skipped cross-check reads as a program with nothing wrong.
    var visionCheckSkipped: String? = nil
    /// Why the performer list was not fetched from the event's website, when it
    /// was not (#449). Its own field for the same reason as the one above: the
    /// two checks are independent, and a silent failure here means the program
    /// list shipped in place of the source the code itself prefers, with
    /// nothing saying so.
    var webPerformersSkipped: String? = nil

    /// Programs Dan knowingly took incomplete, keyed by the uploaded file's
    /// name (#378). Set only when he takes the readable pages of a program that
    /// did not come in whole, and cleared for a file that later comes in whole.
    /// Persisted because the captions and blog are written long after the
    /// import, and by then nothing else can tell that the program is short.
    var partialProgramNotes: [String: String] = [:]

    // Event-wide handles applied to every day's caption (org, venue, recurring tags)
    var eventHandles: String = ""

    /// Per-event posting layout. `nil` means follow the app wide default
    /// (`PostingPreset.current`); set on the Export page to give one event a
    /// different layout without changing the default for other events (#66).
    var postingPresetOverride: PostingPreset? = nil

    /// The layout this event actually uses: its own override, or the app wide
    /// default when it has none.
    var effectivePostingPreset: PostingPreset {
        effectivePostingPreset(in: AppPreferences.store)
    }

    /// This event's layout, reading the app wide default from a given store.
    ///
    /// The store is a parameter so a test can point it at a scratch suite
    /// rather than writing Dan's real posting preference and putting it back
    /// afterwards (#116).
    func effectivePostingPreset(in defaults: UserDefaults) -> PostingPreset {
        postingPresetOverride ?? PostingPreset.current(in: defaults)
    }

    // Per-day photo assignments (keyed by DayName.rawValue)
    var days: [String: PostingDay] = [:]

    // Blog
    var blogPhotoPaths: [URL] = []

    // Generated content (captions + blog)
    var weekResult: WeekGenerationResult?

    // Preview graphics generated before export (day → asset type → absolute path)
    // e.g. ["sunday": ["story": "/path/to/story.png"], "wednesday": ["collage": "/path/..."]]
    var previewMediaPaths: [String: [String: String]] = [:]

    /// Per-day failures from the graphics step of the last run that rendered that
    /// day (day key → raw Python message), plus `PreviewMergePolicy.graphicsRunKey`
    /// when the whole graphics run died. Kept separate from `weekResult.errors`
    /// (the caption step) because the two steps fail and retry independently: a
    /// caption-only retry must not clear a collage failure it never re-attempted.
    var mediaErrors: [String: String] = [:]

    /// Per-day notes from the graphics step about a day that DID render: a
    /// chosen optional photo that has moved, say. Its own store rather than a
    /// second meaning for `mediaErrors`, because the two need opposite
    /// responses and while they shared one field a day whose only complaint was
    /// a missing optional input read as a day with no graphics at all (#265).
    var mediaWarnings: [String: String] = [:]

    // Export
    var exportPath: URL?

    /// Set when stage transitions to .exported. Used by ArchiveCleanup to decide
    /// which preview/program files to reclaim once a shoot has been archived
    /// for long enough that the user is unlikely to re-render it.
    var archivedAt: Date? = nil

    /// `stage` doubles as a navigation router and flips to `.assetsGenerated`
    /// the moment the user opens the generation screen, before any assets are
    /// actually produced. Assets only truly exist once `weekResult` is set, so
    /// the sidebar pill uses this to avoid prematurely showing "Assets Generated".
    var isAwaitingGeneration: Bool {
        stage == .assetsGenerated && weekResult == nil
    }

    /// Same router-vs-milestone trap at the final step: approving captions flips
    /// `stage` to `.exported` to open the Export screen, but no files exist until
    /// the user picks a folder and runs the export (which stamps `exportPath` and
    /// `archivedAt`). Legacy events exported before `exportPath` was recorded still
    /// carry `archivedAt`, so they correctly read as exported rather than pending.
    var isAwaitingExport: Bool {
        stage == .exported && exportPath == nil && archivedAt == nil
    }

    /// Genuinely exported: files exist somewhere and the week is finished.
    ///
    /// The one predicate everything that acts on "is this exported" goes
    /// through (#455, L16). `stage == .exported` alone is a router flag, not a
    /// milestone, and reading it raw cost real data: the launch sweep stamped
    /// `archivedAt` on an event Dan had only approved, which started the 60 day
    /// clock that reclaims its preview media and program scans while the export
    /// it still owed had never run. The sidebar read it raw too, so the same
    /// event was hidden from the default list under a toggle calling it
    /// exported, one row after a badge saying Ready to Export.
    var isExported: Bool {
        stage == .exported && !isAwaitingExport
    }

    var displayDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }

    var isoDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Event backward-compatible decoding
// Custom init in an extension so the synthesized memberwise initializer is preserved.

extension Event {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self,      forKey: .id)
        name         = try c.decode(String.self,    forKey: .name)
        org          = try c.decode(String.self,    forKey: .org)
        venue        = try c.decode(String.self,    forKey: .venue)
        venueContext = try c.decodeIfPresent(String.self, forKey: .venueContext) ?? ""
        date         = try c.decode(Date.self,      forKey: .date)
        shootType    = try c.decode(ShootType.self, forKey: .shootType)
        stage             = try c.decodeIfPresent(EventStage.self,                 forKey: .stage)             ?? .created
        downbeatBookingID = try c.decodeIfPresent(UUID.self,                       forKey: .downbeatBookingID)
        programImagePaths = try c.decodeIfPresent([URL].self,                      forKey: .programImagePaths) ?? []
        programPDFPath    = try c.decodeIfPresent(URL.self,                        forKey: .programPDFPath)
        programPDFFingerprint = try c.decodeIfPresent(String.self,                 forKey: .programPDFFingerprint)
        ocrResult         = try c.decodeIfPresent(OCRResult.self,                  forKey: .ocrResult)
        ocrReviewDone     = try c.decodeIfPresent(Bool.self,                       forKey: .ocrReviewDone)     ?? false
        pendingFlags      = try c.decodeIfPresent([OCRFlag].self,                  forKey: .pendingFlags)      ?? []
        pendingFlagsError = try c.decodeIfPresent(String.self,                     forKey: .pendingFlagsError)
        visionCheckSkipped = try c.decodeIfPresent(String.self,                     forKey: .visionCheckSkipped)
        webPerformersSkipped = try c.decodeIfPresent(String.self,                   forKey: .webPerformersSkipped)
        partialProgramNotes = try c.decodeIfPresent([String: String].self,          forKey: .partialProgramNotes) ?? [:]
        eventURL          = try c.decodeIfPresent(String.self,                     forKey: .eventURL)          ?? ""
        eventHandles      = try c.decodeIfPresent(String.self,                     forKey: .eventHandles)      ?? ""
        postingPresetOverride = try c.decodeIfPresent(PostingPreset.self,          forKey: .postingPresetOverride)
        days              = try c.decodeIfPresent([String: PostingDay].self,       forKey: .days)              ?? [:]
        blogPhotoPaths    = try c.decodeIfPresent([URL].self,                      forKey: .blogPhotoPaths)    ?? []
        weekResult        = try c.decodeIfPresent(WeekGenerationResult.self,       forKey: .weekResult)
        previewMediaPaths = try c.decodeIfPresent([String: [String: String]].self, forKey: .previewMediaPaths) ?? [:]
        mediaErrors       = try c.decodeIfPresent([String: String].self,           forKey: .mediaErrors)       ?? [:]
        mediaWarnings     = try c.decodeIfPresent([String: String].self,           forKey: .mediaWarnings)     ?? [:]
        exportPath        = try c.decodeIfPresent(URL.self,                        forKey: .exportPath)
        archivedAt        = try c.decodeIfPresent(Date.self,                       forKey: .archivedAt)
    }

    /// Writes a freshly-decoded Friday clip plan onto this event's Friday day.
    /// `plan` is nil when no reel was attempted this run (no clips, or the
    /// clip-reel gate fell back): a nil plan must never clobber an
    /// already-persisted one, and there's nothing to write if Friday has no
    /// PostingDay yet. Shared by every call site that applies a
    /// PreviewGenerationResult (GenerationManager.finishSuccess,
    /// CaptionReviewView.generateGraphics, CaptionReviewView.applyRegenResult)
    /// so the write-back logic exists in exactly one place.
    mutating func applyFridayClipPlan(_ plan: FridayClipPlan?) {
        guard let plan else { return }
        days["friday"]?.fridayClipPlan = plan
    }

    /// Writes a freshly-decoded cover pick onto the named day (Thursday or
    /// Friday). `pick` is nil when no cover was generated this run (the
    /// sticky gate reused an already-persisted pick, or the day doesn't
    /// apply): a nil pick must never clobber an already-persisted one, and
    /// there's nothing to write if the day has no PostingDay yet. Shared by
    /// every call site that applies a PreviewGenerationResult, same pattern
    /// as applyFridayClipPlan.
    mutating func applyCoverPick(_ pick: CoverPick?, forDay day: String) {
        guard let pick else { return }
        days[day]?.coverPick = pick
    }

    /// Record what the graphics step said about one day: a failure, a note
    /// about a day that rendered anyway, or neither. Returns whether anything
    /// actually moved, so a caller can skip a save that writes the event back
    /// unchanged.
    ///
    /// Both are passed every time, and nil CLEARS rather than leaves alone.
    /// That is the point of it: these describe the last render of that day, and
    /// a note kept past the render it was about is no longer merely stale, it
    /// is false. The easy way to leave one behind is to write only the value
    /// you happen to have, so there is one call that always writes both.
    ///
    /// On the model rather than in the screen that had it, because two screens
    /// now report a Friday reel that came back without its title (#824), and a
    /// rule about clearing that lives in a private method of one view is a rule
    /// the other one has to remember.
    @discardableResult
    /// Record which layout these days' images were just drawn under (#1010).
    ///
    /// One method rather than a line at each of the three places that write
    /// rendered paths (the full run, a per day render, and a generation run's
    /// graphics pass), because a writer that forgets it leaves that day
    /// permanently unjudgeable and the export gate silently stops covering it.
    mutating func recordRenderedLayout(_ preset: PostingPreset, forDays renderedDays: [String]) {
        for name in renderedDays {
            days[name]?.renderedPostingPreset = preset
        }
    }

    mutating func recordMediaOutcome(day: String, error: String?, warning: String?) -> Bool {
        guard mediaErrors[day] != error || mediaWarnings[day] != warning else { return false }
        if let error { mediaErrors[day] = error } else { mediaErrors.removeValue(forKey: day) }
        if let warning { mediaWarnings[day] = warning } else { mediaWarnings.removeValue(forKey: day) }
        return true
    }
}

// MARK: - ShootType

enum ShootType: String, Codable, CaseIterable {
    case fullShow  = "Performance"
    case photoCall = "Photo Call"
    case rehearsal = "Rehearsal"
    case combo     = "Combo"

    var systemImage: String {
        switch self {
        case .fullShow:  return "music.mic"
        case .photoCall: return "camera.fill"
        case .rehearsal: return "arrow.2.circlepath"
        case .combo:     return "square.grid.2x2.fill"
        }
    }

    /// Value expected by the Python caption / blog generators.
    var pythonValue: String {
        switch self {
        case .fullShow:  return "performance"
        case .photoCall: return "photo_call"
        case .rehearsal: return "rehearsal"
        case .combo:     return "rehearsal_and_performance"
        }
    }
}

// MARK: - EventStage

enum EventStage: String, Codable, CaseIterable {
    case created          = "Event Created"
    case programUploaded  = "Program Uploaded"
    case ocrDone          = "OCR Complete"
    case photosAssigned   = "Photos Assigned"
    case assetsGenerated  = "Assets Generated"
    case captionsReviewed = "Captions Reviewed"
    case exported         = "Exported"

    var stepNumber: Int {
        EventStage.allCases.firstIndex(of: self).map { $0 + 1 } ?? 1
    }

    /// Human-readable label for the stage pill. Decoupled from rawValue (used for persistence).
    var displayLabel: String {
        switch self {
        case .created:          return "Created"
        case .programUploaded:  return "Program Uploaded"
        case .ocrDone:          return "Review Program"
        case .photosAssigned:   return "Assign Photos"
        case .assetsGenerated:  return "Assets Generated"
        // .captionsReviewed is a navigation state — the user is in the caption
        // review screen but hasn't approved yet. Approval jumps straight to
        // .exported, so this stage shouldn't claim a "reviewed" milestone.
        case .captionsReviewed: return "Assets Generated"
        case .exported:         return "Exported"
        }
    }
}

// MARK: - DayName

enum DayName: String, Codable, CaseIterable {
    case sunday, monday, tuesday, wednesday, thursday, friday

    var displayName: String { rawValue.capitalized }

    /// On-disk folder name used for exports. Numbered so Finder sorts
    /// them chronologically (0. Blog, 1. Sunday, 2. Monday, …).
    var folderName: String {
        switch self {
        case .sunday:    return "1. Sunday"
        case .monday:    return "2. Monday"
        case .tuesday:   return "3. Tuesday"
        case .wednesday: return "4. Wednesday"
        case .thursday:  return "5. Thursday"
        case .friday:    return "6. Friday"
        }
    }
}

// MARK: - PostingDay backward-compatible decoding

extension PostingDay {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day                 = try  c.decode(DayName.self,              forKey: .day)
        photoPaths          = try  c.decodeIfPresent([URL].self,                      forKey: .photoPaths)          ?? []
        tagHandles          = try  c.decodeIfPresent([String].self,                   forKey: .tagHandles)          ?? []
        nameMentions        = try  c.decodeIfPresent([String].self,                   forKey: .nameMentions)        ?? []
        screenRecordingPath = try  c.decodeIfPresent(URL.self,                        forKey: .screenRecordingPath)
        rawPhotoPath        = try  c.decodeIfPresent(URL.self,                        forKey: .rawPhotoPath)
        editedPhotoPath     = try  c.decodeIfPresent(URL.self,                        forKey: .editedPhotoPath)
        bwPhotoPath         = try  c.decodeIfPresent(URL.self,                        forKey: .bwPhotoPath)
        reelTargetDuration  = try  c.decodeIfPresent(Double.self,                     forKey: .reelTargetDuration)  ?? 20.0
        audioPath           = try  c.decodeIfPresent(URL.self,                        forKey: .audioPath)
        reelAudioSource     = try  c.decodeIfPresent(URL.self,                        forKey: .reelAudioSource)
        reelAudioTags       = try  c.decodeIfPresent(String.self,                     forKey: .reelAudioTags)       ?? ""
        scrollDuration      = try  c.decodeIfPresent(Double.self,                     forKey: .scrollDuration)      ?? 40.0
        reelSeed            = try  c.decodeIfPresent(Int.self,                        forKey: .reelSeed)
        collageSeed         = try  c.decodeIfPresent(Int.self,                        forKey: .collageSeed)
        cropOffsets         = try  c.decodeIfPresent([String: CropOffset].self,       forKey: .cropOffsets)         ?? [:]
        collageCropOffsets  = try  c.decodeIfPresent([String: CropOffset].self,        forKey: .collageCropOffsets)  ?? [:]
        reelCropOffsets     = try  c.decodeIfPresent([String: CropOffset].self,        forKey: .reelCropOffsets)     ?? [:]
        collageCellOverride  = try  c.decodeIfPresent([CollageCell].self,               forKey: .collageCellOverride)
        photoTags            = try  c.decodeIfPresent([String: [String]].self,         forKey: .photoTags)           ?? [:]
        selectedPerformerIDs = try  c.decodeIfPresent([UUID].self,                    forKey: .selectedPerformerIDs) ?? []
        notes                = try  c.decodeIfPresent(String.self,                    forKey: .notes)               ?? ""
        clipPaths            = try  c.decodeIfPresent([URL].self,                     forKey: .clipPaths)           ?? []
        fridayClipPlan       = try  c.decodeIfPresent(FridayClipPlan.self,            forKey: .fridayClipPlan)
        fridayClipOverride   = try  c.decodeIfPresent([ReelClipOverride].self,        forKey: .fridayClipOverride)
        fridayAudioDuckDB    = try  c.decodeIfPresent(Double.self,                    forKey: .fridayAudioDuckDB)   ?? -15.0
        fridayAudioMuted     = try  c.decodeIfPresent(Bool.self,                      forKey: .fridayAudioMuted)    ?? false
        titleCardMuted       = try  c.decodeIfPresent(Bool.self,                      forKey: .titleCardMuted)      ?? false
        coverPick            = try  c.decodeIfPresent(CoverPick.self,                 forKey: .coverPick)
        coverOverride        = try  c.decodeIfPresent(String.self,                    forKey: .coverOverride)
        // Encoded by the compiler and read back by nobody until #1022 found
        // it. Every day loaded from disk carried nil, so the stale design
        // sweep (#1010) saw no evidence on any day in the library and
        // refused to report anything, which is exactly what a correct
        // library looks like.
        renderedPostingPreset = try c.decodeIfPresent(PostingPreset.self,           forKey: .renderedPostingPreset)
    }

    /// This day's reel layout seed, minting and storing one when there is none.
    ///
    /// The one place a reel seed is decided (#1062). The collage sibling
    /// already worked this way, minting on the first render of a day with no
    /// seed and again when a new layout is asked for; the reel minted ONLY on
    /// a new layout, so a day that was never asked for one never got a seed at
    /// all and re-shuffled on every render.
    ///
    /// `generate` is a parameter so a test can pin the value rather than assert
    /// around a random one. The default is the same range the collage seed and
    /// the "New layout" button already use.
    @discardableResult
    mutating func ensureReelSeed(
        fresh: Bool = false,
        using generate: () -> Int = { Int.random(in: 1...999_999_999) }
    ) -> Int {
        if fresh || reelSeed == nil { reelSeed = generate() }
        // Force unwrapped deliberately: the line above is the only way to reach
        // here with nil, and it cannot leave one.
        return reelSeed!
    }

    /// Returns a copy with the given photos removed from photoPaths and from
    /// every per-photo map (crop offsets and tags, keyed by URL absoluteString)
    /// and collage cells (keyed by POSIX path). Used to drop references to
    /// files that no longer exist on disk.
    func removingPhotos(_ remove: Set<URL>) -> PostingDay {
        guard !remove.isEmpty else { return self }
        let removeKeys = Set(remove.map(\.absoluteString))
        let removePaths = Set(remove.map(\.path))
        var pd = self
        pd.photoPaths = photoPaths.filter { !remove.contains($0) }
        pd.cropOffsets = cropOffsets.filter { !removeKeys.contains($0.key) }
        pd.collageCropOffsets = collageCropOffsets.filter { !removeKeys.contains($0.key) }
        pd.reelCropOffsets = reelCropOffsets.filter { !removeKeys.contains($0.key) }
        pd.photoTags = photoTags.filter { !removeKeys.contains($0.key) }
        if let cells = collageCellOverride {
            pd.collageCellOverride = cells.filter { !removePaths.contains($0.photoPath) }
        }
        // The standalone media slots aren't in photoPaths, so they have to be
        // cleared by hand or the day keeps referencing a file that's gone.
        for slot in MediaSlot.allCases where remove.contains(where: { $0 == pd[slot] }) {
            pd[slot] = nil
        }
        return pd
    }

    /// Returns a copy with photo URLs swapped per `remap` (old -> new), carrying
    /// every per-photo entry (crop offsets, tags, collage cells) over to the new
    /// URL. Used to re-link photos whose files moved to a new location.
    func rebindingPhotos(_ remap: [URL: URL]) -> PostingDay {
        guard !remap.isEmpty else { return self }
        let keyRemap = Dictionary(uniqueKeysWithValues: remap.map { ($0.key.absoluteString, $0.value.absoluteString) })
        let pathRemap = Dictionary(uniqueKeysWithValues: remap.map { ($0.key.path, $0.value.path) })
        var pd = self
        pd.photoPaths = photoPaths.map { remap[$0] ?? $0 }
        pd.cropOffsets = Self.remapKeys(cropOffsets, keyRemap)
        pd.collageCropOffsets = Self.remapKeys(collageCropOffsets, keyRemap)
        pd.reelCropOffsets = Self.remapKeys(reelCropOffsets, keyRemap)
        pd.photoTags = Self.remapKeys(photoTags, keyRemap)
        if let cells = collageCellOverride {
            pd.collageCellOverride = cells.map {
                var cell = $0
                if let newPath = pathRemap[$0.photoPath] { cell.photoPath = newPath }
                return cell
            }
        }
        // The standalone media slots aren't in photoPaths, so they move only if
        // they're remapped here. The B&W photo in particular has no filename
        // fallback anywhere downstream, so a stale path stays broken.
        for slot in MediaSlot.allCases {
            if let current = pd[slot], let moved = remap[current] { pd[slot] = moved }
        }
        return pd
    }

    private static func remapKeys<V>(_ dict: [String: V], _ keyRemap: [String: String]) -> [String: V] {
        guard !keyRemap.isEmpty, !dict.isEmpty else { return dict }
        var out: [String: V] = [:]
        for (key, value) in dict { out[keyRemap[key] ?? key] = value }
        return out
    }

    /// Returns a copy with clip URLs swapped per `remap` (old -> new), carrying
    /// fridayClipPlan's selections and fridayClipOverride entries over to the
    /// new URL. Mirrors rebindingPhotos so clip references survive MediaReclaim
    /// copying files into app storage (feedback_layout_json_paths_go_stale).
    func rebindingClips(_ remap: [URL: URL]) -> PostingDay {
        guard !remap.isEmpty else { return self }
        let pathRemap = Dictionary(uniqueKeysWithValues: remap.map { ($0.key.path, $0.value.path) })
        var pd = self
        pd.clipPaths = clipPaths.map { remap[$0] ?? $0 }
        if var plan = fridayClipPlan {
            plan.selections = plan.selections.map {
                var sel = $0
                if let newPath = pathRemap[$0.clipPath] { sel.clipPath = newPath }
                return sel
            }
            pd.fridayClipPlan = plan
        }
        if let overrides = fridayClipOverride {
            pd.fridayClipOverride = overrides.map {
                var o = $0
                if let newPath = pathRemap[$0.clipPath] { o.clipPath = newPath }
                return o
            }
        }
        return pd
    }

    /// Returns a copy with `urls` appended to clipPaths (Friday clip import,
    /// #135). Appends rather than replaces so importing in multiple batches
    /// doesn't drop earlier picks.
    func addingClips(_ urls: [URL]) -> PostingDay {
        guard !urls.isEmpty else { return self }
        var pd = self
        pd.clipPaths.append(contentsOf: urls)
        return pd
    }

    /// What the manual override editor (#135) displays: the user's own edit
    /// once one exists, otherwise the AI's plan re-derived as a starting
    /// point (order 0-based, everything included) so the editor never opens
    /// on an empty list. Same nil-means-AI / non-nil-means-user semantics as
    /// collageCellOverride.
    var effectiveFridayOverride: [ReelClipOverride] {
        if let override = fridayClipOverride { return override }
        guard let plan = fridayClipPlan else { return [] }
        return plan.selections.enumerated().map { index, sel in
            ReelClipOverride(clipPath: sel.clipPath, order: index, included: true,
                             trimIn: sel.trimIn, trimOut: sel.trimOut,
                             cropX: sel.cropX, cropY: sel.cropY)
        }
    }

    /// "Skip clips, keep story-only" (#135's fail-loud "< 3 usable clips"
    /// banner): drops the imported clips so future regens fall straight
    /// through to the existing before/after path instead of retrying a
    /// doomed clip pipeline. Leaves every other field untouched.
    func clearingFridayClips() -> PostingDay {
        var pd = self
        pd.clipPaths = []
        return pd
    }
}

// MARK: - CollageCell

/// One photo cell in the Wednesday collage layout.
/// x, y, w, h are in canvas pixels (1080 × 1920).  All fields are var so SwiftUI
/// can mutate them when the user drags a frame divider in the collage editor.
struct CollageCell: Codable, Hashable, Identifiable {
    var id: String { photoPath }
    var photoPath: String
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    enum CodingKeys: String, CodingKey {
        case photoPath = "photo_path"
        case x, y, w, h
    }
}

extension CollageCell {
    /// Re-links layout-JSON cell paths to a day's current photo set by filename.
    /// The layout JSON records whatever path Python used at generation time, but
    /// MediaReclaim may since have copied that file into app storage and
    /// rewritten the day's photoPaths. Without rebasing, a dragged thumbnail's
    /// (current) path no longer equals any cell's (old) path, so a swap can't
    /// find the source cell and the photo is duplicated in the collage.
    static func rebasing(_ cells: [CollageCell], toCurrentPhotos photoURLs: [URL]) -> [CollageCell] {
        guard !photoURLs.isEmpty else { return cells }
        let currentByName = Dictionary(
            photoURLs.map { ($0.lastPathComponent, $0.path) },
            uniquingKeysWith: { first, _ in first }
        )
        return cells.map { cell in
            var cell = cell
            let name = (cell.photoPath as NSString).lastPathComponent
            if let current = currentByName[name], current != cell.photoPath {
                cell.photoPath = current
            }
            return cell
        }
    }

    /// The saved layout reconciled against a day's current photo set, or nil when
    /// it no longer describes that set and must give way to the automatic layout.
    ///
    /// A layout records whatever paths were in play when it was made, and two
    /// things later invalidate it. MediaReclaim copies an original into app
    /// storage and rewrites the day's photoPaths, which `rebasing` repairs. And
    /// changing the day's photos (or switching posting preset) leaves cells naming
    /// photos the day no longer has, which nothing can repair: honouring such a
    /// layout means asking the renderer to open a file that may be long gone. That
    /// is exactly how a Wednesday with a leftover 10 cell layout and 4 assigned
    /// photos stopped producing a collage, and therefore a story, on every regen.
    ///
    /// Usable means a one to one match: every cell resolves to a current photo and
    /// every current photo has a cell, so no photo is dropped or drawn twice.
    static func usable(_ cells: [CollageCell]?, forPhotos photoURLs: [URL]) -> [CollageCell]? {
        guard let cells, !cells.isEmpty, !photoURLs.isEmpty,
              cells.count == photoURLs.count
        else { return nil }
        let rebased = rebasing(cells, toCurrentPhotos: photoURLs)
        guard Set(rebased.map(\.photoPath)) == Set(photoURLs.map(\.path)) else { return nil }
        // And it has to be renderable (#967, #970). A layout saved before the
        // save path refused one, or by an editor that skipped the check, is
        // still on disk, and this is the last thing between it and an export
        // that draws a photograph over the branding or off the canvas. nil
        // falls back to the automatic masonry, which is the same answer this
        // already gives a layout that no longer describes the day's photos.
        // No strip band, for the reason `saving` gives below.
        guard layoutProblems(rebased).isEmpty else { return nil }
        return rebased
    }

    /// The cells to STORE, or nil when this layout must not be saved.
    ///
    /// The write side of the same rule (#967). Every divider drag wrote its
    /// geometry straight into the override with nothing checking it, so an
    /// editing path that produced an impossible layout persisted it and the
    /// export drew it. Refusing here keeps the previous layout, which is a
    /// state the editor already handles, rather than storing one that cannot
    /// be drawn.
    /// No strip band is passed, deliberately. `brandedStripBand` INFERS where
    /// the strip is from these same cells, so a `covers_strip` verdict here
    /// could only confirm that the inference agrees with itself (L70): grow a
    /// row down over the strip and the inferred band moves down with it.
    /// Checking it needs the position the layout was BUILT with, which nothing
    /// records; #970 stays open for that. The predicate is written and tested
    /// against an explicit band so it is ready when there is one to give it.
    static func saving(_ cells: [CollageCell]) -> [CollageCell]? {
        layoutProblems(cells).isEmpty ? cells : nil
    }

    /// Every reason this set of cells cannot be rendered, or an empty list.
    ///
    /// Every divider drag writes cell geometry straight into the saved
    /// override, and `CollageRenderer.render` composites those exact cells over
    /// the base PNG, so an impossible layout is not a preview problem: it is
    /// what gets exported and what is written back to events.json (#967, #970).
    /// #965 fixed the one drag known to produce one; this is the rule the SAVE
    /// has to satisfy whatever produced it, so a future editor inherits the
    /// refusal rather than having to remember it.
    ///
    /// Codes rather than sentences, and the rule with its cases lives in
    /// `tests/fixtures/collage_layout_validity.json`, asserted from here and
    /// from Python, because the geometry is implemented twice and nothing else
    /// forces the two to agree (L26).
    ///
    /// The strip band is passed in rather than found here: where it sits
    /// depends on how many rows are above it, and a validator that inferred it
    /// its own way would be a second answer to the same question (L263).
    /// `brandedStripBand(in:)` is the one place that answers it.
    static func layoutProblems(_ cells: [CollageCell],
                               stripBand: (top: Int, height: Int)? = nil,
                               canvas: CGSize = CollageGeometry.canvasSize) -> [String] {
        guard !cells.isEmpty else { return ["empty"] }
        var problems: Set<String> = []
        let width = Int(canvas.width), height = Int(canvas.height)

        for cell in cells {
            if cell.w < minCollageCellPx || cell.h < minCollageCellPx {
                problems.insert("under_floor")
            }
            if cell.x < 0 || cell.y < 0 || cell.x + cell.w > width || cell.y + cell.h > height {
                problems.insert("off_canvas")
            }
        }

        for (i, a) in cells.enumerated() {
            for b in cells.dropFirst(i + 1) {
                // Touching edge to edge is not overlapping: a gap of zero is
                // how two cells in a row sit beside each other.
                if a.x < b.x + b.w, b.x < a.x + a.w, a.y < b.y + b.h, b.y < a.y + a.h {
                    problems.insert("overlapping")
                }
            }
        }

        if let band = stripBand, band.height > 0 {
            let bottom = band.top + band.height
            for cell in cells where cell.y < bottom && band.top < cell.y + cell.h {
                problems.insert("covers_strip")
            }
        }
        return problems.sorted()
    }

    /// Where the branded centre strip sits in this layout, or nil when it has
    /// none.
    ///
    /// The band is the largest gap between two rows, and only when it is wider
    /// than an ordinary row gap: a single row layout has no strip, and reading
    /// its absence as a band at zero would refuse every one of them (L214).
    /// Derived from the dividers rather than from a written offset, because how
    /// far down the strip sits depends on how many rows are above it.
    static func brandedStripBand(in cells: [CollageCell]) -> (top: Int, height: Int)? {
        computeCollageDividers(cells)
            .filter { $0.kind == .horizontal && $0.isBrandedStrip }
            .max { $0.actualGapPx < $1.actualGapPx }
            .map { (top: $0.canvasPos, height: $0.actualGapPx) }
    }

    /// Drops `droppedPath` onto the cell at `idx`, swapping it with whichever
    /// cell currently holds that photo so the photo never lands in the collage
    /// twice. Matches the source cell by exact path first, then by filename
    /// (covers a path the layout JSON recorded before MediaReclaim rewrote it).
    /// Returns the updated cells, or nil when the drop is a no-op (the dropped
    /// photo is already in the target cell).
    static func applyingDrop(of droppedPath: String, ontoCellAt idx: Int, in cells: [CollageCell]) -> [CollageCell]? {
        guard cells.indices.contains(idx) else { return nil }
        var newCells = cells
        let currentPath = newCells[idx].photoPath
        guard droppedPath != currentPath else { return nil }
        let droppedName = (droppedPath as NSString).lastPathComponent
        let otherIdx = newCells.firstIndex(where: { $0.photoPath == droppedPath })
            ?? newCells.firstIndex(where: { ($0.photoPath as NSString).lastPathComponent == droppedName })
        if let otherIdx, otherIdx != idx {
            newCells[otherIdx].photoPath = currentPath
        }
        newCells[idx].photoPath = droppedPath
        return newCells
    }

    // Persisted inside events.json via PostingDay.collageCellOverride: every
    // field must decodeIfPresent or a schema change wipes saved events.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath) ?? ""
        x         = try c.decodeIfPresent(Int.self,    forKey: .x)         ?? 0
        y         = try c.decodeIfPresent(Int.self,    forKey: .y)         ?? 0
        w         = try c.decodeIfPresent(Int.self,    forKey: .w)         ?? 0
        h         = try c.decodeIfPresent(Int.self,    forKey: .h)         ?? 0
    }
}

// MARK: - Friday clip reel

/// How a clip transitions to the next one in the cut. Claude picks this per
/// cut (Stage 2); the render step consumes it.
enum ClipTransition: String, Codable, Hashable {
    case cut
    case crossfade
}

extension ClipTransition {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = (try? c.decode(RawValue.self)).flatMap(ClipTransition.init(rawValue:)) ?? .cut
    }
}

/// One clip's placement in Claude's Stage 2 selection: the trim window
/// (already clamped server-side to Stage 1's validated range) and how it
/// transitions to the next clip in the cut.
struct FridayClipSelection: Codable, Hashable, Identifiable {
    var id: String { clipPath }
    var clipPath: String
    var trimIn: Double
    var trimOut: Double
    var transition: ClipTransition
    /// Per-shot crop (plan #148, Phase 2): same [-1, 1] convention as
    /// CropOffset, 0 = centered. Already server-side clamped and gated in
    /// select_reel_clips.apply_selection, so cropConfidence here reflects
    /// the gate's final decision, not necessarily Claude's raw claim.
    var cropX: Double
    var cropY: Double
    var cropConfidence: String

    enum CodingKeys: String, CodingKey {
        case clipPath = "clip_path"
        case trimIn = "trim_in"
        case trimOut = "trim_out"
        case transition
        case cropX = "crop_x"
        case cropY = "crop_y"
        case cropConfidence = "crop_confidence"
    }

    init(clipPath: String, trimIn: Double, trimOut: Double, transition: ClipTransition,
         cropX: Double = 0, cropY: Double = 0, cropConfidence: String = "low") {
        self.clipPath = clipPath
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.transition = transition
        self.cropX = cropX
        self.cropY = cropY
        self.cropConfidence = cropConfidence
    }

    // Persisted inside events.json via PostingDay.fridayClipPlan: every field
    // must decodeIfPresent or a schema change wipes saved events.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clipPath       = try c.decodeIfPresent(String.self, forKey: .clipPath)   ?? ""
        trimIn         = try c.decodeIfPresent(Double.self, forKey: .trimIn)     ?? 0
        trimOut        = try c.decodeIfPresent(Double.self, forKey: .trimOut)    ?? 0
        transition     = try c.decodeIfPresent(ClipTransition.self, forKey: .transition) ?? .cut
        cropX          = try c.decodeIfPresent(Double.self, forKey: .cropX) ?? 0
        cropY          = try c.decodeIfPresent(Double.self, forKey: .cropY) ?? 0
        cropConfidence = try c.decodeIfPresent(String.self, forKey: .cropConfidence) ?? "low"
    }
}

/// Claude's Stage 2 output for the Friday clip reel: the ordered, trimmed
/// selection plus a one-line rationale surfaced under the reel player.
struct FridayClipPlan: Codable, Hashable {
    var selections: [FridayClipSelection] = []
    var rationale: String = ""

    enum CodingKeys: String, CodingKey {
        case selections
        case rationale
    }

    init(selections: [FridayClipSelection] = [], rationale: String = "") {
        self.selections = selections
        self.rationale = rationale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selections = try c.decodeIfPresent([FridayClipSelection].self, forKey: .selections) ?? []
        rationale  = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
    }
}

/// Claude's cover-image pick for Thursday's scroll reel or Friday's auto-cut
/// clip reel: the source photo/frame plus a one-line rationale shown under
/// the cover thumbnail (mirrors FridayClipPlan's rationale display).
struct CoverPick: Codable, Hashable {
    var sourcePath: String = ""
    var rationale: String = ""

    enum CodingKeys: String, CodingKey {
        case sourcePath = "source_path"
        case rationale
    }

    init(sourcePath: String = "", rationale: String = "") {
        self.sourcePath = sourcePath
        self.rationale = rationale
    }

    // Persisted inside events.json via PostingDay.coverPick: every field
    // must decodeIfPresent or a schema change wipes saved events.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        rationale  = try c.decodeIfPresent(String.self, forKey: .rationale)  ?? ""
    }
}

/// A user's manual edit to the Friday clip reel: reorder, include/exclude,
/// or adjust the trim window for one clip. Stored separately from
/// fridayClipPlan (Claude's pass) so manual edits never trigger a re-cut.
/// Same override-layer principle as CollageCell (feedback_collage_edits_no_python_regen).
struct ReelClipOverride: Codable, Hashable, Identifiable {
    var id: String { clipPath }
    var clipPath: String
    var order: Int
    var included: Bool
    var trimIn: Double
    var trimOut: Double
    /// Per-shot crop (plan #148, Phase 2): carried over from the AI's
    /// FridayClipSelection (via PostingDay.effectiveFridayOverride) so a
    /// manual reorder/trim edit doesn't silently drop the AI's crop
    /// choice, and user-adjustable from the crop editor thereafter.
    var cropX: Double
    var cropY: Double

    enum CodingKeys: String, CodingKey {
        case clipPath = "clip_path"
        case order
        case included
        case trimIn = "trim_in"
        case trimOut = "trim_out"
        case cropX = "crop_x"
        case cropY = "crop_y"
    }

    init(clipPath: String, order: Int, included: Bool, trimIn: Double, trimOut: Double,
         cropX: Double = 0, cropY: Double = 0) {
        self.clipPath = clipPath
        self.order = order
        self.included = included
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.cropX = cropX
        self.cropY = cropY
    }

    // Persisted inside events.json via PostingDay.fridayClipOverride: every
    // field must decodeIfPresent or a schema change wipes saved events.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clipPath = try c.decodeIfPresent(String.self, forKey: .clipPath) ?? ""
        order    = try c.decodeIfPresent(Int.self,    forKey: .order)    ?? 0
        included = try c.decodeIfPresent(Bool.self,   forKey: .included) ?? true
        trimIn   = try c.decodeIfPresent(Double.self, forKey: .trimIn)   ?? 0
        trimOut  = try c.decodeIfPresent(Double.self, forKey: .trimOut)  ?? 0
        cropX    = try c.decodeIfPresent(Double.self, forKey: .cropX)    ?? 0
        cropY    = try c.decodeIfPresent(Double.self, forKey: .cropY)    ?? 0
    }
}

// MARK: - CropOffset

/// Per-photo crop adjustment, stored keyed by photo URL absoluteString.
/// x/y are in [-1, 1]: 0 = centred, ±1 = full shift to that edge.
/// scale ≥ 1 zooms the photo within its cell frame (1 = fill exactly, 2 = 2× zoom).
struct CropOffset: Codable, Hashable {
    /// The vertical framing every surface starts from: the photo's top edge.
    ///
    /// Performing-arts frames compose the subject in the upper part of the
    /// picture, so a centred crop quietly takes a slice off the heads. The
    /// pixels a fill has to discard come off the BOTTOM, always (#167). A crop
    /// the user has actually dragged still wins; this only moves the starting
    /// point. It applies to the fill case alone: a photo zoomed out below fill
    /// has nothing to crop, and both draw paths centre it regardless of `y`.
    static let topAnchoredY: Double = -1.0

    var x:     Double = 0    // horizontal: -1 = left, +1 = right
    var y:     Double = CropOffset.topAnchoredY  // vertical: -1 = top, +1 = bottom
    var scale: Double = 1.0  // zoom: 1 = default fill, >1 zooms in

    enum CodingKeys: String, CodingKey { case x, y, scale }
}

extension CropOffset {
    init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        x       = try c.decodeIfPresent(Double.self, forKey: .x)     ?? 0
        y       = try c.decodeIfPresent(Double.self, forKey: .y)     ?? CropOffset.topAnchoredY
        scale   = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
    }
}

// MARK: - PostingDay

struct PostingDay: Codable, Hashable {
    var day: DayName
    var photoPaths: [URL] = []
    var tagHandles: [String] = []
    var nameMentions: [String] = []
    // Tuesday speed edit reel inputs
    var screenRecordingPath: URL? = nil
    var rawPhotoPath: URL? = nil       // Tuesday closing frame + Friday before/after
    var editedPhotoPath: URL? = nil    // Tuesday closing frame + Friday before/after
    var bwPhotoPath: URL? = nil        // Optional B&W after. When set, Tuesday reel + Friday graphic become a 3-photo (RAW / color / B&W) treatment
    var reelTargetDuration: Double = 20.0  // Tuesday: timelapse target (seconds, 10–30)
    // Thursday scroll reel
    var audioPath: URL? = nil
    // The track that actually ended up in the rendered reel, and what it was
    // matched on. Distinct from `audioPath`, which only ever holds a file Dan
    // uploaded himself: a Jamendo fetch left no trace in the app at all, so the
    // music in the reel had no name anywhere on screen (#262). Tags are empty
    // for an uploaded file, which was not matched on anything.
    var reelAudioSource: URL? = nil
    var reelAudioTags: String = ""
    var scrollDuration: Double = 40.0  // Thursday: scroll animation duration (seconds, 15–60)
    /// Thursday: the reel's masonry layout seed.
    ///
    /// nil is a DEFECT rather than a default (#1062). It used to mean "random
    /// each time", and `build_collage_strip` duly seeded from system entropy,
    /// so every regenerate reshuffled all 234 photographs and adjusting one
    /// crop re-laid-out the whole reel. It also made `SpeculativeReelRenderer`
    /// wrong in a way its own comment denied: it calls the reel a pure function
    /// of five inputs while one of them was absent, so a background pre-render
    /// and the render it was adopted for could be two different collages.
    ///
    /// Measured in the live store on 2026-08-31: 19 of 21 Thursday days carry
    /// no seed. They get one on their next render, which is what
    /// `ensureReelSeed` is for.
    var reelSeed: Int? = nil
    // Wednesday collage
    var collageSeed: Int? = nil        // nil = random each time
    var cropOffsets: [String: CropOffset] = [:]        // carousel crop — keyed by photo URL absoluteString
    var collageCropOffsets: [String: CropOffset] = [:] // collage-specific crop — separate from carousel
    var reelCropOffsets: [String: CropOffset] = [:]    // Thursday reel per-photo crop — independent from carousel/collage
    var collageCellOverride: [CollageCell]? = nil      // user-adjusted frame layout (nil = use Python layout)
    var photoTags: [String: [String]] = [:]            // collage-carousel days: per-photo people tags, keyed by photo URL absoluteString
    // Performers selected as appearing in this day's photos — drives auto handle/name merging
    var selectedPerformerIDs: [UUID] = []
    // Shooter's observations — passed to caption generator to produce voice-y, specific captions
    var notes: String = ""
    // Friday auto-cut clip reel: imported video clips for the week's event
    var clipPaths: [URL] = []
    // Claude's Stage 2 output (selected/ordered/trimmed clips + rationale). nil = not yet cut or no clips.
    var fridayClipPlan: FridayClipPlan? = nil
    // User's manual reorder/include-exclude/trim edits. nil = defer to fridayClipPlan,
    // non-nil = user's edit wins forever (same nil-means-AI / non-nil-means-user semantics as collageCellOverride).
    var fridayClipOverride: [ReelClipOverride]? = nil
    // How far under the music bed each clip's own audio is ducked when the
    // Friday reel is rendered. Dan's default call (-15dB); adjustable per
    // event since some weeks he wants clip audio fully muted instead.
    var fridayAudioDuckDB: Double = -15.0
    var fridayAudioMuted: Bool = false
    // Title card overlay (plan #148, Phase 3): the event name as an
    // animated reveal on the reel's opening seconds. On by default (Dan's
    // call, 2026-07-09); this only ever turns it off for one event.
    var titleCardMuted: Bool = false
    // Instagram grid cover image (Thursday scroll reel + Friday auto-cut clip
    // reel only). Claude's pick; nil = not yet generated. Same nil-means-AI /
    // non-nil-means-user override semantics as fridayClipPlan/fridayClipOverride.
    var coverPick: CoverPick? = nil
    var coverOverride: String? = nil
    /// The posting layout this day's CURRENT images were drawn under (#1010).
    ///
    /// A layout switch redraws only the days it changes, so a redraw that fails
    /// leaves the event saying one layout while that day's collage is still the
    /// other one's. Nothing recorded that, and the export shipped it.
    ///
    /// nil means no evidence, not "matches": every day saved before this
    /// existed carries nil, which is precisely the backlog a marker based check
    /// cannot see (L223), and reading the absence as a mismatch would refuse
    /// every export in the library at once. It is filled in by the next render
    /// of that day.
    var renderedPostingPreset: PostingPreset? = nil
}

// MARK: - Standalone media slots

/// The single-file media references a day carries outside its photo grid. They
/// live in named fields rather than an array, so anything that walks "every
/// file this day points at" (the missing-file scan, a re-link, a removal) has
/// to enumerate them. This enum is that enumeration, so a new slot can't be
/// added and silently skipped by all three.
enum MediaSlot: String, CaseIterable, Hashable {
    case rawPhoto
    case editedPhoto
    case bwPhoto
    case screenRecording

    /// How the slot is named on screen, for a message that has to say which
    /// control to go fix.
    var displayName: String {
        switch self {
        case .rawPhoto:        return "RAW photo"
        case .editedPhoto:     return "edited photo"
        case .bwPhoto:         return "B&W photo"
        case .screenRecording: return "screen recording"
        }
    }
}

extension PostingDay {
    /// Reads/writes a standalone media slot by name, so callers can loop over
    /// `MediaSlot.allCases` instead of repeating four lines each time.
    subscript(slot: MediaSlot) -> URL? {
        get {
            switch slot {
            case .rawPhoto:        return rawPhotoPath
            case .editedPhoto:     return editedPhotoPath
            case .bwPhoto:         return bwPhotoPath
            case .screenRecording: return screenRecordingPath
            }
        }
        set {
            switch slot {
            case .rawPhoto:        rawPhotoPath = newValue
            case .editedPhoto:     editedPhotoPath = newValue
            case .bwPhoto:         bwPhotoPath = newValue
            case .screenRecording: screenRecordingPath = newValue
            }
        }
    }
}

// MARK: - Event-wide photo re-link

extension Event {
    /// Applies a photo remap (old -> new) to every day and to the derived blog
    /// photo list, so a re-link moves EVERY reference to a moved file: the day
    /// grid, its crops and tags, the collage layout, and the standalone media
    /// slots. Rebinding a throwaway copy of a day and writing three fields back
    /// is what let the collage layout and the B&W photo keep pointing at a dead
    /// folder after a re-link (#177).
    func rebindingPhotos(_ remap: [URL: URL]) -> Event {
        guard !remap.isEmpty else { return self }
        var ev = self
        for (key, day) in days { ev.days[key] = day.rebindingPhotos(remap) }
        ev.blogPhotoPaths = blogPhotoPaths.map { remap[$0] ?? $0 }
        return ev
    }

    /// Drops every reference to the given photos across every day and the blog
    /// photo list. Counterpart to `rebindingPhotos` for the "Remove missing"
    /// route.
    func removingPhotos(_ remove: Set<URL>) -> Event {
        guard !remove.isEmpty else { return self }
        var ev = self
        for (key, day) in days { ev.days[key] = day.removingPhotos(remove) }
        ev.blogPhotoPaths = blogPhotoPaths.filter { !remove.contains($0) }
        return ev
    }
}
