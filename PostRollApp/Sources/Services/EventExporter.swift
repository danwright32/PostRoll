import Foundation

// MARK: - EventExporter

struct EventExporter {
    /// Export one event. Pass `days = nil` (the default) to export the whole week;
    /// pass a specific set to export only those days — in which case the master
    /// CAPTIONS.txt / CHECKLIST.md and Blog are left untouched so they keep
    /// reflecting the last full export.
    static func export(event: Event, to root: URL, days: Set<DayName>? = nil) throws -> URL {
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

        // Per-day folders — only Wednesday's carousel photos are copied
        // directly by Swift (in the user's assigned order). All other day
        // artifacts — story.png, reels, collage, before/after — come from
        // the Python media generator. Per-day caption.txt / alt_text.txt
        // files are no longer written; the master CAPTIONS.txt at the root
        // is the single source of truth for caption + alt text.
        for day in DayName.allCases {
            if let days, !days.contains(day) { continue }
            guard result?[day] != nil else { continue }
            let dayDir = folder.appendingPathComponent(day.folderName)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

            if day == .wednesday {
                let photos = event.days[day.rawValue]?.photoPaths ?? []
                if !photos.isEmpty {
                    let carouselDir = dayDir.appendingPathComponent("carousel")
                    try? FileManager.default.createDirectory(at: carouselDir, withIntermediateDirectories: true)
                    for (i, photo) in photos.enumerated() {
                        let ext = photo.pathExtension
                        let dest = carouselDir.appendingPathComponent("\(String(format: "%02d", i + 1)).\(ext)")
                        try? FileManager.default.copyItem(at: photo, to: dest)
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
                let md = "# \(blog.title)\n\n\(blog.body)\n"
                try md.write(to: blogDir.appendingPathComponent("draft.md"),
                             atomically: true, encoding: .utf8)

                for (i, photo) in event.blogPhotoPaths.enumerated() {
                    let ext = photo.pathExtension
                    let dest = blogDir.appendingPathComponent("photo_\(String(format: "%02d", i + 1)).\(ext)")
                    try? FileManager.default.copyItem(at: photo, to: dest)
                }
            }

            let masterCaptions = masterCaptionText(event: event, result: result)
            try masterCaptions.write(to: folder.appendingPathComponent("CAPTIONS.txt"),
                                      atomically: true, encoding: .utf8)
        }

        return folder
    }

    // MARK: - Text generators

    private static func masterCaptionText(event: Event, result: WeekGenerationResult?) -> String {
        var sections: [String] = []
        for day in DayName.allCases {
            guard let cap = result?[day] else { continue }
            var block = "=== \(day.displayName.uppercased()) ===\n\(cap.formatted)"
            let photoPaths = event.days[day.rawValue]?.photoPaths ?? []
            if !cap.altTexts.isEmpty {
                let altBody: String
                if day == .wednesday {
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
            // Wednesday carousel: per-photo people tags, in photo order, only for
            // photos that were actually tagged.
            if day == .wednesday {
                let photoTags = event.days[day.rawValue]?.photoTags ?? [:]
                let tagLines = photoPaths.enumerated().compactMap { idx, url -> String? in
                    let tags = photoTags[url.absoluteString] ?? []
                    guard !tags.isEmpty else { return nil }
                    return "\(photoLabel(idx: idx, photoPaths: photoPaths)): \(tags.joined(separator: ", "))"
                }
                if !tagLines.isEmpty {
                    block += "\n\nPHOTO TAGS:\n\(tagLines.joined(separator: "\n"))"
                }
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
