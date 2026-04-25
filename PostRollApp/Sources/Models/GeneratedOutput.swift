import Foundation

// MARK: - Per-day caption result (mirrors Python generate_captions output)

struct DayCaption: Codable, Hashable {
    var caption: String = ""
    var hashtags: [String] = []
    var altTexts: [String] = []
    var sceneLabels: [String?] = []
    /// The caption exactly as it came out of generation — never overwritten by edits.
    /// Empty until `WeekGenerationResult.stampOriginals()` is called after first decode.
    var generatedCaption: String = ""

    enum CodingKeys: String, CodingKey {
        case caption, hashtags
        case altTexts         = "alt_texts"
        case sceneLabels      = "scene_labels"
        case generatedCaption = "generated_caption"
    }

    /// Caption + hashtags as a ready-to-paste string.
    var formatted: String {
        let tags = hashtags.joined(separator: " ")
        guard !tags.isEmpty else { return caption }
        guard !caption.isEmpty else { return tags }
        // Don't append if the hashtags are already the last non-empty line of the caption
        let lastLine = caption
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        if lastLine == tags { return caption }
        return "\(caption)\n\n\(tags)"
    }

    var wasEdited: Bool {
        !generatedCaption.isEmpty && caption != generatedCaption
    }
}

// MARK: - Blog post result (mirrors Python generate_blog output)

struct BlogOutput: Codable, Hashable {
    var title: String = ""
    var body: String = ""
    var photoCount: Int = 0
    /// Body exactly as generated — never overwritten by edits.
    var generatedBody: String = ""

    enum CodingKeys: String, CodingKey {
        case title, body
        case photoCount    = "photo_count"
        case generatedBody = "generated_body"
    }

    var wasEdited: Bool {
        !generatedBody.isEmpty && body != generatedBody
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

    /// True when the run produced at least one caption (or blog), regardless
    /// of whether other days errored. Used to gate timing-store updates so a
    /// run that fails immediately and produces nothing doesn't skew the
    /// rolling-mean estimate downward.
    var hasAnyContent: Bool {
        blog != nil || DayName.allCases.contains { self[$0] != nil }
    }

    var daysWithContent: [DayName] {
        DayName.allCases.filter { self[$0] != nil }
    }

    var errorCount: Int { errors.count }

    /// Copy `caption` → `generatedCaption` and `body` → `generatedBody` for any
    /// day/blog that hasn't been stamped yet. Call once after decoding from Python output.
    mutating func stampOriginals() {
        for day in DayName.allCases {
            guard var cap = self[day], cap.generatedCaption.isEmpty else { continue }
            cap.generatedCaption = cap.caption
            self[day] = cap
        }
        if var b = blog, b.generatedBody.isEmpty {
            b.generatedBody = b.body
            blog = b
        }
    }
}

// MARK: - Backward-compatible decoding (decodeIfPresent so new fields don't break old saves)

extension DayCaption {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caption          = try c.decodeIfPresent(String.self,    forKey: .caption)          ?? ""
        hashtags         = try c.decodeIfPresent([String].self,  forKey: .hashtags)         ?? []
        altTexts         = try c.decodeIfPresent([String].self,  forKey: .altTexts)         ?? []
        sceneLabels      = try c.decodeIfPresent([String?].self, forKey: .sceneLabels)      ?? []
        generatedCaption = try c.decodeIfPresent(String.self,    forKey: .generatedCaption) ?? ""
    }
}

extension BlogOutput {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title         = try c.decodeIfPresent(String.self, forKey: .title)         ?? ""
        body          = try c.decodeIfPresent(String.self, forKey: .body)          ?? ""
        photoCount    = try c.decodeIfPresent(Int.self,    forKey: .photoCount)    ?? 0
        generatedBody = try c.decodeIfPresent(String.self, forKey: .generatedBody) ?? ""
    }
}

extension WeekGenerationResult {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sunday    = try c.decodeIfPresent(DayCaption.self, forKey: .sunday)
        monday    = try c.decodeIfPresent(DayCaption.self, forKey: .monday)
        tuesday   = try c.decodeIfPresent(DayCaption.self, forKey: .tuesday)
        wednesday = try c.decodeIfPresent(DayCaption.self, forKey: .wednesday)
        thursday  = try c.decodeIfPresent(DayCaption.self, forKey: .thursday)
        friday    = try c.decodeIfPresent(DayCaption.self, forKey: .friday)
        blog      = try c.decodeIfPresent(BlogOutput.self,            forKey: .blog)
        errors    = try c.decodeIfPresent([String: String].self,      forKey: .errors)    ?? [:]
    }
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
