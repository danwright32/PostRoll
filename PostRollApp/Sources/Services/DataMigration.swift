import Foundation

/// One-time move of user data out of ~/Documents/PostRoll — a TCC-protected
/// folder that made macOS prompt for "access your Documents folder" on every
/// photo read and at launch — into ~/Library/Application Support/PostRoll, which
/// is not gated. Moves `events.json`, `analytics.json`, the `photos/`,
/// `programs/`, `audio/` directories, and the regeneratable `preview/` graphics.
/// The Python project (venv, source, logs) stays in the repo checkout.
///
/// Safety model (a prior attempt lost photos, so this is deliberate):
/// - COPY, never move: the legacy Documents originals are left fully intact.
/// - Verify every copy by file count before trusting it.
/// - Write the `.migrated` marker ONLY after every irreplaceable folder
///   (photos/programs/audio) and events.json are verified. `AppPaths.resolveRoot`
///   keeps reading from Documents until that marker exists, so a denied or
///   partial migration never leaves the app pointing at an empty folder — it
///   just retries on the next launch.
/// - previews and analytics are best-effort (regeneratable / non-critical) and
///   never block completion.
///
/// STATUS: NOT invoked at launch. `AppState.init` deliberately runs no migration
/// (the production Documents→Application Support move was done out-of-band), so
/// this is currently dormant. It is kept — rather than deleted — as a vetted,
/// copy-based recovery tool: a fresh machine whose data still lives in
/// ~/Documents/PostRoll can be migrated by wiring `migrateIfNeeded` to a
/// deliberate action. Do not call it from launch without re-reviewing the
/// data-safety model above.
enum DataMigration {

    /// Entry point (see STATUS above — not currently called). No-op when already
    /// migrated, when running against a redirected data dir (tests/automation),
    /// or when there's nothing in the legacy location.
    static func migrateIfNeeded(
        appSupportRoot: URL = AppPaths.appSupportRoot,
        legacyRoot: URL = AppPaths.legacyDataRoot,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // A redirected data dir means tests/automation — never touch live data.
        if let override = environment["POSTROLL_DATA_DIR"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return
        }
        let fm = FileManager.default

        // Same location (misconfiguration) — nothing to do.
        guard appSupportRoot.standardizedFileURL.path != legacyRoot.standardizedFileURL.path else { return }

        let marker = appSupportRoot.appendingPathComponent(AppPaths.migrationMarker)
        guard !fm.fileExists(atPath: marker.path) else { return }  // already migrated

        try? fm.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)

        // Read the legacy events.json by CONTENT, never by `fileExists`. A
        // TCC-denied path reports as "does not exist" through fileExists, which
        // previously made this take the fresh-install shortcut and stamp the
        // migration complete WITHOUT copying anything (it shipped a half-migrated
        // library). An actual read distinguishes the two cases:
        //  - no-such-file     → genuinely a fresh install; claim App Support.
        //  - permission/other → access not granted yet (the prompt only appears
        //    once the app is active); bail WITHOUT marking, retry on next launch.
        let oldEvents = legacyRoot.appendingPathComponent("events.json")
        let rawEvents: String
        do {
            rawEvents = try String(contentsOf: oldEvents, encoding: .utf8)
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
                fm.createFile(atPath: marker.path, contents: nil)
            } else {
                NSLog("DataMigration: legacy events.json not readable yet (\(error)); will retry.")
            }
            return
        }

        // Irreplaceable data: every one must copy and verify before we commit.
        var criticalOK = true
        for sub in ["photos", "programs", "audio"] {
            if !copyDirVerified(sub, from: legacyRoot, to: appSupportRoot, fm: fm) {
                criticalOK = false
            }
        }

        // Rewrite events.json so every photos/programs/audio/preview reference
        // points at the new root, then write it to the new location.
        let rewritten = rebasePaths(in: rawEvents, from: legacyRoot, to: appSupportRoot)
        let newEvents = appSupportRoot.appendingPathComponent("events.json")
        var eventsOK = false
        do {
            try rewritten.write(to: newEvents, atomically: true, encoding: .utf8)
            eventsOK = true
        } catch {
            NSLog("DataMigration: failed to write rebased events.json: \(error)")
        }

        // Best-effort extras — never block completion on these.
        _ = copyDirVerified("preview", from: legacyRoot, to: appSupportRoot, fm: fm)
        let oldAnalytics = legacyRoot.appendingPathComponent("analytics.json")
        let newAnalytics = appSupportRoot.appendingPathComponent("analytics.json")
        if fm.fileExists(atPath: oldAnalytics.path), !fm.fileExists(atPath: newAnalytics.path) {
            try? fm.copyItem(at: oldAnalytics, to: newAnalytics)
        }

        if criticalOK && eventsOK {
            fm.createFile(atPath: marker.path, contents: nil)
        } else {
            NSLog("DataMigration: incomplete (criticalOK=\(criticalOK), eventsOK=\(eventsOK)); "
                + "still reading from Documents, will retry next launch.")
        }
    }

    /// Copies `<legacyRoot>/<sub>` to `<appSupportRoot>/<sub>` FILE BY FILE and
    /// confirms every source file now exists at the destination. Returns true
    /// when the source is absent (nothing to copy) or every file copied.
    ///
    /// File-by-file (rather than one `copyItem` on the whole directory) for two
    /// reasons: a single unreadable file can't abort the entire copy and silently
    /// drop the other hundreds, and it is idempotent — a file already at the
    /// destination is skipped, so a re-run after a partial/interrupted copy fills
    /// only the gaps instead of trusting (or wiping) what's there. Combined with
    /// the marker only being written when this returns true for every critical
    /// folder, a half-finished migration can never be stamped complete.
    private static func copyDirVerified(
        _ sub: String, from legacyRoot: URL, to appSupportRoot: URL, fm: FileManager
    ) -> Bool {
        let src = legacyRoot.appendingPathComponent(sub)
        let dst = appSupportRoot.appendingPathComponent(sub)
        guard fm.fileExists(atPath: src.path) else { return true }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)

        guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        let srcPrefix = src.standardizedFileURL.path + "/"
        var allCopied = true
        for case let file as URL in en {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = String(file.standardizedFileURL.path.dropFirst(srcPrefix.count))
            let target = dst.appendingPathComponent(rel)
            if fm.fileExists(atPath: target.path) { continue }  // already migrated
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: file, to: target)
            } catch {
                NSLog("DataMigration: failed to copy \(sub)/\(rel): \(error)")
                allCopied = false
            }
        }
        return allCopied
    }

    /// Rebase every reference to `<legacyRoot>/{photos,programs,audio,preview}`
    /// onto `<appSupportRoot>/…`. The data uses several string forms and the
    /// migration must hit all of them:
    /// - percent-encoded `file://` URLs (Codable's `URL`, and dictionary keys
    ///   like photoTags / cropOffsets) and plain filesystem paths (the preview
    ///   manifest stores plain paths), AND
    /// - JSON with forward slashes escaped as `\/` (how EventStore writes them
    ///   on disk) as well as unescaped.
    /// Pure and textual so it catches dict keys too. Other subpaths (`venv`,
    /// `logs`, …) are left untouched — they stay with the Python project.
    static func rebasePaths(in json: String, from legacyRoot: URL, to dataRoot: URL) -> String {
        var out = json
        let legacyPath = legacyRoot.standardizedFileURL.path
        let dataPath   = dataRoot.standardizedFileURL.path
        // absoluteString gives the percent-encoded file:// form (spaces → %20).
        // CRITICAL: build with isDirectory:false so there is NO trailing slash.
        // URL(fileURLWithPath:) stats the path and appends "/" for a real
        // directory, which made "<legacyURL>/photos" become "…/PostRoll//photos"
        // — that double slash never matched the single-slash on-disk form, so the
        // file:// replacement silently no-op'd and the PLAIN-path replacement
        // below clobbered the file:// URLs instead, injecting a literal space into
        // the URL. A later save round-trip then re-encoded that into "%2520",
        // double-encoding every filename and breaking image loads + orphan
        // matching. (The old unit test passed only because its fake paths don't
        // exist, so no trailing slash was added.)
        let legacyURL = URL(fileURLWithPath: legacyPath, isDirectory: false).absoluteString
        let dataURL   = URL(fileURLWithPath: dataPath, isDirectory: false).absoluteString

        func escapeSlashes(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "\\/") }

        for sub in ["photos", "programs", "audio", "preview"] {
            // file:// (percent-encoded) form FIRST so the precise URL match wins,
            // then the plain-path form for any remaining non-URL occurrences
            // (collage cell photoPath, preview manifest). Order matters: once the
            // file:// roots are rebased they no longer contain the legacy plain
            // path, so the plain pass can't corrupt them.
            for (from, to) in [("\(legacyURL)/\(sub)", "\(dataURL)/\(sub)"),
                               ("\(legacyPath)/\(sub)", "\(dataPath)/\(sub)")] {
                // Escaped-slash form first (how it sits on disk), then plain.
                out = out.replacingOccurrences(of: escapeSlashes(from), with: escapeSlashes(to))
                out = out.replacingOccurrences(of: from, with: to)
            }
        }
        return out
    }
}
