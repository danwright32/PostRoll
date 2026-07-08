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

    // Event-wide handles applied to every day's caption (org, venue, recurring tags)
    var eventHandles: String = ""

    /// Per-event posting layout. `nil` means follow the app wide default
    /// (`PostingPreset.current`); set on the Export page to give one event a
    /// different layout without changing the default for other events (#66).
    var postingPresetOverride: PostingPreset? = nil

    /// The layout this event actually uses: its own override, or the app wide
    /// default when it has none.
    var effectivePostingPreset: PostingPreset {
        postingPresetOverride ?? PostingPreset.current
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
        programImagePaths = try c.decodeIfPresent([URL].self,                      forKey: .programImagePaths) ?? []
        programPDFPath    = try c.decodeIfPresent(URL.self,                        forKey: .programPDFPath)
        programPDFFingerprint = try c.decodeIfPresent(String.self,                 forKey: .programPDFFingerprint)
        ocrResult         = try c.decodeIfPresent(OCRResult.self,                  forKey: .ocrResult)
        ocrReviewDone     = try c.decodeIfPresent(Bool.self,                       forKey: .ocrReviewDone)     ?? false
        pendingFlags      = try c.decodeIfPresent([OCRFlag].self,                  forKey: .pendingFlags)      ?? []
        pendingFlagsError = try c.decodeIfPresent(String.self,                     forKey: .pendingFlagsError)
        eventURL          = try c.decodeIfPresent(String.self,                     forKey: .eventURL)          ?? ""
        eventHandles      = try c.decodeIfPresent(String.self,                     forKey: .eventHandles)      ?? ""
        postingPresetOverride = try c.decodeIfPresent(PostingPreset.self,          forKey: .postingPresetOverride)
        days              = try c.decodeIfPresent([String: PostingDay].self,       forKey: .days)              ?? [:]
        blogPhotoPaths    = try c.decodeIfPresent([URL].self,                      forKey: .blogPhotoPaths)    ?? []
        weekResult        = try c.decodeIfPresent(WeekGenerationResult.self,       forKey: .weekResult)
        previewMediaPaths = try c.decodeIfPresent([String: [String: String]].self, forKey: .previewMediaPaths) ?? [:]
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

    enum CodingKeys: String, CodingKey {
        case clipPath = "clip_path"
        case trimIn = "trim_in"
        case trimOut = "trim_out"
        case transition
    }

    init(clipPath: String, trimIn: Double, trimOut: Double, transition: ClipTransition) {
        self.clipPath = clipPath
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.transition = transition
    }

    // Persisted inside events.json via PostingDay.fridayClipPlan: every field
    // must decodeIfPresent or a schema change wipes saved events.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clipPath   = try c.decodeIfPresent(String.self, forKey: .clipPath)   ?? ""
        trimIn     = try c.decodeIfPresent(Double.self, forKey: .trimIn)     ?? 0
        trimOut    = try c.decodeIfPresent(Double.self, forKey: .trimOut)    ?? 0
        transition = try c.decodeIfPresent(ClipTransition.self, forKey: .transition) ?? .cut
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

    enum CodingKeys: String, CodingKey {
        case clipPath = "clip_path"
        case order
        case included
        case trimIn = "trim_in"
        case trimOut = "trim_out"
    }

    init(clipPath: String, order: Int, included: Bool, trimIn: Double, trimOut: Double) {
        self.clipPath = clipPath
        self.order = order
        self.included = included
        self.trimIn = trimIn
        self.trimOut = trimOut
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
    }
}

// MARK: - CropOffset

/// Per-photo crop adjustment, stored keyed by photo URL absoluteString.
/// x/y are in [-1, 1]: 0 = centred, ±1 = full shift to that edge.
/// scale ≥ 1 zooms the photo within its cell frame (1 = fill exactly, 2 = 2× zoom).
struct CropOffset: Codable, Hashable {
    var x:     Double = 0    // horizontal: -1 = left, +1 = right
    var y:     Double = 0    // vertical:   -1 = top,  +1 = bottom
    var scale: Double = 1.0  // zoom: 1 = default fill, >1 zooms in

    enum CodingKeys: String, CodingKey { case x, y, scale }
}

extension CropOffset {
    init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        x       = try c.decodeIfPresent(Double.self, forKey: .x)     ?? 0
        y       = try c.decodeIfPresent(Double.self, forKey: .y)     ?? 0
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
    var scrollDuration: Double = 40.0  // Thursday: scroll animation duration (seconds, 15–60)
    var reelSeed: Int? = nil           // Thursday: layout seed (nil = random each time)
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
}
