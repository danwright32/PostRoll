import Foundation

/// Who a day's caption has to credit, and how.
///
/// Four sources feed this and every one of them is used twice: once to tell the
/// caption prompt whom to mention, and once by the hashtag gate (#199) to decide
/// whose name must NOT become a hashtag. The credit checks added in #475 read
/// the same lists a third time, to decide whether a handle in the finished
/// caption was ever offered.
///
/// It lives here rather than inside the week manifest loop because the revision
/// path needs exactly the same answer (#476). Two derivations would drift, and
/// the drift is silent in the worst direction: a handle offered at generation
/// and withheld at revision reads to the credit checks as a handle nobody
/// offered, which is the finding that says the caption tags a stranger.
/// How one credit somebody TYPED is carried into a caption (#912).
///
/// Three answers rather than two, because the third is not the absence of the
/// other two. A mention goes in `tag_handles` and the model writes `@name`. A
/// name goes in `name_mentions` and the model writes the words. NOTHING is the
/// answer for a sentinel, which is a recorded "somebody looked and there is no
/// Instagram" and is not a credit at all: routing one to names would put the
/// word "unknown" in a caption (L118).
///
/// One rule for every field somebody types a credit into, because they were
/// three rules and each had a different hole. #899 fixed the performer rows and
/// the event handles field. The day's own handle list still split on commas and
/// passed every piece through, so `DPR Dance` typed there became `@DPR Dance`
/// in the prompt, which is exactly what #899 was filed for. The per photo tags
/// dropped `@DPR Dance` on the floor instead, silently, so somebody tagged a
/// company and nothing credited them (L100).
enum TypedCredit: Equatable {
    /// A usable handle. Carried with the @ the caption needs.
    case mention(String)
    /// Anything else meant as a credit. The name underneath a sigil counts:
    /// somebody typing `@DPR Dance` meant that company, and the words are the
    /// credit even though the account is not.
    case name(String)
    /// A sentinel, or nothing at all.
    case nothing

    static func read(_ raw: String) -> TypedCredit {
        let typed = raw.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return .nothing }
        if PythonBridge.isRealHandle(typed) {
            return .mention(typed.hasPrefix("@") ? typed : "@\(typed)")
        }
        // Shaped like a handle but refused above: that is the sentinel case,
        // and it is the one thing here that is not a credit.
        if CaptionBlocks.isHandleShaped(typed) { return .nothing }
        let words = CaptionBlocks.bareUsername(typed)
        return words.isEmpty ? .nothing : .name(words)
    }
}

enum CaptionCreditInputs {

    struct ForDay {
        /// @ handles to mention, event-wide first, deduped case insensitively.
        let handles: [String]
        /// People credited by plain name, because no handle was offered.
        let names: [String]
        /// Per-photo people tags, keyed by the POSIX path Python matches on.
        let photoTags: [String: [String]]
    }

    /// Everything one day of one event has to credit.
    ///
    /// `day` is optional because a day may not exist on the event at all, which
    /// is not an error: it credits the event-wide handles and nothing else.
    static func forDay(_ day: PostingDay?, event: Event) -> ForDay {
        // Event-wide handles (org, venue) go on every day, read through the
        // same helper the tagging sheet reads them with (#899).
        //
        // This used to split the field on commas and pass the pieces straight
        // through, with no gate of any kind. The field is free text and holds
        // two shapes: the comma separated bare names the OCR review writes,
        // and a sentence somebody typed. Two entries in the org book are prose
        // today, "@bludlineodyssey presented by @matchbookfestival" among
        // them, and each reached the caption prompt as ONE multi word account
        // to mention. `accounts(in:)` takes the accounts out of either shape
        // and takes a comma separated piece only when it could be a handle, so
        // prose can no longer become one.
        let eventHandles = EventHandleSuggestions.accounts(in: event.eventHandles)

        guard let day else {
            return ForDay(handles: PythonBridge.dedupedPreservingOrder(eventHandles),
                          names: [], photoTags: [:])
        }

        // Selected performers: by handle when they have a real one, by name
        // otherwise. A sentinel like "unknown" is not a handle.
        let selectedIDs = Set(day.selectedPerformerIDs)
        let selected = (event.ocrResult?.performers ?? [])
            .filter { selectedIDs.contains($0.id) }

        // Judged across the performers posted THIS day, not the whole
        // programme: whether two credits collapse into one depends on who is
        // in these photos, and naming a company left out of them would credit
        // a performance nobody is looking at (L166).
        let sharing = DuplicateHandleMark.marks(in: selected)

        var performerHandles: [String] = []
        var performerNames: [String] = []
        for performer in selected {
            let handle = performer.handle.trimmingCharacters(in: .whitespaces)
            if !handle.isEmpty && PythonBridge.isRealHandle(handle) {
                performerHandles.append(handle.hasPrefix("@") ? handle : "@\(handle)")
                // Two performers on one account are one tag but two credits.
                // The dedupe below keeps the account once, which is right, and
                // that alone would leave the second company named nowhere in
                // the caption while the credit check reports every credit
                // present (#475 cannot see this: it looks for the handle, and
                // the handle is there). So each of them is named as well.
                if !(sharing[performer.id]?.sameHandleAs.isEmpty ?? true),
                   !performer.name.isEmpty {
                    performerNames.append(performer.name)
                }
            } else if !performer.name.isEmpty {
                performerNames.append(performer.name)
            }
        }

        // People tagged on individual photos are credited by the caption too
        // (#171). Without this, tagging a carousel photo only produced the
        // PHOTO TAGS list in CAPTIONS.txt and Dan had to tick the same person
        // again at day level to get them into the caption.
        //
        // Read through `TypedCredit` since #912. This used to send anything
        // starting with @ to the handles list or nowhere, so `@DPR Dance` was
        // dropped on the floor: somebody tagged a company on a photograph and
        // nothing credited them, with nothing said (L100).
        var photoTagHandles: [String] = []
        var photoTagNames: [String] = []
        for tags in day.photoTags.values {
            for raw in tags {
                switch TypedCredit.read(raw) {
                case .mention(let handle): photoTagHandles.append(handle)
                case .name(let words):     photoTagNames.append(words)
                case .nothing:             continue
                }
            }
        }

        // The day's own handle list, read the same way (#912).
        //
        // It was added to the handles list verbatim, which is the ungated comma
        // split #899 removed from `event.eventHandles`, still standing one
        // field along. A name typed here reached the caption prompt as an
        // account to mention, and the mention went to whoever owns the first
        // word of it.
        var dayHandles: [String] = []
        var dayNames: [String] = []
        for raw in day.tagHandles {
            switch TypedCredit.read(raw) {
            case .mention(let handle): dayHandles.append(handle)
            case .name(let words):     dayNames.append(words)
            case .nothing:             continue
            }
        }
        // photoTags iterates a dictionary, so sort for a stable manifest.
        photoTagHandles.sort()
        photoTagNames.sort()

        // Re-key the per-photo tags from the URL absoluteString the UI stores
        // to the POSIX path used in `photos`, so Python can line each tag up
        // with its photo by path.
        var tagsByPath: [String: [String]] = [:]
        for (key, tags) in day.photoTags where !tags.isEmpty {
            tagsByPath[URL(string: key)?.path ?? key] = tags
        }

        return ForDay(
            handles: PythonBridge.dedupedPreservingOrder(
                eventHandles + performerHandles + dayHandles + photoTagHandles),
            names: PythonBridge.dedupedPreservingOrder(
                performerNames + day.nameMentions + dayNames + photoTagNames),
            photoTags: tagsByPath)
    }
}
