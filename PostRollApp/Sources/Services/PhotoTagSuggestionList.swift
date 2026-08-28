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

    /// What the tagging sheet shows: the chips, and what it could not offer.
    struct Sheet: Equatable {
        var suggestions: [PhotoTagSuggestion] = []
        /// One sentence, or nothing when the sheet is offering everybody.
        var note: String? = nil
    }

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
    /// The event's own accounts (organization, venue, presenting festival) come
    /// first, then the performers. Dan's rule, 2026-08-10 (#302): those two or
    /// three accounts are on every post of the week, so they are the pick he
    /// reaches for most, while the performer he wants is found by typing.
    ///
    /// `appearingIn` holds the performers ticked as appearing in this day's
    /// photos; they are floated to the top so the common picks are closest to
    /// hand, and everyone keeps their original order otherwise.
    static func sheet(eventHandles: String,
                      performers: [Performer],
                      appearingIn selected: Set<UUID>) -> Sheet {
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
        let kept = (eventAccounts + performerSuggestions).filter {
            seen.insert($0.token.lowercased()).inserted
        }

        // Who the dedupe took out (#902).
        //
        // Walked in the same order, over the same suggestions, as the filter
        // above: which of two colliding rows survives depends on that order, so
        // a second pass in a different one would name the wrong company. It is
        // the same reading rather than a fresh count of the performers, because
        // a count written beside a list is a second definition of what the
        // sheet is offering and drifts in the direction that flatters it (L107).
        var taken = Set(eventAccounts.map { $0.token.lowercased() })
        var offered = 0
        var dropped: [String] = []
        for performer in ordered {
            guard let suggestion = suggestion(for: performer) else { continue }
            if taken.insert(suggestion.token.lowercased()).inserted {
                offered += 1
            } else {
                let name = performer.name.trimmingCharacters(in: .whitespaces)
                dropped.append(name.isEmpty ? suggestion.token : name)
            }
        }

        return Sheet(suggestions: kept,
                     note: PhotoTagSheetNote.line(offered: offered,
                                                  offerable: offered + dropped.count,
                                                  dropped: dropped))
    }

    /// The chips alone, for a caller that has no use for the sentence.
    static func build(eventHandles: String,
                      performers: [Performer],
                      appearingIn selected: Set<UUID>) -> [PhotoTagSuggestion] {
        sheet(eventHandles: eventHandles, performers: performers,
              appearingIn: selected).suggestions
    }
}
