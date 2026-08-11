import Foundation

/// The tagging sheet's suggestion list for one day: the event's own accounts
/// (organization, venue, presenting festival) plus its performers.
///
/// Lives here rather than inside `PhotoAssignmentView` so the list can be
/// asserted against the field shapes real events actually carry. It was built
/// in the view from `EventHandleSuggestions.tokens(fromAll:)`, which finds only
/// `@` handles inside prose, while every event on disk writes the field as a
/// comma separated list of bare names, so no event account was ever offered on
/// any of them (#292).
enum PhotoTagSuggestionList {

    /// A performer's suggestion, or nil when there is neither a name nor a real
    /// handle to offer.
    private static func suggestion(for p: Performer) -> PhotoTagSuggestion? {
        let name = p.name.trimmingCharacters(in: .whitespaces)
        let handle = p.handle.trimmingCharacters(in: .whitespaces)
        let realHandle = PythonBridge.isRealHandle(handle)
        guard !name.isEmpty || realHandle else { return nil }
        let normalizedHandle = handle.hasPrefix("@") ? handle : "@\(handle)"
        let token = realHandle ? normalizedHandle : name
        // Label echoes the performer checkbox: name, instrument/role, handle.
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        let designation = p.designation
        if !designation.isEmpty { parts.append(designation.lowercased()) }
        if realHandle { parts.append(normalizedHandle) }
        let display = parts.isEmpty ? token : parts.joined(separator: " ")
        return PhotoTagSuggestion(token: token, display: display)
    }

    /// Everything taggable on one photo of `day`.
    ///
    /// The event's own accounts are taggable on a photo too: a shot of the room
    /// or of the presenting festival is often about them rather than about a
    /// performer. Performers come first because they are the common pick, and
    /// the event's accounts are a handful that stay findable at the end.
    ///
    /// `appearingIn` holds the performers ticked as appearing in this day's
    /// photos; they are floated to the top so the common picks are closest to
    /// hand, and everyone keeps their original order otherwise.
    static func build(eventHandles: String,
                      performers: [Performer],
                      appearingIn selected: Set<UUID>) -> [PhotoTagSuggestion] {
        // `accounts(in:)` reads both shapes the field is written in: the comma
        // separated bare names every event on disk carries, and `@` handles
        // inside a sentence. Every account is then spelled the one way the
        // performer half spells a handle, so the two halves share one
        // vocabulary and a venue that is in both is offered once rather than
        // twice in two spellings that look like two different accounts.
        let eventAccounts = EventHandleSuggestions
            .accounts(in: eventHandles)
            .map { raw -> PhotoTagSuggestion in
                let handle = "@" + CaptionBlocks.bareUsername(raw)
                return PhotoTagSuggestion(token: handle, display: handle)
            }

        let ordered = performers.enumerated().sorted { a, b in
            let aSel = selected.contains(a.element.id)
            let bSel = selected.contains(b.element.id)
            if aSel != bSel { return aSel }
            return a.offset < b.offset
        }.map(\.element)

        let performerSuggestions = ordered.compactMap(suggestion(for:))

        var seen = Set<String>()
        return (performerSuggestions + eventAccounts).filter {
            seen.insert($0.token.lowercased()).inserted
        }
    }
}
