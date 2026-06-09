import Foundation

/// Reclaims disk space for shoots that have been archived (stage == .exported)
/// for longer than `archiveAgeDays`. Captions, blog text, and other metadata in
/// events.json stay intact; only regeneratable media files and program scans
/// for those events are deleted.
///
/// Also wipes stale debris from `output/` (loose test renders from earlier
/// dev work; nothing in the active app writes there).
///
/// Safety: every delete path is constrained to subfolders inside the project
/// root so a misconfigured event URL can't escape and remove user data.
enum ArchiveCleanup {
    static let archiveAgeDays: Int = 60

    /// Runs the cleanup sweep against the provided events array.
    /// Returns `true` if any event was mutated (caller should persist).
    @discardableResult
    static func sweep(events: inout [Event], projectRoot: URL) -> Bool {
        let now = Date()
        let threshold = TimeInterval(archiveAgeDays) * 86_400
        var dirty = false

        for i in events.indices where events[i].stage == .exported {
            let referenceDate = events[i].archivedAt ?? events[i].date
            guard now.timeIntervalSince(referenceDate) > threshold else { continue }

            let removed = reclaim(event: events[i], projectRoot: projectRoot)
            if removed {
                events[i].previewMediaPaths = [:]
                events[i].programImagePaths = []
                dirty = true
            }
        }

        cleanOutputDebris(projectRoot: projectRoot, olderThan: threshold, now: now)

        return dirty
    }

    /// Deletes the per-event preview folder and any program-scan files this
    /// event still references. Returns true if anything was removed.
    private static func reclaim(event: Event, projectRoot: URL) -> Bool {
        let fm = FileManager.default
        var removed = false

        let previewDir = projectRoot
            .appendingPathComponent("preview")
            .appendingPathComponent(slug(event: event))
        if fm.fileExists(atPath: previewDir.path),
           isInside(previewDir, parent: projectRoot.appendingPathComponent("preview")) {
            try? fm.removeItem(at: previewDir)
            removed = true
        }

        let programsDir = projectRoot.appendingPathComponent("programs").standardizedFileURL
        for url in event.programImagePaths {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(programsDir.path + "/") else { continue }
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
                removed = true
            }
        }

        return removed
    }

    /// Removes loose files at the root of `output/` whose mtime is older than
    /// the cleanup threshold. Skips directories so a freshly created export
    /// subfolder is never touched.
    private static func cleanOutputDebris(projectRoot: URL, olderThan: TimeInterval, now: Date) {
        let fm = FileManager.default
        let outputDir = projectRoot.appendingPathComponent("output")
        guard let entries = try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  let mtime = values.contentModificationDate
            else { continue }
            let isDir = values.isDirectory ?? false
            guard !isDir else { continue }
            guard now.timeIntervalSince(mtime) > olderThan else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    /// Matches the Python slug in postroll/ai/generate_media.py so we hit the
    /// exact folder generate_media created.
    private static func slug(event: Event) -> String {
        "\(slugify(event.org))_\(slugify(event.name))_\(event.isoDate)"
    }

    private static func slugify(_ text: String) -> String {
        var out: [Character] = []
        var lastWasUnderscore = false
        for scalar in text.lowercased().unicodeScalars {
            let isAlphaNum =
                (scalar.value >= 0x61 && scalar.value <= 0x7A) ||
                (scalar.value >= 0x30 && scalar.value <= 0x39)
            if isAlphaNum {
                out.append(Character(scalar))
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                out.append("_")
                lastWasUnderscore = true
            }
        }
        var s = String(out)
        while s.hasPrefix("_") { s.removeFirst() }
        while s.hasSuffix("_") { s.removeLast() }
        return s
    }

    private static func isInside(_ url: URL, parent: URL) -> Bool {
        let u = url.standardizedFileURL.path
        let p = parent.standardizedFileURL.path
        return u.hasPrefix(p + "/")
    }
}
