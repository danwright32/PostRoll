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

    /// The same gap, said as positions in the uploaded programme, one per entry
    /// in `unreadPages` and paired with it by index (#558).
    ///
    /// A path stops identifying a page the moment the programme images move,
    /// which this app does do, and a gap keyed on paths then names files
    /// nothing can find: every page reads as missing and the only way back is
    /// paying to read the whole programme again. The position is the part a
    /// move cannot break.
    ///
    /// Empty on every result written before this existed, and on any run that
    /// could not place its pages. Empty means "no positions", never "no gap":
    /// `unreadPages` is what says whether there is one.
    var unreadPageNumbers: [Int] = []

    enum CodingKeys: String, CodingKey {
        case performers, pieces, scenes, other
        case unreadPages       = "unread_pages"
        case unreadPageNumbers = "unread_page_numbers"
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
        unreadPageNumbers = try c.decodeIfPresent([Int].self,          forKey: .unreadPageNumbers) ?? []
    }
}

struct Performer: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var role: String
    var voiceOrInstrument: String
    var handle: String
    /// The Instagram profile the research step fetched and checked this handle
    /// against, where there was one (#987).
    ///
    /// `handle_matches_profile` in the enrichment step already compared the two
    /// and dropped the pair when they named different people, and the address
    /// it compared against was then thrown away, so every later reader rebuilt
    /// it by convention and nothing recorded that the handle had been checked
    /// at all.
    ///
    /// Nil on a handle Dan typed and on one the account book filled in, which
    /// is most of them. That absence is NOT a claim that the handle is wrong:
    /// those are his own answers rather than a model's, and marking them
    /// unverified would accuse the accounts most likely to be right. It means
    /// only that no fetched address is on record, so a reader falls back to the
    /// constructed one.
    var profileURL: String?

    init(id: UUID = UUID(), name: String = "", role: String = "", voiceOrInstrument: String = "", handle: String = "",
         profileURL: String? = nil) {
        self.id = id; self.name = name; self.role = role; self.voiceOrInstrument = voiceOrInstrument; self.handle = handle
        self.profileURL = profileURL
    }

    // Python JSON won't include id — generate one on decode
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Folded to one line on the way in (#688). These arrive from the
        // Python side's reading of the printed pages, where a performer
        // credited across two printed lines is an everyday occurrence rather
        // than a paste accident, and none of them passed through FieldText in
        // either direction before.
        id                = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name              = FieldText.singleLine((try? c.decode(String.self, forKey: .name)) ?? "")
        role              = FieldText.singleLine((try? c.decode(String.self, forKey: .role)) ?? "")
        voiceOrInstrument = FieldText.singleLine((try? c.decode(String.self, forKey: .voiceOrInstrument)) ?? "")
        handle            = FieldText.singleLine((try? c.decode(String.self, forKey: .handle)) ?? "")
        // Every performer stored before #987 has no such key, so an absent one
        // decodes as nil rather than failing the whole file.
        profileURL        = (try? c.decode(String.self, forKey: .profileURL))
            .map(FieldText.singleLine).flatMap { $0.isEmpty ? nil : $0 }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role, handle
        case voiceOrInstrument = "voice_or_instrument"
        case profileURL = "profile_url"
    }

    /// Change the handle, and drop a checked address that no longer describes
    /// it (#1372).
    ///
    /// The address is a fact about ONE account. Editing the handle to a
    /// different one leaves a mark saying this handle was checked against a
    /// profile that belongs to somebody else, which is worse than no mark at
    /// all: it is the app vouching for an account nobody looked at (L15, L92).
    ///
    /// A no-op edit keeps it, because retyping the same handle is not a change
    /// of account, and case and the leading sigil are not either: `@Jenna` and
    /// `jenna` are one username.
    mutating func setHandle(_ newValue: String) {
        let wasChecked = CaptionBlocks.bareUsername(handle).lowercased()
        let becomes = CaptionBlocks.bareUsername(newValue).lowercased()
        handle = newValue
        if wasChecked != becomes { profileURL = nil }
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
        // notes is the exception and it is deliberate (#688): it is bound to
        // the multi line editor on the review screen and line breaks in it are
        // meaningful. Everything else here is one line, including each movement
        // title, which wraps on a printed page like any other.
        id        = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        composer  = FieldText.singleLine((try? c.decode(String.self, forKey: .composer)) ?? "")
        title     = FieldText.singleLine((try? c.decode(String.self, forKey: .title)) ?? "")
        movements = ((try? c.decode([String].self, forKey: .movements)) ?? [])
            .map(FieldText.singleLine)
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
        // description is the exception here, for the same reason notes is on a
        // piece (#688): it is prose about the scene, and a line break in it is
        // something somebody meant.
        id          = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name        = FieldText.singleLine((try? c.decode(String.self, forKey: .name)) ?? "")
        location    = FieldText.singleLine((try? c.decode(String.self, forKey: .location)) ?? "")
        visualCues  = FieldText.singleLine((try? c.decode(String.self, forKey: .visualCues)) ?? "")
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, name, location, description
        case visualCues = "visual_cues"
    }
}
