import Foundation

struct GeneratedOutput: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var suggestedText: String
    var finalText: String?
    var createdAt: Date = Date()

    /// What to display — final if saved, suggested otherwise.
    var displayText: String { finalText ?? suggestedText }
    var hasFinal: Bool { finalText != nil }
}
