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
