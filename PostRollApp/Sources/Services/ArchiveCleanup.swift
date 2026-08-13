import Foundation

/// Reclaims disk space for shoots that have been archived (stage == .exported)
/// for longer than `archiveAgeDays`. Captions, blog text, and other metadata in
/// events.json stay intact; only regeneratable media files and program scans
/// for those events are deleted.
///
/// Safety: every delete path is constrained to subfolders inside the data
/// root so a misconfigured event URL can't escape and remove user data.
///
/// Correctness ALSO depends on `slugify` producing byte-for-byte what Python's
/// `_slug` produced when it created the folder, because that is how the folder
/// to delete is identified. Two implementations in two languages with nothing
/// forcing them to agree: drift one way leaks a folder forever, drift the other
/// way deletes a folder some other event is still using.
/// `tests/fixtures/event_slug.json` is the contract, and
/// `EventSlugParityTests` holds this side to it (#108).
///
/// Every reclaim is written to an audit log, because a mistargeted delete was
/// otherwise completely silent: the folder is simply gone, months after the
/// export, with nothing anywhere saying what took it.
enum ArchiveCleanup {
    static let archiveAgeDays: Int = 60

    /// One reclaim, as recorded.
    struct Reclaim: Equatable {
        let eventName: String
        let eventID: UUID
        let slug: String
        /// Absolute paths actually removed from disk.
        let removed: [String]
    }

    /// Where reclaims are recorded, beside the generation logs.
    static func auditLog(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("logs").appendingPathComponent("archive-cleanup.log")
    }

    /// What happened to one attempted audit-log append.
    ///
    /// Three outcomes rather than a Bool, because "could not open a log that is
    /// already there" is the one that matters and used to be indistinguishable
    /// from a first write (#444, L11).
    enum AuditWrite: Equatable {
        /// Appended to the existing log, or created it for the first time.
        case recorded
        /// The log exists and could not be opened for writing. Nothing was
        /// written, deliberately: see `appendToAuditLog`.
        case refusedToOverwriteExistingLog(String)
        /// There was no log and one could not be created.
        case couldNotCreate(String)
    }

    /// Append one reclaim to the audit log. Never raises: failing to record a
    /// tidy-up must not fail the launch that triggered it, and a reclaim that
    /// could not be written is still better than one that was never attempted.
    ///
    /// The fallback whole-file write happens ONLY when there is no log yet.
    /// It used to be the branch for any failed open, so a log that existed but
    /// could not be opened (permissions, flags, a lock) was replaced by a
    /// single line: the entire history of past reclaims gone, on the one record
    /// that exists to explain a mistargeted delete months later. That is
    /// append-by-rewrite, and a read that cannot distinguish absent from
    /// unreadable erases the record exactly when it is worth having (#444,
    /// L105).
    @discardableResult
    static func appendToAuditLog(_ reclaim: Reclaim, dataRoot: URL) -> AuditWrite {
        guard !reclaim.removed.isEmpty else { return .recorded }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) reclaimed for \"\(reclaim.eventName)\" "
                 + "(\(reclaim.eventID.uuidString), slug \(reclaim.slug)): "
                 + reclaim.removed.joined(separator: ", ") + "\n"
        let url = auditLog(dataRoot: dataRoot)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        // Asked BEFORE the open, so the answer cannot be inferred from the
        // open having failed. Those are two different questions and the whole
        // defect was answering the second with the first.
        let alreadyThere = FileManager.default.fileExists(atPath: url.path)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            do {
                try handle.write(contentsOf: Data(line.utf8))
                return .recorded
            } catch {
                let reason = error.localizedDescription
                NSLog("ArchiveCleanup: could not append to the audit log: \(reason)")
                return .refusedToOverwriteExistingLog(reason)
            }
        }

        if alreadyThere {
            let reason = "the log at \(url.path) exists but could not be opened for writing"
            NSLog("ArchiveCleanup: \(reason); this reclaim is unrecorded rather "
                  + "than overwriting the history of past ones.")
            return .refusedToOverwriteExistingLog(reason)
        }

        do {
            try Data(line.utf8).write(to: url)
            return .recorded
        } catch {
            let reason = error.localizedDescription
            NSLog("ArchiveCleanup: could not create the audit log: \(reason)")
            return .couldNotCreate(reason)
        }
    }

    /// Runs the cleanup sweep against the provided events array.
    /// Returns `true` if any event was mutated (caller should persist).
    /// `dataRoot` holds both program scans (`programs/`) and the regeneratable
    /// preview graphics (`preview/`); both sit under the data root so this never
    /// reads the TCC-protected Documents folder at launch.
    @discardableResult
    static func sweep(events: inout [Event], dataRoot: URL,
                      audit: ((Reclaim) -> Void)? = nil) -> Bool {
        // The default sink writes under the dataRoot this sweep was given, not
        // under AppPaths.root. A default reaching the real data root would make
        // a test of a temporary directory append to the live audit log, which
        // is the shape of mistake that log exists to catch.
        let record = audit ?? { appendToAuditLog($0, dataRoot: dataRoot) }
        let now = Date()
        let threshold = TimeInterval(archiveAgeDays) * 86_400
        var dirty = false

        for i in events.indices where events[i].isExported {
            // Events exported before archivedAt existed carry no stamp;
            // falling back to the shoot date would sweep them on the first
            // launch after updating (the shoot is always months older than
            // the export). Stamp them now so the full grace period applies.
            guard let referenceDate = events[i].archivedAt else {
                events[i].archivedAt = now
                dirty = true
                continue
            }
            guard now.timeIntervalSince(referenceDate) > threshold else { continue }

            // duplicateEvent copies org, name, date, and programImagePaths
            // verbatim, so a live duplicate shares this event's preview
            // folder slug and program scans. Never reclaim anything another
            // event still references; a bounded disk leak beats deleting
            // files out from under an active event.
            let event = events[i]
            let others = events.filter { $0.id != event.id }
            let slugShared = others.contains { slug(event: $0) == slug(event: event) }
            let sharedProgramPaths = Set(
                others.flatMap { $0.programImagePaths.map { $0.standardizedFileURL.path } }
            )

            let result = reclaim(
                event: event,
                dataRoot: dataRoot,
                skipPreviewFolder: slugShared,
                sharedProgramPaths: sharedProgramPaths
            )
            record(Reclaim(eventName: event.name, eventID: event.id,
                           slug: slug(event: event), removed: result.removedPaths))
            if result.previewRemoved {
                events[i].previewMediaPaths = [:]
                dirty = true
            }
            if result.programsRemoved {
                events[i].programImagePaths = []
                dirty = true
            }
        }

        return dirty
    }

    /// Deletes the per-event preview folder and any program-scan files this
    /// event still references, except anything shared with another event.
    private static func reclaim(
        event: Event,
        dataRoot: URL,
        skipPreviewFolder: Bool,
        sharedProgramPaths: Set<String>
    ) -> (previewRemoved: Bool, programsRemoved: Bool, removedPaths: [String]) {
        let fm = FileManager.default
        var previewRemoved = false
        var programsRemoved = false
        var removedPaths: [String] = []

        if !skipPreviewFolder {
            let previewParent = dataRoot.appendingPathComponent("preview")
            let previewDir = previewParent.appendingPathComponent(slug(event: event))
            if fm.fileExists(atPath: previewDir.path),
               isInside(previewDir, parent: previewParent) {
                try? fm.removeItem(at: previewDir)
                previewRemoved = true
                removedPaths.append(previewDir.path)
            }
        }

        let programsDir = dataRoot.appendingPathComponent("programs").standardizedFileURL
        for url in event.programImagePaths {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(programsDir.path + "/") else { continue }
            guard !sharedProgramPaths.contains(path) else { continue }
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
                programsRemoved = true
                removedPaths.append(path)
            }
        }

        return (previewRemoved, programsRemoved, removedPaths)
    }

    /// Matches the Python slug in postroll/ai/generate_media.py so we hit the
    /// exact folder generate_media created. Held to that by the shared fixture
    /// rather than by this comment (#108).
    static func slug(event: Event) -> String {
        slug(org: event.org, name: event.name, isoDate: event.isoDate)
    }

    /// The same rule from raw strings, so the parity fixture can exercise it
    /// without building an Event around every vector.
    static func slug(org: String, name: String, isoDate: String) -> String {
        "\(slugify(org))_\(slugify(name))_\(isoDate)"
    }

    static func slugify(_ text: String) -> String {
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
