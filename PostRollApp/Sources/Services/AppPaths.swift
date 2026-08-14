import Foundation

/// Single source of truth for where PostRoll keeps its files on disk.
///
/// Two distinct roots:
/// - `root` — user DATA (events.json, photos, programs, audio) plus the
///   regeneratable `preview/` graphics. Resolves to ~/Library/Application
///   Support/PostRoll once `DataMigration` has moved data there (marker present),
///   which is NOT a TCC-protected location, so neither the app nor its Python
///   subprocess prompts at launch or while editing. Until the verified move
///   completes it stays at the legacy ~/Documents/PostRoll so the app keeps
///   working. POSTROLL_DATA_DIR redirects this for tests.
/// - `projectRoot` — the Python project checkout (venv, source, logs,
///   brand-voice files). Stays in ~/Documents/PostRoll; only read during
///   generation, not at launch. POSTROLL_PROJECT_DIR overrides it.
enum AppPaths {
    static let root: URL = resolveRoot()
    static let projectRoot: URL = resolveProjectRoot()

    /// Marker file (inside `appSupportRoot`) written by `DataMigration` only once
    /// a verified copy of every irreplaceable data folder has completed. Its
    /// presence is the single source of truth for "data now lives in Application
    /// Support"; until then `resolveRoot` keeps returning the legacy Documents
    /// location so a denied or partial migration never points the app at an
    /// empty folder.
    static let migrationMarker = ".migrated"

    /// The pre-migration data location. Always ~/Documents/PostRoll regardless
    /// of any project-root override, so `DataMigration` can find legacy data.
    static var legacyDataRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/PostRoll")
    }

    /// The post-migration data location: ~/Library/Application Support/PostRoll,
    /// which is NOT a TCC-protected folder, so neither the app nor its Python
    /// subprocess prompts when reading data, previews, photos, etc.
    static var appSupportRoot: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PostRoll")
    }

    /// Split out so tests can exercise the override logic with an injected
    /// environment; the static `root` resolves once per process.
    ///
    /// Returns Application Support once `DataMigration` has dropped its marker
    /// there, otherwise the legacy Documents folder. Because the marker is only
    /// written after a verified copy, the app reads live data from Documents
    /// (working, but prompting) until the move is genuinely complete, then
    /// switches to the unprotected location and never prompts at launch again.
    static func resolveRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager fm: FileManager = .default
    ) -> URL {
        if let override = environment["POSTROLL_DATA_DIR"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let appSupport = appSupportRoot
        if fm.fileExists(atPath: appSupport.appendingPathComponent(migrationMarker).path) {
            return appSupport
        }
        return legacyDataRoot
    }

    /// Where the Python code lives — separate from data so the data root can sit
    /// outside the TCC-protected Documents folder.
    static func resolveProjectRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["POSTROLL_PROJECT_DIR"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/PostRoll")
    }

    static var eventsFile: URL { layout.eventsFile }
    /// Generation logs. Under the data root (not the Documents checkout) so the
    /// Python subprocess never writes to the TCC-protected folder during a run.
    static var logsDir: URL { layout.logsDir }

    /// Where a running generation reports the step it is on, per event (#95,
    /// #96). One known path per event rather than a value threaded through
    /// every call, so any screen showing that event's progress can read it
    /// without the path being handed down to it.
    static var progressDir: URL { layout.progressDir }

    static func progressFile(forEventID id: UUID) -> URL {
        progressDir.appendingPathComponent("\(id.uuidString).json")
    }

    /// Where the MEDIA run reports its step, separate from the caption run's
    /// file above (#234).
    ///
    /// Its own file because the two runs happen at the same time: a full
    /// generation fires captions and graphics in parallel. Sharing one file
    /// would have each overwrite the other's label, so the screen would flip
    /// between "Writing the Sunday caption" and "Wednesday: collage" and
    /// neither surface could trust what it read (L8).
    static func mediaProgressFile(forEventID id: UUID) -> URL {
        progressDir.appendingPathComponent("\(id.uuidString)-media.json")
    }

    /// Where the program OCR run reports its step (#467).
    ///
    /// Its own file for the same reason as the media one: OCR is a different
    /// run with a different lifetime, and sharing a path would have each
    /// overwrite the other's label.
    static func ocrProgressFile(forEventID id: UUID) -> URL {
        progressDir.appendingPathComponent("\(id.uuidString)-ocr.json")
    }
    static var logFile: URL { logsDir.appendingPathComponent("postroll.log") }

    /// The logs folder as it should appear in a message to Dan.
    ///
    /// Derived, never written out by hand: the data root moved to Application
    /// Support and every hardcoded "~/Documents/PostRoll/logs" in a user-facing
    /// string kept pointing at the old place, sending him to a folder with
    /// nothing in it (#101).
    static var logsDirDisplayPath: String {
        (logsDir.path as NSString).abbreviatingWithTildeInPath
    }
    /// Writable brand voice doc. Lives under the data root (not the TCC-protected
    /// Documents checkout) so generation-time reads/appends never prompt. Seeded
    /// once from the checkout's read-only default via `ensureBrandVoiceSeeded`.
    static var brandVoiceFile: URL { layout.brandVoiceFile }
    /// The read-only default shipped in the Python checkout — the seed source.
    static var brandVoiceSeed: URL {
        projectRoot.appendingPathComponent("postroll/assets/brand-voice.md")
    }

    /// Copies the checkout's brand-voice.md into the data root once, if the
    /// writable copy is absent. Called lazily at generation/append time (never at
    /// launch), so the single Documents read is a one-time migration that also
    /// carries over any notes the user already accumulated in the old location.
    static func ensureBrandVoiceSeeded() {
        seedBrandVoice(into: root, from: brandVoiceSeed)
    }

    /// Injectable core of `ensureBrandVoiceSeeded` (so it can be unit-tested
    /// against temp dirs). Copies `seed` to `<root>/brand-voice.md` only when the
    /// destination is absent; a present writable copy is never overwritten, and a
    /// missing seed is a no-op rather than an error.
    static func seedBrandVoice(into root: URL, from seed: URL, fileManager fm: FileManager = .default) {
        let dest = root.appendingPathComponent("brand-voice.md")
        guard !fm.fileExists(atPath: dest.path) else { return }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.copyItem(at: seed, to: dest)
    }
    static var analyticsFile: URL { layout.analyticsFile }
    static var programsDir: URL { layout.programsDir }
    /// Canonical location of an event's baked, searchable program PDF (one per
    /// event), so the upload-time bake and the on-demand rebuild agree on it.
    static func programPDFFile(eventID: UUID) -> URL {
        programsDir.appendingPathComponent("\(eventID.uuidString)_program.pdf")
    }
    static var photosDir: URL { layout.photosDir }
    static var audioDir: URL { layout.audioDir }
    /// Video clips (Friday auto-cut clip reel). A dedicated directory rather
    /// than reusing photosDir. Clips are large 4K video files with a
    /// different size/lifecycle profile than photos.
    static var clipsDir: URL { layout.clipsDir }
    /// Where Python writes collage/reel preview graphics. Lives under the data
    /// root (not the Documents project checkout) so the caption review screen,
    /// which reloads these on every visit, never triggers a TCC prompt.
    static var previewDir: URL { layout.previewDir }

    /// Every folder and file the app keeps, expressed against one root.
    ///
    /// The statics above are this struct built on the live `root`. A test (or
    /// any sweep that must not reach live media) builds one on a temp directory
    /// instead and is then structurally unable to touch real data (L2), rather
    /// than being trusted to pass the right four directories to every call.
    ///
    /// One place naming these folders, so the backup doc's inventory and the
    /// code cannot drift apart (L41): `DataInventory` reads its names from here.
    struct Layout {
        let root: URL

        var eventsFile: URL { root.appendingPathComponent("events.json") }
        var analyticsFile: URL { root.appendingPathComponent("analytics.json") }
        var brandVoiceFile: URL { root.appendingPathComponent("brand-voice.md") }
        var accountsFile: URL { root.appendingPathComponent("accounts.json") }
        var photosDir: URL { root.appendingPathComponent("photos") }
        var audioDir: URL { root.appendingPathComponent("audio") }
        var clipsDir: URL { root.appendingPathComponent("clips") }
        var programsDir: URL { root.appendingPathComponent("programs") }
        var previewDir: URL { root.appendingPathComponent("preview") }
        var logsDir: URL { root.appendingPathComponent("logs") }
        var progressDir: URL { root.appendingPathComponent("progress") }
    }

    static var layout: Layout { Layout(root: root) }

    static var accountsFile: URL { layout.accountsFile }

    /// True when `url` already lives under `storageRoot`.
    static func isInside(_ url: URL, root storageRoot: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(storageRoot.standardizedFileURL.path + "/")
    }

    /// True when `url` already lives inside the app's own storage.
    static func isInsideAppStorage(_ url: URL) -> Bool { isInside(url, root: root) }

    /// Copies an external file into `dir` (inside the app's storage) and returns
    /// the new URL. Files the user picks from ~/Downloads, ~/Desktop, etc. are
    /// gated by macOS per app launch; copying them into the app's own folder
    /// means later reads (thumbnails, export) don't re-trigger that permission
    /// prompt. Names are uniquified so two different files can't collide.
    /// Returns `url` unchanged when it is already inside app storage, or nil on
    /// copy failure. `storageRoot` is injectable so tests can run against a
    /// temporary tree.
    static func importedCopy(of url: URL, into dir: URL, storageRoot: URL = AppPaths.root) -> URL? {
        try? importedCopyResult(of: url, into: dir, storageRoot: storageRoot).get()
    }

    /// Why a picked file couldn't be brought into app storage, in the terms the
    /// person who picked it needs: which file, and what went wrong.
    struct ImportCopyFailure: Error, Equatable {
        let fileName: String
        let message: String
    }


    /// Copies an external file into `dir` (inside the app's storage) and returns
    /// the new URL. Files the user picks from ~/Downloads, ~/Desktop, etc. are
    /// gated by macOS per app launch; copying them into the app's own folder
    /// means later reads (thumbnails, export) don't re-trigger that permission
    /// prompt. Names are uniquified so two different files can't collide.
    /// Returns `url` unchanged when it is already inside app storage.
    ///
    /// A failure is returned, never swallowed: handing the caller the external
    /// URL to persist is what let an import report success and then break the
    /// moment the source folder was renamed (#179). `storageRoot` is injectable
    /// so tests can run against a temporary tree.
    static func importedCopyResult(
        of url: URL, into dir: URL, storageRoot: URL = AppPaths.root
    ) -> Result<URL, ImportCopyFailure> {
        if isInside(url, root: storageRoot) { return .success(url) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
            dest = dir.appendingPathComponent("\(stem)_\(UUID().uuidString.prefix(8)).\(ext)")
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return .success(dest)
        } catch {
            NSLog("AppPaths.importedCopy failed for \(url.lastPathComponent): \(error)")
            return .failure(ImportCopyFailure(fileName: url.lastPathComponent,
                                              message: error.localizedDescription))
        }
    }

    /// The sanctioned way to turn a user-picked file into a path safe to
    /// persist. Every import entry point (file picker, folder/auto import) must
    /// route picked URLs through these so a raw ~/Downloads/~/Desktop URL never
    /// reaches the Event model — otherwise later reads (collage edits, exports)
    /// re-trigger the macOS permission prompt.
    ///
    /// These return a Result rather than a URL on purpose: a call site cannot
    /// persist the picked path by accident, because it never gets it back.
    static func storedPhoto(_ url: URL) -> Result<URL, ImportCopyFailure> {
        importedCopyResult(of: url, into: photosDir)
    }
    static func storedAudio(_ url: URL) -> Result<URL, ImportCopyFailure> {
        importedCopyResult(of: url, into: audioDir)
    }
    static func storedClip(_ url: URL) -> Result<URL, ImportCopyFailure> {
        importedCopyResult(of: url, into: clipsDir)
    }
}

/// What the user is told when a picked file couldn't be brought into app
/// storage. Those files are deliberately NOT imported (persisting the external
/// path is what silently broke events when a source folder was renamed, #179),
/// so the message has to say they were left out. Kept out of the view so the
/// wording can be pinned by a test.
enum ImportFailureText {
    static func message(_ failures: [AppPaths.ImportCopyFailure]) -> String {
        guard let first = failures.first else { return "" }
        if failures.count == 1 {
            // The reason is a Cocoa file-system error, which is a whole sentence
            // ending in a stop, so parenthesising it and adding another produced
            // "(...already exists.)." The existing test's fixture had no
            // terminator, so nothing exercised the real shape (#405).
            return "\(first.fileName) was not imported: PostRoll couldn't copy it into "
                 + "its own storage. \(Sentence.closed(first.message)) Linking it where "
                 + "it sits would break as soon as that folder moves."
        }
        let names = failures.map(\.fileName).joined(separator: ", ")
        return "\(failures.count) files were not imported: PostRoll couldn't copy them into its own storage. Files: \(names)."
    }

    /// Folders a folder import could not read at all, keyed by name (#451).
    ///
    /// Its own message rather than the no-photos-found one, because the two
    /// need opposite responses: that one coaches Dan through renaming his day
    /// folders, and renaming a folder macOS will not let the app open changes
    /// nothing (L11). Sorted so the same failure reads the same way twice.
    static func unreadableFolders(_ folders: [String: String]) -> String {
        let named = folders.keys.sorted()
            .map { "\($0) (\(folders[$0] ?? ""))" }
            .joined(separator: ", ")
        let one = folders.count == 1
        return "\(one ? "This folder" : "These folders") could not be read, so nothing in "
             + "\(one ? "it" : "them") was imported: \(named). This is usually a "
             + "permissions problem rather than a naming one: grant PostRoll access under "
             + "System Settings > Privacy & Security > Files and Folders, then import again."
    }
}

/// One place every "the user picked some files" path goes through, so a picked
/// URL can't reach the Event model without being copied into app storage first
/// (#77, #145) and a copy that fails can't be silently swapped for the external
/// path (#179).
enum ImportedPicks {
    struct Outcome {
        /// The picks that made it into app storage. Safe to persist.
        let stored: [URL]
        /// The picks that did not, deliberately left out.
        let failures: [AppPaths.ImportCopyFailure]

        /// What to show the user, or nil when everything copied.
        var failureMessage: String? {
            failures.isEmpty ? nil : ImportFailureText.message(failures)
        }
    }

    static func copy(_ urls: [URL],
                     into dir: URL = AppPaths.photosDir,
                     storageRoot: URL = AppPaths.root) -> Outcome {
        var stored: [URL] = []
        var failures: [AppPaths.ImportCopyFailure] = []
        for url in urls {
            switch AppPaths.importedCopyResult(of: url, into: dir, storageRoot: storageRoot) {
            case .success(let copied): stored.append(copied)
            case .failure(let error):  failures.append(error)
            }
        }
        return Outcome(stored: stored, failures: failures)
    }
}
