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

    /// The heading the handles that did not fit are printed under (#281).
    static let tagsDroppedHeader = "TAGS THAT DID NOT FIT:"

    /// How many accounts Instagram will tag on one post (#281).
    ///
    /// 20, confirmed by Dan on 2026-08-10. Named here with that date rather
    /// than typed inline at each use, because Instagram has changed limits of
    /// this kind before and a number nobody can find the provenance of gets
    /// copied forward long after it stopped being true. Mirrors
    /// `caption_blocks.MAX_TAGS_PER_POST`; the shared fixture holds them
    /// together.
    static let maxTagsPerPost = 20

    /// The characters an Instagram username is made of.
    private static let handleCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._")

    /// Whether this value could be an Instagram username at all (#899).
    ///
    /// A performer row carried its company's display name in the handle field,
    /// "DPR Dance", and nothing checked. It reached `tag_handles` as a handle
    /// to mention, the model wrote `@DPR Dance` into a caption bound for
    /// Instagram, and `HANDLE_RE` on the Python side then read that as `@dpr`,
    /// which was never offered and belongs to somebody else. Any `tag_handles`
    /// entry containing a space produces that pair; it is not probabilistic.
    ///
    /// SHAPE only. Whether a value is a SENTINEL recorded because a lookup
    /// found nothing ("unknown", "n/a") is a different question, answered
    /// separately by `PythonBridge.isRealHandle`, so that one word names one
    /// unit (L118). "unknown" is well shaped.
    ///
    /// Mirrors `caption_blocks.is_handle_shaped` in Python, and
    /// `tests/fixtures/handle_shape.json` states the cases once for both,
    /// because a rule applied on one side of the bridge only is how this
    /// happened.
    static func isHandleShaped(_ raw: String) -> Bool {
        let name = bareUsername(raw)
        guard !name.isEmpty, !name.hasSuffix(".") else { return false }
        return name.allSatisfy { handleCharacters.contains($0) }
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
        weekTags(event: event).kept
    }

    /// The handles that fit on a post, and the ones that do not (#281).
    ///
    /// Both, because the whole defect was that the overflow went nowhere:
    /// Instagram silently ignores handles past its limit, so a week at a
    /// multi-ensemble venue tagged twenty people and lost the rest with the
    /// export reading as complete either way.
    ///
    /// Handles that appear in a photo's own tags come FIRST, ahead of ones
    /// that only appear as a day-level tag, so the people actually in the
    /// pictures keep their slots by construction.
    ///
    /// `tests/fixtures/caption_blocks.json` is the contract this and Python's
    /// `week_tags` both satisfy.
    static func weekTags(event: Event,
                         limit: Int = maxTagsPerPost) -> (kept: [String], dropped: [String]) {
        var seen = Set<String>()
        var inPhotos: [String] = []
        var dayLevel: [String] = []

        func add(_ raw: String, into list: inout [String]) {
            // Only an account reaches the TAG LIST (#917). #912 gated the
            // caption's mention list and left this path ungated, so a name
            // typed in either field still landed in the list Dan pastes into
            // Instagram's Tag people field.
            //
            // Excluding it loses nothing: `CaptionCreditInputs` reads both
            // sources through the same `TypedCredit` and credits a name by
            // name. INCLUDING it costs a real person their slot, because
            // Instagram tags at most `maxTagsPerPost` accounts and silently
            // ignores the rest, so a value that is not an account displaces one
            // that is (L117).
            guard case .mention = TypedCredit.read(raw) else { return }
            let name = bareUsername(raw)
            guard !name.isEmpty else { return }
            // Case-insensitively deduplicated: Instagram handles are not
            // case sensitive, so two spellings are one person.
            let key = name.lowercased()
            guard seen.insert(key).inserted else { return }
            list.append(name)
        }

        // Photos across the whole week first, so somebody in a picture is
        // never the one cut for somebody who is only on the day.
        for day in DayName.allCases {
            guard let posting = event.days[day.rawValue] else { continue }
            // Photo order, so the list is stable rather than dictionary order.
            for url in posting.photoPaths {
                for tag in posting.photoTags[url.absoluteString] ?? [] {
                    add(tag, into: &inPhotos)
                }
            }
        }
        for day in DayName.allCases {
            guard let posting = event.days[day.rawValue] else { continue }
            for handle in posting.tagHandles { add(handle, into: &dayLevel) }
        }

        let ordered = inPhotos + dayLevel
        guard ordered.count > limit else { return (ordered, []) }
        return (Array(ordered.prefix(limit)), Array(ordered.dropFirst(limit)))
    }

    /// Every account this week's posts tag, from both routes they arrive by (#289).
    ///
    /// `weekTags` is the caption's own TAG LIST block. The org and venue
    /// handles reach every post separately, which is why they are not in it and
    /// must not be added to it: printing them there would duplicate them and eat
    /// slots from the cap that decides who gets tagged at all (#281).
    ///
    /// But they ARE tagged, and anything asking "who does this week tag" has to
    /// see both or it sees the wrong set. Measured on Dan's 19 real events: of
    /// the 38 accounts tagged, the 6 that recur are all org or venue handles, so
    /// a list built from `weekTags` alone misses every returning account and
    /// keeps only the one-offs.
    ///
    /// One function so the book, the ranking and anything counting recurrence
    /// share a predicate rather than each rebuilding a nearly-right one (L16).
    static func accountsTagged(event: Event) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for handle in weekTagList(event: event)
            + EventHandleSuggestions.accounts(in: event.eventHandles) {
            let name = bareUsername(handle)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// The accounts one day's post actually tags, in the order it lists them.
    ///
    /// One predicate, shared by the export's own block and by the collaborator
    /// suggestion (#278), because a suggestion built from a different rule than
    /// the post would rank people the post does not tag, or miss people it
    /// does, and nothing on either surface would say so.
    ///
    /// A collage carousel day tags the people in its photos, per photo. The
    /// reel days carry the whole week's list, which is what their TAG LIST
    /// block prints: they are shot at the same event, and they have no
    /// per-photo tag data of their own (#222). Every other day prints no tag
    /// block at all, so it has no candidates.
    static func dayTagCandidates(event: Event, day: DayName,
                                 preset: PostingPreset) -> [String] {
        if preset.isCollageCarousel(day) {
            guard let posting = event.days[day.rawValue] else { return [] }
            var seen = Set<String>()
            var handles: [String] = []
            // The photos the day POSTS (#999). A person tagged only in an
            // assigned photo the carousel does not carry is not in the post,
            // so they cannot be tagged in it and must not be offered as a
            // collaborator on it either.
            for url in preset.postedPhotos(posting.photoPaths, on: day) {
                for tag in photoTags(posting, for: url) {
                    let name = bareUsername(tag)
                    guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                    handles.append(name)
                }
            }
            // The event's own accounts too (#985). The post tags them, and they
            // are the ones that come back: of the accounts tagged across the
            // archive, the handful that recur are all org or venue handles, so
            // a pool of the day's photo tags alone can only ever offer people
            // who will never be seen again.
            //
            // AFTER the people, and the ranking keeps them there. An invite
            // puts the post on their grid, so somebody actually in the pictures
            // is the better ask; the org fills a slot the people did not.
            for handle in EventHandleSuggestions.accounts(in: event.eventHandles) {
                let name = bareUsername(handle)
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                handles.append(name)
            }
            return handles
        }
        if day == .tuesday || day == .thursday { return weekTagList(event: event) }
        return []
    }

    /// One photo's tags, matched by filename when the stored key is an older
    /// path.
    ///
    /// `photoTags` is keyed on the URL as it stood when the tag was entered,
    /// and `MediaReclaim` later copies originals into app storage and rewrites
    /// the day's `photoPaths`. An exact-key-only lookup silently returns
    /// nobody, which reads identically to a photo with nobody in it.
    static func photoTags(_ posting: PostingDay, for url: URL) -> [String] {
        if let exact = posting.photoTags[url.absoluteString] { return exact }
        let name = url.lastPathComponent
        for (key, tags) in posting.photoTags
        where URL(string: key)?.lastPathComponent == name {
            return tags
        }
        return []
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
