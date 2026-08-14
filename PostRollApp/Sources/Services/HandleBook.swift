import Foundation

/// Remembers handles per org name and per venue name so they auto-fill
/// on every future event at the same org or venue.
final class HandleBook: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HandleBook()
    private let orgKey   = "postroll.handlebook.org.v1"
    private let venueKey = "postroll.handlebook.venue.v1"

    /// Where the book is kept. A property rather than `UserDefaults.standard`
    /// reached for inline, so a test can point it at a scratch suite: a test
    /// that recorded handles for real would edit the book Dan has built up
    /// across every event he has shot (L2).
    private let defaults: UserDefaults

    private init() { defaults = .standard }

    #if POSTROLL_TESTS
    /// A book on its own storage. Compiled only into the test bundle, so the
    /// shipping app cannot end up with a second book by accident.
    init(defaults: UserDefaults) { self.defaults = defaults }
    #endif

    private func normalize(_ name: String) -> String {
        FieldText.normalized(name).lowercased()
    }

    // MARK: - Org handles

    private var orgBook: [String: String] {
        get { defaults.dictionary(forKey: orgKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: orgKey) }
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
        get { defaults.dictionary(forKey: venueKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: venueKey) }
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

    // MARK: - Performer handles

    private let performerKey = "postroll.handlebook.performer.v1"

    private var performerBook: [String: String] {
        get { defaults.dictionary(forKey: performerKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: performerKey) }
    }

    /// Look up a saved handle for a performer name. Returns empty string if unknown.
    func handle(forPerformer name: String) -> String {
        performerBook[normalize(name)] ?? ""
    }

    /// Save a performer name → handle mapping. Empty handle removes the entry.
    func record(performer name: String, handle: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var b = performerBook
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { b.removeValue(forKey: normalize(name)) }
        else               { b[normalize(name)] = trimmed }
        performerBook = b
    }

    /// Save all performers that have handles. Call when advancing past OCR review.
    func recordAll(performers: [Performer]) {
        var b = performerBook
        for p in performers where !p.name.trimmingCharacters(in: .whitespaces).isEmpty {
            let key = normalize(p.name)
            let handle = p.handle.trimmingCharacters(in: .whitespaces)
            if !handle.isEmpty {
                b[key] = handle
            }
        }
        performerBook = b
    }

    /// Fill in handles from the book for any performer missing one, and say
    /// which ones came from there (#459).
    ///
    /// The book is keyed on a normalised NAME and is global across every org
    /// and event, so this is a guess: the next Sarah Chen gets the last Sarah
    /// Chen's Instagram. It arrived in the field looking exactly like a handle
    /// read off this programme, which is the substitution L75 is about, and the
    /// web lookup right beside it presents its finds as suggestions with a
    /// confidence, a verify link and an explicit Accept.
    ///
    /// Returns performer id to the handle the book supplied, so the screen can
    /// mark those as suggestions for as long as they are still untouched.
    @discardableResult
    func autoFill(performers: inout [Performer]) -> [UUID: String] {
        var supplied: [UUID: String] = [:]
        for i in performers.indices {
            if performers[i].handle.isEmpty && !performers[i].name.isEmpty {
                let saved = handle(forPerformer: performers[i].name)
                if !saved.isEmpty {
                    performers[i].handle = saved
                    supplied[performers[i].id] = saved
                }
            }
        }
        return supplied
    }
}
