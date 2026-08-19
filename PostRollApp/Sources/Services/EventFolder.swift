import Foundation

/// The one name an event's folder has, wherever that folder is being made,
/// found or deleted (#108, #689).
///
/// Three places built this name and two of them slugged their text with
/// different code: `ArchiveCleanup` walked the characters, `EventExporter` ran
/// a regular expression, and Python has a third implementation again. They
/// agreed, which is exactly why nobody noticed there were three: the day one of
/// them changes, the archive sweep stops finding the folder the export made and
/// leaks it, or worse, finds somebody else's.
///
/// So the rule lives here once and everything calls it. `tests/fixtures/
/// event_slug.json` holds the contract the Python side is held to as well, and
/// every expected value in it was measured by running Python's own function
/// rather than written by hand (L48).
enum EventFolder {

    /// The folder name for one event.
    ///
    /// The organisation leads when there is one. An event can have none (#689):
    /// a director hiring Dan to shoot a play is not an organisation, and there
    /// is nothing to name. The venue takes its place there, because the folder
    /// still has to say something about where the work came from, and a name
    /// starting with a bare underscore says nothing while looking like a
    /// mistake.
    ///
    /// The fallback is keyed on the organisation being BLANK, never on it
    /// slugging away to nothing, and that distinction is load bearing. An
    /// organisation written in a non latin script slugs to an empty string
    /// today and produces a name with a leading underscore, and folders with
    /// those names already exist on disk. Falling back for them would derive a
    /// different name for a folder Python created months ago: this side would
    /// miss it, leak it forever, and the event would quietly keep two. An
    /// organisation that is there keeps exactly the name it has always had,
    /// underscore and all.
    ///
    /// Only the genuinely absent case falls through, and there the empty
    /// segment is owed to nobody: when the venue slugs to nothing either, the
    /// name and the date stand alone.
    static func name(org: String, venue: String, name: String,
                     isoDate: String) -> String {
        "\(stem(org: org, venue: venue, name: name))_\(isoDate)"
    }

    /// The same leading part without the date, for the files named after an
    /// event rather than the folder holding it (the program PDF).
    ///
    /// One rule, so a file saved beside an event and the folder it belongs to
    /// cannot disagree about who the event is billed to.
    static func stem(org: String, venue: String, name: String) -> String {
        let tail = slugify(name)
        guard org.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(slugify(org))_\(tail)"
        }
        let lead = slugify(venue)
        return lead.isEmpty ? tail : "\(lead)_\(tail)"
    }

    /// The folder name for an event, from the event.
    static func name(for event: Event) -> String {
        name(org: event.org, venue: event.venue, name: event.name,
             isoDate: event.isoDate)
    }

    /// Lowercase, every run of characters outside a-z0-9 collapsed to one
    /// underscore, leading and trailing underscores stripped.
    ///
    /// Byte for byte what Python's `_slug` produces, held there by the shared
    /// fixture rather than by this sentence.
    static func slugify(_ text: String) -> String {
        var out: [Character] = []
        var lastWasUnderscore = false
        for scalar in text.lowercased().unicodeScalars {
            let isAlphaNum =
                (scalar.value >= 0x61 && scalar.value <= 0x7A) ||
                (scalar.value >= 0x30 && scalar.value <= 0x39)
            if isAlphaNum {
                out.append(Character(scalar))
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                out.append("_")
                lastWasUnderscore = true
            }
        }
        while out.first == "_" { out.removeFirst() }
        while out.last == "_" { out.removeLast() }
        return String(out)
    }
}
