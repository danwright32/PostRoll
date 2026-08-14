import Foundation

// Mirrors the JSON dict output of postroll/ai/ocr_program.py.
// Python uses snake_case; CodingKeys bridge the difference.

struct OCRResult: Codable, Hashable, Sendable {
    var performers: [Performer] = []
    var pieces: [Piece] = []
    var scenes: [ProgramScene] = []
    var organizationNotes: String = ""
    var programNotes: String = ""
    var venueNotes: String = ""
    var productionDetails: String = ""
    /// Anything else printed in the programme worth a blog post: sponsor notes,
    /// dedications, audience instructions.
    ///
    /// OCR asked Claude for this on every programme and Python returned it, and
    /// there was no field here to hold it, so it was dropped at this boundary.
    /// `generate_blog.py` has had a prompt slot for `other` the whole time,
    /// which therefore always rendered "(none)": paid for on every event, used
    /// on none of them (#262).
    var other: String = ""

    /// Pages the scan could not read, named by the path they were sent under
    /// (#518).
    ///
    /// Empty means the run read everything. A large programme is read in
    /// several paid calls, and a call that dies takes its pages with it while
    /// the rest are kept; before this the pages it lost existed only in a log
    /// line, so closing the gap meant re-running the whole scan and paying
    /// again for every page that had already been read.
    var unreadPages: [String] = []

    enum CodingKeys: String, CodingKey {
        case performers, pieces, scenes, other
        case unreadPages       = "unread_pages"
        case organizationNotes = "organization_notes"
        case programNotes      = "program_notes"
        case venueNotes        = "venue_notes"
        case productionDetails = "production_details"
    }
}

extension OCRResult {
    // Persisted inside events.json: every field must decodeIfPresent or a
    // future schema change wipes all saved events on the next launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        performers        = try c.decodeIfPresent([Performer].self,    forKey: .performers)        ?? []
        pieces            = try c.decodeIfPresent([Piece].self,        forKey: .pieces)            ?? []
        scenes            = try c.decodeIfPresent([ProgramScene].self, forKey: .scenes)            ?? []
        organizationNotes = try c.decodeIfPresent(String.self,         forKey: .organizationNotes) ?? ""
        programNotes      = try c.decodeIfPresent(String.self,         forKey: .programNotes)      ?? ""
        venueNotes        = try c.decodeIfPresent(String.self,         forKey: .venueNotes)        ?? ""
        productionDetails = try c.decodeIfPresent(String.self,         forKey: .productionDetails) ?? ""
        other             = try c.decodeIfPresent(String.self,         forKey: .other)             ?? ""
        unreadPages       = try c.decodeIfPresent([String].self,       forKey: .unreadPages)       ?? []
    }
}

struct Performer: Identifiable, Codable, Hashable, Sendable {
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

    /// A short label for what this performer plays or does, shown next to their
    /// name when assigning performers. Prefers the instrument/voice; falls back
    /// to the role (e.g. "conductor" or a character name) when no instrument
    /// was captured. Empty when neither is known.
    var designation: String {
        let instrument = voiceOrInstrument.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instrument.isEmpty { return instrument }
        return role.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct Piece: Identifiable, Codable, Hashable, Sendable {
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
enum FlagPathSegment: Codable, Hashable, Sendable {
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
struct OCRFlag: Identifiable, Codable, Hashable, Sendable {
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
enum JSONValue: Codable, Sendable {
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

struct ProgramScene: Identifiable, Codable, Hashable, Sendable {
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
