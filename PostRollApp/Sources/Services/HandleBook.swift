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

    // MARK: - Reading and correcting what the books hold (#903)

    /// Which book, for a screen that shows all three.
    ///
    /// The three are separate stores keyed the same way, so an operation has to
    /// name one: keyed alike, a delete that took the key rather than the book
    /// would remove a handle nobody asked about.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case performer, org, venue

        var id: String { rawValue }

        var title: String {
            switch self {
            case .performer: return "Performers"
            case .org:       return "Organisations"
            case .venue:     return "Venues"
            }
        }

        var explanation: String {
            switch self {
            case .performer:
                return "Filled into a performer's handle field on every future "
                    + "event with the same name. It is a guess, matched on the "
                    + "name alone, so the next Sarah Chen gets the last one's."
            case .org:
                return "Filled into the event handles field for every future "
                    + "event at the same organisation. This one is free text, "
                    + "so a sentence with accounts inside it is fine."
            case .venue:
                return "Filled into the event handles field for every future "
                    + "event at the same venue. Free text, like organisations."
            }
        }

        /// Whether this book's values have to be shaped like a handle (#899).
        ///
        /// Only the performer book. The other two hold the event handles field,
        /// which legitimately carries a sentence: two entries are prose today
        /// and `EventHandleSuggestions` takes the accounts out of them.
        var valuesMustBeHandles: Bool { self == .performer }

        var storageKey: String {
            switch self {
            // The one place this string is written. `orgKey` and `venueKey`
            // are already static on HandleBook because a test plants values
            // through them; the performer key had no such reader until now.
            case .performer: return "postroll.handlebook.performer.v1"
            case .org:       return HandleBook.orgKey
            case .venue:     return HandleBook.venueKey
            }
        }
    }

    /// One saved entry, as the screen shows it.
    struct Entry: Identifiable, Equatable, Sendable {
        /// The normalised name the book is keyed on.
        var name: String
        var value: String
        /// Whether this value is actually served, or filtered on the way out.
        ///
        /// #899 stopped a value that is not shaped like a handle reaching a
        /// caption, which left it invisible: this is the one screen that has to
        /// show it anyway, and say that it is doing nothing.
        var isUsable: Bool

        var id: String { name }
    }

    /// Everything a book holds, by name.
    ///
    /// Read raw, NOT through `handle(forPerformer:)`. That filters a value the
    /// caption path must not see, which is right there and wrong here: the only
    /// reason this screen exists is to show the entry somebody has to correct,
    /// and a filtered read would hide exactly the row worth looking at.
    ///
    /// Sorted, because a dictionary has no order and a list drawn straight from
    /// one rearranges itself between two readings of the same book.
    func entries(in kind: Kind) -> [Entry] {
        let stored = defaults.dictionary(forKey: kind.storageKey) as? [String: String] ?? [:]
        return stored
            .sorted { $0.key < $1.key }
            .map { name, value in
                Entry(name: name, value: value,
                      isUsable: !kind.valuesMustBeHandles
                          || CaptionBlocks.isHandleShaped(value))
            }
    }

    /// Correct one entry, or clear it to remove it.
    ///
    /// A blank value removes, because clearing the field is how a row is
    /// removed on screen and a refusal there would leave a dead control (L109).
    ///
    /// A performer value that is not shaped like a handle is refused and
    /// changes nothing: the screen that exists to correct a bad value must not
    /// be a second way to write one, and it may not throw away a good handle on
    /// the way past (L5, #899).
    func setEntry(name: String, value: String, in kind: Kind) {
        let key = normalize(name)
        guard !key.isEmpty else { return }
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        var book = defaults.dictionary(forKey: kind.storageKey) as? [String: String] ?? [:]
        if trimmed.isEmpty {
            book.removeValue(forKey: key)
        } else if kind.valuesMustBeHandles, !CaptionBlocks.isHandleShaped(trimmed) {
            return
        } else {
            book[key] = trimmed
        }
        defaults.set(book, forKey: kind.storageKey)
    }

    func removeEntry(name: String, in kind: Kind) {
        setEntry(name: name, value: "", in: kind)
    }

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

    /// Named off `Kind` rather than spelled again, so the screen that lists the
    /// books and the code that writes them cannot end up reading two different
    /// stores (L41).
    private var performerKey: String { Kind.performer.storageKey }

    private var performerBook: [String: String] {
        get { defaults.dictionary(forKey: performerKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: performerKey) }
    }

    /// Look up a saved handle for a performer name. Returns empty string if
    /// unknown, and for an entry that is not shaped like a handle (#899).
    ///
    /// Filtered at the read rather than deleted from the store. The book holds
    /// one such entry today, a company's display name learned before anything
    /// checked, and a value cannot be brought back once it is gone (L116). It
    /// reaches no caption from here, and it stays visible to whatever surface
    /// ends up listing what the book holds.
    func handle(forPerformer name: String) -> String {
        let stored = performerBook[normalize(name)] ?? ""
        guard CaptionBlocks.isHandleShaped(stored) else { return "" }
        return stored
    }

    /// Save a performer name → handle mapping. Empty handle removes the entry.
    ///
    /// A value that is not shaped like a handle is neither written nor allowed
    /// to remove what is there (#899). Writing it caches the defect against
    /// the name for every future event; removing on it would let a typo throw
    /// away a good handle on the way past (L5).
    func record(performer name: String, handle: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var b = performerBook
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { b.removeValue(forKey: normalize(name)) }
        else if CaptionBlocks.isHandleShaped(trimmed) { b[normalize(name)] = trimmed }
        else { return }
        performerBook = b
    }

    /// Save all performers that have handles. Call when advancing past OCR review.
    ///
    /// A row whose HANDLE is on another row too is skipped, and the entry the
    /// book already holds for that name is left exactly as it was. On Battery
    /// Dance Festival, 2026-08-27, a paste had put one handle on two different
    /// companies while the book held the correct one for the first of them,
    /// and this write would have replaced a good value with a wrong one for
    /// every future event carrying that name.
    ///
    /// Neither half is recorded, not even the one that is probably right:
    /// which row holds the bad value is exactly what cannot be known here, so
    /// picking one would be a guess stored as a fact (L75). Not learning costs
    /// only this pass, and correcting the row and advancing again records both
    /// (L5: never destroy good state for an unverified replacement).
    ///
    /// A repeated NAME is warned about on the row but does NOT stop the write.
    /// Dan's call, 2026-08-27: two performers genuinely sharing a name happens,
    /// and refusing to learn either would mean retyping both handles at every
    /// future event for a programme that is not wrong. The later row wins, as
    /// it always has, and what it auto-fills is marked as a guess (#459) rather
    /// than presented as read off the programme.
    func recordAll(performers: [Performer]) {
        let duplicated = DuplicateHandleMark.marks(in: performers)
        var b = performerBook
        for p in performers where !p.name.trimmingCharacters(in: .whitespaces).isEmpty {
            guard duplicated[p.id]?.sameHandleAs.isEmpty ?? true else { continue }
            let key = normalize(p.name)
            let handle = p.handle.trimmingCharacters(in: .whitespaces)
            // Shaped like a handle, or it is not one to learn (#899). A row
            // carrying a company's display name in this field is how the book
            // came to hold one, and it auto filled into every future event
            // with that name from then on.
            if !handle.isEmpty, CaptionBlocks.isHandleShaped(handle) {
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
