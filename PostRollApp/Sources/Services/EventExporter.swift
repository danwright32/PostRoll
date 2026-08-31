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
        /// Where the files are right now, which is the staging folder until the
        /// run commits. Every later step of the export writes here.
        let folder: URL
        let dropped: [DroppedAsset]

        /// The staging this export is being built in (#442). The caller commits
        /// it once the whole run has finished, or abandons it on a failure, so
        /// the export already on disk survives a run that dies partway.
        let staging: ExportStaging

        /// Where the finished export will be, for anything that has to name it
        /// before the swap.
        var destination: URL { staging.finalFolder }

        var isComplete: Bool { dropped.isEmpty }

        /// What to show the user, or nil when nothing was dropped.
        var warning: String? { EventExporter.warning(for: dropped) }
    }

    /// What to show the user about files that could not be copied, or nil when
    /// none were.
    ///
    /// A function over the list rather than a property on `Outcome`, so a
    /// caller that has only accumulated some dropped assets does not have to
    /// fabricate an Outcome (and a staging folder) around them to get a
    /// sentence out.
    static func warning(for dropped: [DroppedAsset]) -> String? {
        guard !dropped.isEmpty else { return nil }
        let lines = dropped.map { "\($0.label) (\($0.source.lastPathComponent)): \($0.reason)" }
        let count = dropped.count
        return "\(count) file\(count == 1 ? "" : "s") couldn't be copied into the export folder, so \(count == 1 ? "it is" : "they are") missing from it:\n" + lines.joined(separator: "\n")
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

        // The same rule the archive sweep uses to find this folder again, and
        // the same one Python uses to make the preview folder. Three spellings
        // of it agreed until the day one changed (#689).
        let folderName = EventFolder.name(for: event)
        let destination = root.appendingPathComponent(folderName)

        let result = event.weekResult
        let isFullExport = (days == nil)

        // Built beside the previous export and swapped in by the caller once
        // the whole run has finished, rather than deleting the previous one
        // first (#442, L5). A full export starts from nothing; a scoped one
        // starts from a copy of what is there and clears only its own days, so
        // the days it is not rebuilding, the blog and CAPTIONS.txt survive.
        let staging = try ExportStaging.begin(
            finalFolder: destination,
            rebuilding: isFullExport ? nil : Set((days ?? []).map(\.folderName))
        )
        let folder = staging.workingFolder

        do {
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
                // `effectiveCount`, the one spelling of how many of a day's
                // photos actually get posted (#1010). This read
                // `format(for:)?.count ?? 0`, one of four fallbacks across the
                // app that each guessed differently (0 here, 10 in the picker,
                // the assigned count in two more) for a day no preset governs.
                let assigned = event.days[day.rawValue]?.photoPaths ?? []
                let count = preset.effectiveCount(for: day, assigned: assigned.count)
                    ?? assigned.count
                let photos = Array(assigned.prefix(count))
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

        } catch {
            // A staged export that will never be committed is debris in the
            // person's chosen folder, and the export already on disk is the one
            // thing this whole arrangement exists to protect.
            staging.abandon()
            throw error
        }

        return Outcome(folder: folder, dropped: dropped, staging: staging)
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
                    // Walked in PHOTO order, resolving each photo's own alt
                    // text, rather than walking the alt texts and labelling
                    // them by position (#1008). The two agree only until the
                    // photos move, and a drag to reorder moves them with
                    // nothing permuting the alt texts, so the old form
                    // described each photo with its neighbour's words.
                    altBody = photoPaths
                        .enumerated()
                        .compactMap { idx, url -> String? in
                            guard let alt = cap.altText(for: url, at: idx),
                                  !alt.isEmpty else { return nil }
                            return "\(photoLabel(idx: idx, photoPaths: photoPaths)): \(alt)"
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
            // On EVERY posting day since #964, not only when there are more
            // candidates than slots. An absent section reads as a post that was
            // considered and needed no invites, and the days carrying the best
            // photos are the ones that used to go quiet.
            block += "\n\n" + CollaboratorPick.captionBlock(
                CollaboratorPick.suggest(event: event, day: day, preset: preset,
                                         stats: collaboratorStats, asOf: now,
                                         notes: collaboratorNotes))
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

    /// Kept as a name because the program PDF file name is built from it, but
    /// no longer a second implementation of the rule (#689).
    static func slug(_ text: String) -> String { EventFolder.slugify(text) }
}
