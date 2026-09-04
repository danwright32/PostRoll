import Foundation

/// What the missing-media banner says. Pure text so the wording (which has to
/// name the standalone slots, not just count files) can be pinned by a test.
enum MissingMediaBannerText {
    static func message(photoCount: Int, standaloneNames: [String]) -> String {
        var parts: [String] = []
        if photoCount > 0 {
            parts.append("\(photoCount) photo\(photoCount == 1 ? "" : "s")")
        }
        parts.append(contentsOf: standaloneNames)
        let subject = list(parts)
        let plural = photoCount + standaloneNames.count > 1
        return "\(subject) can't be found: the file\(plural ? "s were" : " was") moved or deleted off disk."
    }

    /// Through the one joiner (#933). The empty case keeps its own wording:
    /// `SentenceList` answers with nothing, which is right for a sentence that
    /// names things and wrong for one that has to say something regardless.
    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "Some files" : SentenceList.of(items)
    }
}

/// Finds every file an event references that is no longer on disk.
///
/// The photo screen used to scan only the per-day photo grids, so a dead RAW,
/// edited or B&W path was invisible on the one screen whose job is to show the
/// state of the photos (#178). Anything that renders from those slots then
/// failed later with a message naming a file path rather than a control.
enum MissingMediaScan {

    /// One missing standalone file, named well enough to point at the control
    /// that sets it.
    struct Item: Hashable {
        let day: DayName
        let slot: MediaSlot
        let url: URL

        /// e.g. "Tuesday B&W photo": what the banner says is missing.
        var displayName: String { "\(day.displayName) \(slot.displayName)" }
    }

    struct Result: Equatable {
        /// Missing entries from the per-day photo grids.
        var photos: Set<URL> = []
        /// Missing standalone media, in day then slot order so the list is stable.
        var standalone: [Item] = []

        var isEmpty: Bool { photos.isEmpty && standalone.isEmpty }
        var count: Int { photos.count + standalone.count }
        /// Everything flagged, which is exactly what the Locate flow re-links.
        var allURLs: Set<URL> { photos.union(standalone.map(\.url)) }
    }

    /// Stats every referenced file. Pure apart from the file manager, which is
    /// injectable so tests run against a temp tree.
    static func scan(_ event: Event, fileManager fm: FileManager = .default) -> Result {
        var result = Result()
        for day in DayName.allCases {
            guard let pd = event.days[day.rawValue] else { continue }
            for photo in pd.photoPaths where MediaPresence.isMissing(photo, fileManager: fm) {
                result.photos.insert(photo)
            }
            for slot in MediaSlot.allCases {
                guard let url = pd[slot], MediaPresence.isMissing(url, fileManager: fm) else { continue }
                result.standalone.append(Item(day: day, slot: slot, url: url))
            }
        }
        return result
    }
}
