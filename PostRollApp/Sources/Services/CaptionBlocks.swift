import Foundation

/// The shape of a day's block in CAPTIONS.txt, and the rules the two builders
/// (Swift `EventExporter.masterCaptionText`, Python `_master_captions`) must
/// both satisfy (#221, #222, #223).
///
/// CAPTIONS.txt is the deliverable: it is what gets pasted into Instagram. A
/// whole missing section produces a file that reads as complete, so it ships
/// and is only caught if Dan happens to notice something absent. That is how
/// both #221 and #222 were found.
enum CaptionBlocks {

    enum Block: String, CaseIterable {
        case caption   = "caption"
        case altText   = "ALT TEXT:"
        case photoTags = "PHOTO TAGS:"
        case tagList   = "TAG LIST:"
    }

    /// Instagram's "Tag people" field takes a bare username, so the export
    /// must not carry the @ (#221). Also tolerates a pasted profile URL.
    static func bareUsername(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "instagram.com/") {
            name = String(name[range.upperBound...])
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while name.hasPrefix("@") { name.removeFirst() }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Every handle taggable anywhere in the week, deduplicated, first
    /// appearance order preserved (#222).
    ///
    /// The reel days carry this rather than nothing. They are shot at the same
    /// event as the rest of the week, so anyone taggable on any other day is
    /// taggable on the reel, and there is no per-photo tag data for a reel day
    /// to draw on because the tagging control is only offered on collage days.
    static func weekTagList(event: Event) -> [String] {
        var seen = Set<String>()
        var out: [String] = []

        func add(_ raw: String) {
            let name = bareUsername(raw)
            guard !name.isEmpty else { return }
            // Case-insensitively deduplicated: Instagram handles are not
            // case sensitive, so two spellings are one person.
            let key = name.lowercased()
            guard seen.insert(key).inserted else { return }
            out.append(name)
        }

        for day in DayName.allCases {
            guard let posting = event.days[day.rawValue] else { continue }
            posting.tagHandles.forEach(add)
            // Photo order, so the list is stable rather than dictionary order.
            for url in posting.photoPaths {
                (posting.photoTags[url.absoluteString] ?? []).forEach(add)
            }
        }
        return out
    }

    /// Which blocks a day is expected to emit (#223).
    ///
    /// Declared once, here, rather than inferred from whichever builder ran:
    /// a check derived from the code it is checking can only confirm that code
    /// is self-consistent.
    static func expected(day: DayName, preset: PostingPreset,
                         hasAltText: Bool, hasPhotoTags: Bool,
                         hasWeekTags: Bool) -> Set<Block> {
        var blocks: Set<Block> = [.caption]
        if hasAltText { blocks.insert(.altText) }
        if preset.isCollageCarousel(day) {
            if hasPhotoTags { blocks.insert(.photoTags) }
        } else if day == .tuesday || day == .thursday {
            // The reel days. Their tag list comes from the whole week.
            if hasWeekTags { blocks.insert(.tagList) }
        }
        return blocks
    }

    /// Blocks that should be in `text` for this day but are not.
    ///
    /// Returns the shortfall rather than a bool so the caller can name what is
    /// missing; "the export is wrong" is not an actionable message.
    static func missing(from text: String, expected: Set<Block>) -> [Block] {
        Block.allCases.filter { block in
            guard expected.contains(block) else { return false }
            switch block {
            case .caption:
                // The caption is the block with no header: what is left once
                // the headed sections are removed.
                var body = text
                for header in [Block.altText, .photoTags, .tagList] {
                    if let range = body.range(of: "\n\n\(header.rawValue)") {
                        body = String(body[..<range.lowerBound])
                    }
                }
                let firstLineEnd = body.firstIndex(of: "\n") ?? body.endIndex
                let afterHeading = body[firstLineEnd...]
                return afterHeading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return !text.contains(block.rawValue)
            }
        }
    }
}
