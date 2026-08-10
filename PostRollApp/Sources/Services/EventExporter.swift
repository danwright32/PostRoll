import Foundation

// MARK: - EventExporter

struct EventExporter {

    /// One file the export meant to copy and couldn't. Carries where it came
    /// from and what it was for, so the warning names the day and the file
    /// rather than just saying something went wrong.
    struct DroppedAsset: Equatable {
        /// Where it belonged, e.g. "Wednesday carousel photo 2" or "blog photo 1".
        let label: String
        let source: URL
        let reason: String
    }

    /// What an export produced. `dropped` is empty on a clean run; anything in
    /// it means the folder is short a file, which used to be invisible because
    /// every copy went through `try?` (#79).
    struct Outcome {
        let folder: URL
        let dropped: [DroppedAsset]

        var isComplete: Bool { dropped.isEmpty }

        /// What to show the user, or nil when nothing was dropped.
        var warning: String? {
            guard !dropped.isEmpty else { return nil }
            let lines = dropped.map { "\($0.label) (\($0.source.lastPathComponent)): \($0.reason)" }
            let count = dropped.count
            return "\(count) file\(count == 1 ? "" : "s") couldn't be copied into the export folder, so \(count == 1 ? "it is" : "they are") missing from it:\n" + lines.joined(separator: "\n")
        }
    }

    /// Export one event. Pass `days = nil` (the default) to export the whole week;
    /// pass a specific set to export only those days, in which case the master
    /// CAPTIONS.txt and Blog are left untouched so they keep reflecting the
    /// last full export. (No CHECKLIST.md is written by this exporter or by
    /// anything else in the app: an earlier version of this doc comment
    /// claimed one was, which was never true.)
    /// - Parameters:
    ///   - collaboratorStats: what is known about one tagged account (#278).
    ///     Injected rather than read from `AccountBook.shared` so a test can
    ///     never touch the real book, and so this stays callable off the main
    ///     actor. Returning nil for everything is the honest first-run state:
    ///     the accounts are still named, just not ranked.
    static func export(event: Event, to root: URL, days: Set<DayName>? = nil,
                       preset: PostingPreset = .balanced,
                       collaboratorStats: (String) -> AccountStats? = { _ in nil },
                       asOf now: Date = Date(),
                       collaboratorNotes: [String] = []) throws -> Outcome {
        // Every intended copy is accounted for: a source that isn't there, or a
        // copy that fails, is recorded rather than skipped, because an export
        // folder short a photo gets uploaded looking complete (#79).
        var dropped: [DroppedAsset] = []
        func copy(_ source: URL, to dest: URL, label: String) {
            do {
                try FileManager.default.copyItem(at: source, to: dest)
            } catch {
                dropped.append(DroppedAsset(label: label, source: source,
                                            reason: error.localizedDescription))
            }
        }

        let folderName = "\(slug(event.org))_\(slug(event.name))_\(event.isoDate)"
        let folder = root.appendingPathComponent(folderName)

        let result = event.weekResult
        let isFullExport = (days == nil)

        // A re-export must not inherit anything from the previous one:
        // FileManager.copyItem never overwrites (so re-exported photos keep
        // stale content), and trimmed sets leave orphans (carousel 11.jpg
        // after cutting to 10) that would get uploaded. Full exports rebuild
        // the folder from scratch; scoped exports clear just their days.
        if isFullExport {
            try? FileManager.default.removeItem(at: folder)
        } else if let days {
            for day in days {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(day.folderName))
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Per-day folders — for collage-carousel days the assigned photos are
        // copied directly by Swift (in the user's order) into a carousel/
        // subfolder. Wednesday is always collage-carousel; Sunday/Monday are
        // too under the balanced preset. All other day artifacts — story.png,
        // reels, collage, before/after — come from the Python media generator.
        // Per-day caption.txt / alt_text.txt files are no longer written; the
        // master CAPTIONS.txt at the root is the single source of truth.
        for day in DayName.allCases {
            if let days, !days.contains(day) { continue }
            guard result?[day] != nil else { continue }
            let dayDir = folder.appendingPathComponent(day.folderName)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

            if preset.isCollageCarousel(day) {
                let count = preset.format(for: day)?.count ?? 0
                let photos = Array((event.days[day.rawValue]?.photoPaths ?? []).prefix(count))
                if !photos.isEmpty {
                    let carouselDir = dayDir.appendingPathComponent("carousel")
                    try? FileManager.default.createDirectory(at: carouselDir, withIntermediateDirectories: true)
                    for (i, photo) in photos.enumerated() {
                        let ext = photo.pathExtension
                        let dest = carouselDir.appendingPathComponent("\(String(format: "%02d", i + 1)).\(ext)")
                        copy(photo, to: dest,
                             label: "\(day.displayName) carousel photo \(i + 1)")
                    }
                }
            }
        }

        // Blog draft and master CAPTIONS.txt are only written on a full
        // export. Single-day exports leave them untouched so they keep
        // reflecting the last full export.
        if isFullExport {
            if let blog = result?.blog {
                let blogDir = folder.appendingPathComponent("0. Blog")
                try FileManager.default.createDirectory(at: blogDir, withIntermediateDirectories: true)
                // One renderer, shared with the CLI writer and the review
                // screen's copy button, so a change to the draft's shape
                // reaches all three (#282). This copy used to concatenate
                // unconditionally, so a body already carrying its heading got
                // a second one.
                let md = BlogDraftText.copyText(title: blog.title, body: blog.body) + "\n"
                try md.write(to: blogDir.appendingPathComponent("draft.md"),
                             atomically: true, encoding: .utf8)

                // The SEO description and details block, in their own file
                // rather than appended to the draft (#284). Appended, they
                // would be pasted into the post along with everything else,
                // which is the exact hazard they exist to avoid (#283).
                try BlogMeta.exportFileText(event: event)
                    .write(to: blogDir.appendingPathComponent(BlogMeta.exportFileName),
                           atomically: true, encoding: .utf8)

                for (i, photo) in event.blogPhotoPaths.enumerated() {
                    let ext = photo.pathExtension
                    let dest = blogDir.appendingPathComponent("photo_\(String(format: "%02d", i + 1)).\(ext)")
                    copy(photo, to: dest, label: "blog photo \(i + 1)")
                }
            }

            let masterCaptions = masterCaptionText(event: event, result: result, preset: preset,
                                                   collaboratorStats: collaboratorStats, asOf: now,
                                                   collaboratorNotes: collaboratorNotes)
            try masterCaptions.write(to: folder.appendingPathComponent("CAPTIONS.txt"),
                                      atomically: true, encoding: .utf8)
        }

        return Outcome(folder: folder, dropped: dropped)
    }

    // MARK: - Text generators

    private static func masterCaptionText(event: Event, result: WeekGenerationResult?,
                                          preset: PostingPreset,
                                          collaboratorStats: (String) -> AccountStats?,
                                          asOf now: Date,
                                          collaboratorNotes: [String]) -> String {
        var sections: [String] = []
        let (weekTags, droppedTags) = CaptionBlocks.weekTags(event: event)
        for day in DayName.allCases {
            guard let cap = result?[day] else { continue }
            var block = "=== \(day.displayName.uppercased()) ===\n\(cap.formatted)"
            let photoPaths = event.days[day.rawValue]?.photoPaths ?? []
            if !cap.altTexts.isEmpty {
                let altBody: String
                if preset.isCollageCarousel(day) {
                    altBody = cap.altTexts.enumerated()
                        .map { idx, altText in
                            "\(photoLabel(idx: idx, photoPaths: photoPaths)): \(altText)"
                        }
                        .joined(separator: "\n")
                } else {
                    altBody = cap.altTexts[0]
                }
                block += "\n\nALT TEXT:\n\(altBody)"
            }
            // Collage-carousel days: per-photo people tags, in photo order, only
            // for photos that were actually tagged (Wednesday always; Sun/Mon
            // under the balanced preset).
            if preset.isCollageCarousel(day) {
                let photoTags = event.days[day.rawValue]?.photoTags ?? [:]
                let tagLines = photoPaths.enumerated().compactMap { idx, url -> String? in
                    // Bare usernames: Instagram's "Tag people" field takes a
                    // username, not an @ mention (#221).
                    let tags = (photoTags[url.absoluteString] ?? [])
                        .map(CaptionBlocks.bareUsername)
                        .filter { !$0.isEmpty }
                    guard !tags.isEmpty else { return nil }
                    return "\(photoLabel(idx: idx, photoPaths: photoPaths)): \(tags.joined(separator: ", "))"
                }
                if !tagLines.isEmpty {
                    block += "\n\nPHOTO TAGS:\n\(tagLines.joined(separator: "\n"))"
                }
            } else if day == .tuesday || day == .thursday, !weekTags.isEmpty {
                // The reel days had no tag list at all, so everyone in the reel
                // went untagged. They have no per-photo tags to draw on, so
                // they carry the whole week's list: same shoot, same people
                // (#222).
                block += "\n\nTAG LIST:\n\(weekTags.joined(separator: ", "))"
                // What Instagram will not accept, named rather than lost.
                // Past its limit the extra handles are simply not tagged when
                // this is pasted in, and nothing said which ones (#281).
                if !droppedTags.isEmpty {
                    block += "\n\n\(CaptionBlocks.tagsDroppedHeader)\n"
                          + "Instagram tags at most \(CaptionBlocks.maxTagsPerPost) accounts "
                          + "per post, so these did not fit: "
                          + droppedTags.joined(separator: ", ")
                }
            }
            // Which of this day's tags to invite as collaborators (#278).
            // A tag puts someone in a list almost nobody sees; a
            // collaborator invite puts the post on their own grid. Built
            // from the same `suggest` the review screen renders, so the
            // file and the screen cannot name a different five.
            if let picks = CollaboratorPick.suggest(event: event, day: day, preset: preset,
                                                    stats: collaboratorStats, asOf: now,
                                                    notes: collaboratorNotes) {
                block += "\n\n" + CollaboratorPick.captionBlock(picks)
            }
            sections.append(block)
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// Label for a carousel photo in CAPTIONS.txt: the trailing number from the
    /// filename (e.g. "-277.jpg" → "277"), falling back to 1-based position.
    private static func photoLabel(idx: Int, photoPaths: [URL]) -> String {
        guard idx < photoPaths.count else { return "\(idx + 1)" }
        let stem = photoPaths[idx].deletingPathExtension().lastPathComponent
        if let dash = stem.range(of: "-", options: .backwards) {
            let num = String(stem[dash.upperBound...])
            return num.isEmpty ? "\(idx + 1)" : num
        }
        return "\(idx + 1)"
    }

    // MARK: - Slug

    static func slug(_ text: String) -> String {
        var result = text.lowercased()
        result = result.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "_",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
