import Foundation

// MARK: - Per-day caption result (mirrors Python generate_captions output)

struct DayCaption: Codable, Hashable {
    var caption: String = ""
    var hashtags: [String] = []
    var altTexts: [String] = []
    var sceneLabels: [String?] = []

    enum CodingKeys: String, CodingKey {
        case caption, hashtags
        case altTexts   = "alt_texts"
        case sceneLabels = "scene_labels"
    }

    /// Caption + hashtags as a ready-to-paste string.
    var formatted: String {
        let tags = hashtags.joined(separator: " ")
        return caption.isEmpty ? tags : "\(caption)\n\n\(tags)"
    }
}

// MARK: - Blog post result (mirrors Python generate_blog output)

struct BlogOutput: Codable, Hashable {
    var title: String = ""
    var body: String = ""
    var photoCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case title, body
        case photoCount = "photo_count"
    }
}

// MARK: - Full week result (mirrors Python generate_week output)

struct WeekGenerationResult: Codable, Hashable {
    var sunday: DayCaption?
    var monday: DayCaption?
    var tuesday: DayCaption?
    var wednesday: DayCaption?
    var thursday: DayCaption?
    var friday: DayCaption?
    var blog: BlogOutput?
    var errors: [String: String] = [:]

    subscript(day: DayName) -> DayCaption? {
        get {
            switch day {
            case .sunday:    return sunday
            case .monday:    return monday
            case .tuesday:   return tuesday
            case .wednesday: return wednesday
            case .thursday:  return thursday
            case .friday:    return friday
            }
        }
        set {
            switch day {
            case .sunday:    sunday    = newValue
            case .monday:    monday    = newValue
            case .tuesday:   tuesday   = newValue
            case .wednesday: wednesday = newValue
            case .thursday:  thursday  = newValue
            case .friday:    friday    = newValue
            }
        }
    }

    var daysWithContent: [DayName] {
        DayName.allCases.filter { self[$0] != nil }
    }

    var errorCount: Int { errors.count }
}

// MARK: - GeneratedOutput (kept for future per-field editing in Step 5)

struct GeneratedOutput: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var suggestedText: String
    var finalText: String?
    var createdAt: Date = Date()

    var displayText: String { finalText ?? suggestedText }
    var hasFinal: Bool { finalText != nil }
}
