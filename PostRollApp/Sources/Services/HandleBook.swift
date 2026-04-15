import Foundation

/// Remembers handles per org name and per venue name so they auto-fill
/// on every future event at the same org or venue.
final class HandleBook: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HandleBook()
    private let orgKey   = "postroll.handlebook.org.v1"
    private let venueKey = "postroll.handlebook.venue.v1"

    private init() {}

    private func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Org handles

    private var orgBook: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: orgKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: orgKey) }
    }

    func handles(forOrg org: String) -> String {
        orgBook[normalize(org)] ?? ""
    }

    func record(org: String, handles: String) {
        var b = orgBook
        let trimmed = handles.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { b.removeValue(forKey: normalize(org)) }
        else               { b[normalize(org)] = trimmed }
        orgBook = b
    }

    // MARK: - Venue handles

    private var venueBook: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: venueKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: venueKey) }
    }

    func handles(forVenue venue: String) -> String {
        venueBook[normalize(venue)] ?? ""
    }

    func record(venue: String, handles: String) {
        var b = venueBook
        let trimmed = handles.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { b.removeValue(forKey: normalize(venue)) }
        else               { b[normalize(venue)] = trimmed }
        venueBook = b
    }
}
