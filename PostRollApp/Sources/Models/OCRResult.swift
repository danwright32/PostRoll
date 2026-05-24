import Foundation

// Mirrors the JSON dict output of postroll/ai/ocr_program.py.
// Python uses snake_case; CodingKeys bridge the difference.

struct OCRResult: Codable, Hashable {
    var performers: [Performer] = []
    var pieces: [Piece] = []
    var scenes: [ProgramScene] = []
    var organizationNotes: String = ""
    var programNotes: String = ""
    var venueNotes: String = ""
    var productionDetails: String = ""

    enum CodingKeys: String, CodingKey {
        case performers, pieces, scenes
        case organizationNotes = "organization_notes"
        case programNotes      = "program_notes"
        case venueNotes        = "venue_notes"
        case productionDetails = "production_details"
    }
}

struct Performer: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var role: String
    var voiceOrInstrument: String
    var handle: String

    init(id: UUID = UUID(), name: String = "", role: String = "", voiceOrInstrument: String = "", handle: String = "") {
        self.id = id; self.name = name; self.role = role; self.voiceOrInstrument = voiceOrInstrument; self.handle = handle
    }

    // Python JSON won't include id — generate one on decode
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name              = (try? c.decode(String.self, forKey: .name)) ?? ""
        role              = (try? c.decode(String.self, forKey: .role)) ?? ""
        voiceOrInstrument = (try? c.decode(String.self, forKey: .voiceOrInstrument)) ?? ""
        handle            = (try? c.decode(String.self, forKey: .handle)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role, handle
        case voiceOrInstrument = "voice_or_instrument"
    }
}

struct Piece: Identifiable, Codable, Hashable {
    var id: UUID
    var composer: String
    var title: String
    var movements: [String]
    var notes: String

    init(id: UUID = UUID(), composer: String = "", title: String = "", movements: [String] = [], notes: String = "") {
        self.id = id; self.composer = composer; self.title = title; self.movements = movements; self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        composer  = (try? c.decode(String.self, forKey: .composer)) ?? ""
        title     = (try? c.decode(String.self, forKey: .title)) ?? ""
        movements = (try? c.decode([String].self, forKey: .movements)) ?? []
        notes     = (try? c.decode(String.self, forKey: .notes)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, composer, title, movements, notes
    }
}

// MARK: - Flag review

/// One element of a JSON-style path into OCRResult, e.g. `["pieces", 5, "composer"]`.
/// Flag JSON returns paths as a mixed array of strings and ints — this enum preserves
/// the type so we can walk the structure correctly when applying corrections.
enum FlagPathSegment: Codable, Hashable {
    case key(String)
    case index(Int)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .index(i) }
        else if let s = try? c.decode(String.self) { self = .key(s) }
        else {
            throw DecodingError.typeMismatch(
                FlagPathSegment.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or int")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .key(let s):   try c.encode(s)
        case .index(let i): try c.encode(i)
        }
    }

    var displayString: String {
        switch self {
        case .key(let s):   return s
        case .index(let i): return "[\(i)]"
        }
    }
}

/// A flagged item from `postroll.ai.flag_issues`. Transient — produced by Claude
/// after OCR, surfaced in the OCR review UI, then either applied or dismissed.
struct OCRFlag: Identifiable, Codable, Hashable {
    var id: String
    var fieldPath: [FlagPathSegment]
    var currentValue: String      // Stringified for display; complex values become JSON text
    var suggestedValue: String    // Claude's best guess at the corrected value
    var concern: String
    var programContext: String
    var resolved: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, concern, resolved
        case fieldPath      = "field_path"
        case currentValue   = "current_value"
        case suggestedValue = "suggested_value"
        case programContext = "program_context"
    }

    init(id: String = "", fieldPath: [FlagPathSegment] = [], currentValue: String = "",
         suggestedValue: String = "", concern: String = "", programContext: String = "",
         resolved: Bool = false) {
        self.id = id; self.fieldPath = fieldPath; self.currentValue = currentValue
        self.suggestedValue = suggestedValue
        self.concern = concern; self.programContext = programContext; self.resolved = resolved
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = (try? c.decode(String.self,                forKey: .id))              ?? UUID().uuidString
        fieldPath       = (try? c.decode([FlagPathSegment].self,     forKey: .fieldPath))       ?? []
        // current_value comes in as any JSON type — stringify for storage/display
        if let s = try? c.decode(String.self, forKey: .currentValue) {
            currentValue = s
        } else if let any = try? c.decode(JSONValue.self, forKey: .currentValue) {
            currentValue = any.displayString
        } else {
            currentValue = ""
        }
        // suggested_value, like current_value, may arrive as any JSON type
        if let s = try? c.decode(String.self, forKey: .suggestedValue) {
            suggestedValue = s
        } else if let any = try? c.decode(JSONValue.self, forKey: .suggestedValue) {
            suggestedValue = any.displayString
        } else {
            suggestedValue = ""
        }
        concern         = (try? c.decode(String.self,                forKey: .concern))         ?? ""
        programContext  = (try? c.decode(String.self,                forKey: .programContext))  ?? ""
        resolved        = (try? c.decode(Bool.self,                  forKey: .resolved))        ?? false
    }
}

/// Minimal heterogeneous JSON value — used to coerce flag `current_value`
/// into a display string when Claude returns a non-string (e.g. a piece object).
enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                   { self = .null }
        else if let v = try? c.decode(Bool.self)           { self = .bool(v) }
        else if let v = try? c.decode(Int.self)            { self = .int(v) }
        else if let v = try? c.decode(Double.self)         { self = .double(v) }
        else if let v = try? c.decode(String.self)         { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self)    { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown JSON type")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:        try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v):  try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var displayString: String {
        switch self {
        case .null:           return ""
        case .bool(let v):    return String(v)
        case .int(let v):     return String(v)
        case .double(let v):  return String(v)
        case .string(let v):  return v
        case .array, .object:
            if let data = try? JSONEncoder().encode(self),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return ""
        }
    }
}

struct ProgramScene: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var location: String
    var visualCues: String
    var description: String

    init(id: UUID = UUID(), name: String = "", location: String = "", visualCues: String = "", description: String = "") {
        self.id = id; self.name = name; self.location = location; self.visualCues = visualCues; self.description = description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name        = (try? c.decode(String.self, forKey: .name)) ?? ""
        location    = (try? c.decode(String.self, forKey: .location)) ?? ""
        visualCues  = (try? c.decode(String.self, forKey: .visualCues)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, name, location, description
        case visualCues = "visual_cues"
    }
}
