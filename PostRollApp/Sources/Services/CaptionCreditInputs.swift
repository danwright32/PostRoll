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
        // Event-wide handles (org, venue) go on every day.
        let eventHandles: [String] = event.eventHandles
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

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
        var photoTagHandles: [String] = []
        var photoTagNames: [String] = []
        for tags in day.photoTags.values {
            for raw in tags {
                let tag = raw.trimmingCharacters(in: .whitespaces)
                guard !tag.isEmpty else { continue }
                if tag.hasPrefix("@") {
                    if PythonBridge.isRealHandle(tag) { photoTagHandles.append(tag) }
                } else {
                    photoTagNames.append(tag)
                }
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
                eventHandles + performerHandles + day.tagHandles + photoTagHandles),
            names: PythonBridge.dedupedPreservingOrder(
                performerNames + day.nameMentions + photoTagNames),
            photoTags: tagsByPath)
    }
}
