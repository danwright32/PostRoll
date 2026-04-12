import Foundation

struct Event: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var org: String
    var venue: String
    var date: Date
    var shootType: ShootType
    var stage: EventStage = .created

    // Program OCR inputs
    var programImagePaths: [URL] = []
    var ocrResult: OCRResult?
    var ocrReviewDone: Bool = false

    // Per-day photo assignments (keyed by DayName.rawValue)
    var days: [String: PostingDay] = [:]

    // Blog
    var blogPhotoPaths: [URL] = []

    // Generated content (captions + blog)
    var weekResult: WeekGenerationResult?

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

// MARK: - ShootType

enum ShootType: String, Codable, CaseIterable {
    case fullShow  = "Full Show"
    case photoCall = "Photo Call"
    case rehearsal = "Rehearsal"
    case combo     = "Combo"

    var systemImage: String {
        switch self {
        case .fullShow:  return "theatermasks.fill"
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

    var badgeColor: String {
        switch self {
        case .created:          return "gray"
        case .programUploaded:  return "blue"
        case .ocrDone:          return "purple"
        case .photosAssigned:   return "orange"
        case .assetsGenerated:  return "yellow"
        case .captionsReviewed: return "teal"
        case .exported:         return "green"
        }
    }
}

// MARK: - DayName

enum DayName: String, Codable, CaseIterable {
    case sunday, monday, tuesday, wednesday, thursday, friday

    var displayName: String { rawValue.capitalized }
}

// MARK: - CropOffset

/// Per-photo crop adjustment, stored keyed by photo URL absoluteString.
/// Values are in [-1, 1]: 0 = default position, ±1 = full shift toward that edge.
struct CropOffset: Codable, Hashable {
    var x: Double = 0   // horizontal: -1 = left, +1 = right
    var y: Double = 0   // vertical:   -1 = top,  +1 = bottom
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
    var cropOffsets: [String: CropOffset] = [:]  // keyed by photo URL absoluteString
    // Shooter's observations — passed to caption generator to produce voice-y, specific captions
    var notes: String = ""
}
