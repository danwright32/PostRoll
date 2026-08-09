import Foundation

/// One offer in the tagging sheet's suggestion list: the text that gets written
/// as a tag, plus how it reads on screen.
///
/// Lives here rather than in the view so the filtering below can be tested
/// against the real type instead of a stand-in that would happily accept the
/// wrong field (L52).
struct PhotoTagSuggestion: Identifiable, Hashable {
    let token: String
    let display: String
    var id: String { token }
}

/// Stepping through a day's photos in the tagging sheet. Clamps at both ends
/// rather than wrapping: reaching the last photo and being silently returned
/// to the first reads as a bug, and hides that the carousel has been walked.
enum PhotoTagSheetNavigation {
    static func clamped(index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    static func canGoNext(from index: Int, count: Int) -> Bool {
        count > 0 && index < count - 1
    }

    static func canGoPrevious(from index: Int, count: Int) -> Bool {
        count > 0 && index > 0
    }

    static func next(from index: Int, count: Int) -> Int {
        canGoNext(from: index, count: count) ? index + 1 : clamped(index: index, count: count)
    }

    static func previous(from index: Int, count: Int) -> Int {
        canGoPrevious(from: index, count: count) ? index - 1 : clamped(index: index, count: count)
    }

    static func label(index: Int, count: Int) -> String {
        "Photo \(clamped(index: index, count: count) + 1) of \(count)"
    }

    /// What the sheet's one filled button does from here.
    ///
    /// On the last photo it finishes rather than refusing (#194). That is the
    /// moment the work is done, so the control the eye goes to after each Next
    /// should complete the pass; a greyed-out "Last photo" sitting in the
    /// primary position ends the rhythm on something that cannot be pressed,
    /// and leaves the small close icon in the opposite corner as the only exit.
    /// A control may only refuse when the system genuinely cannot act (L54),
    /// and there is always either a next photo or a way out.
    enum PrimaryAction: Equatable {
        case next
        case done

        var label: String {
            switch self {
            case .next: return "Next photo"
            case .done: return "Done"
            }
        }
    }

    static func primaryAction(index: Int, count: Int) -> PrimaryAction {
        canGoNext(from: index, count: count) ? .next : .done
    }

    /// How long the "added to N other photos" confirmation stays up (#193).
    ///
    /// It exists because the button previously gave no feedback at all, so it
    /// has to outlast a glance. But a message about a finished action that sits
    /// there indefinitely stops reading as "that just happened" and starts
    /// reading as current state, and then a second press gives no clear signal
    /// that anything happened.
    static let confirmationLifetime: TimeInterval = 6

    static func confirmationVisible(shownAt: Date?, now: Date,
                                    lifetime: TimeInterval = confirmationLifetime) -> Bool {
        guard let shownAt else { return false }
        return now.timeIntervalSince(shownAt) < lifetime
    }

    /// Suggestions matching what has been typed, in their original order.
    ///
    /// The list is walked once per PHOTO now rather than once per day, so its
    /// length multiplies by the size of the carousel (#192). Order is preserved
    /// because the caller puts performers seen in this day's photos first, and
    /// reshuffling that would undo the work it did.
    ///
    /// An empty or whitespace-only query means no filter. A query that matches
    /// nothing returns nothing rather than falling back to the full list, since
    /// silently showing everything makes the filter look broken exactly when it
    /// is working.
    static func filtered(_ suggestions: [PhotoTagSuggestion],
                         query: String) -> [PhotoTagSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return suggestions }
        return suggestions.filter { suggestion in
            // Matched on both fields, and anywhere within them: Dan reaches for
            // a surname alone as readily as a full name, and types a handle
            // without its leading "@".
            suggestion.token.lowercased().contains(needle)
                || suggestion.display.lowercased().contains(needle)
        }
    }
}
