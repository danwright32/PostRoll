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
    var ocrResult: OCRResult?
    var ocrReviewDone: Bool = false
    var eventURL: String = ""  // Optional event page URL — used to enrich OCR data

    // Event-wide handles applied to every day's caption (org, venue, recurring tags)
    var eventHandles: String = ""

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
        ocrResult         = try c.decodeIfPresent(OCRResult.self,                  forKey: .ocrResult)
        ocrReviewDone     = try c.decodeIfPresent(Bool.self,                       forKey: .ocrReviewDone)     ?? false
        eventURL          = try c.decodeIfPresent(String.self,                     forKey: .eventURL)          ?? ""
        eventHandles      = try c.decodeIfPresent(String.self,                     forKey: .eventHandles)      ?? ""
        days              = try c.decodeIfPresent([String: PostingDay].self,       forKey: .days)              ?? [:]
        blogPhotoPaths    = try c.decodeIfPresent([URL].self,                      forKey: .blogPhotoPaths)    ?? []
        weekResult        = try c.decodeIfPresent(WeekGenerationResult.self,       forKey: .weekResult)
        previewMediaPaths = try c.decodeIfPresent([String: [String: String]].self, forKey: .previewMediaPaths) ?? [:]
        exportPath        = try c.decodeIfPresent(URL.self,                        forKey: .exportPath)
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
        case .captionsReviewed: return "Captions Reviewed"
        case .exported:         return "Exported"
        }
    }
}

// MARK: - DayName

enum DayName: String, Codable, CaseIterable {
    case sunday, monday, tuesday, wednesday, thursday, friday

    var displayName: String { rawValue.capitalized }
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
        reelTargetDuration  = try  c.decodeIfPresent(Double.self,                     forKey: .reelTargetDuration)  ?? 20.0
        audioPath           = try  c.decodeIfPresent(URL.self,                        forKey: .audioPath)
        scrollDuration      = try  c.decodeIfPresent(Double.self,                     forKey: .scrollDuration)      ?? 30.0
        reelSeed            = try  c.decodeIfPresent(Int.self,                        forKey: .reelSeed)
        collageSeed         = try  c.decodeIfPresent(Int.self,                        forKey: .collageSeed)
        cropOffsets         = try  c.decodeIfPresent([String: CropOffset].self,       forKey: .cropOffsets)         ?? [:]
        collageCropOffsets  = try  c.decodeIfPresent([String: CropOffset].self,        forKey: .collageCropOffsets)  ?? [:]
        reelCropOffsets     = try  c.decodeIfPresent([String: CropOffset].self,        forKey: .reelCropOffsets)     ?? [:]
        collageCellOverride = try  c.decodeIfPresent([CollageCell].self,               forKey: .collageCellOverride)
        notes               = try  c.decodeIfPresent(String.self,                     forKey: .notes)               ?? ""
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
    var reelTargetDuration: Double = 20.0  // Tuesday: timelapse target (seconds, 10–30)
    // Thursday scroll reel
    var audioPath: URL? = nil
    var scrollDuration: Double = 30.0  // Thursday: scroll animation duration (seconds, 15–60)
    var reelSeed: Int? = nil           // Thursday: layout seed (nil = random each time)
    // Wednesday collage
    var collageSeed: Int? = nil        // nil = random each time
    var cropOffsets: [String: CropOffset] = [:]        // carousel crop — keyed by photo URL absoluteString
    var collageCropOffsets: [String: CropOffset] = [:] // collage-specific crop — separate from carousel
    var reelCropOffsets: [String: CropOffset] = [:]    // Thursday reel per-photo crop — independent from carousel/collage
    var collageCellOverride: [CollageCell]? = nil      // user-adjusted frame layout (nil = use Python layout)
    // Shooter's observations — passed to caption generator to produce voice-y, specific captions
    var notes: String = ""
}
