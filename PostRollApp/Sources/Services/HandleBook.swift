import Foundation

/// Remembers handles per org name and per venue name so they auto-fill
/// on every future event at the same org or venue.
final class HandleBook: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HandleBook()
    /// Not private, so a test can plant a value directly in the store.
    ///
    /// The blank key guard exists in two places on purpose, at the write and at
    /// the read, and each masks the other: nothing a test does through this
    /// type can produce a book that holds a blank key, so the read guard could
    /// never be seen to fail (L1). Planting one is the only way to exercise it,
    /// and it is also the honest scenario, since a book written by any older
    /// build is not something this one can assume the shape of.
    static let orgKey   = "postroll.handlebook.org.v1"
    static let venueKey = "postroll.handlebook.venue.v1"

    /// Where the book is kept. A property rather than `UserDefaults.standard`
    /// reached for inline, so a test can point it at a scratch suite: a test
    /// that recorded handles for real would edit the book Dan has built up
    /// across every event he has shot (L2).
    private let defaults: UserDefaults

    private init() { defaults = AppPreferences.store }

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
        get { defaults.dictionary(forKey: Self.orgKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.orgKey) }
    }

    /// Nothing is remembered against a blank name, in either direction (#689).
    ///
    /// An event can have no organisation, and the book is keyed by the
    /// normalised name. A blank key is one bucket that every such event shares,
    /// so the handles saved while working on one play would be prepended to the
    /// captions of every other event with no organisation. That is not a
    /// lookup, it is a collision that looks like a memory (L15).
    func handles(forOrg org: String) -> String {
        let key = normalize(org)
        guard !key.isEmpty else { return "" }
        return orgBook[key] ?? ""
    }

    func record(org: String, handles: String) {
        let key = normalize(org)
        guard !key.isEmpty else { return }
        var b = orgBook
        let trimmed = handles.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { b.removeValue(forKey: key) }
        else               { b[key] = trimmed }
        orgBook = b
    }

    // MARK: - Venue handles

    private var venueBook: [String: String] {
        get { defaults.dictionary(forKey: Self.venueKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.venueKey) }
    }

    /// Blank keys are refused here for the same reason as above: a venue can be
    /// left empty too, and one shared bucket is worse than no memory at all.
    func handles(forVenue venue: String) -> String {
        let key = normalize(venue)
        guard !key.isEmpty else { return "" }
        return venueBook[key] ?? ""
    }

    func record(venue: String, handles: String) {
        let key = normalize(venue)
        guard !key.isEmpty else { return }
        var b = venueBook
        let trimmed = handles.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { b.removeValue(forKey: key) }
        else               { b[key] = trimmed }
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
