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
///   brand-voice files). Discovered from the path this build was made from,
///   which the build stamps into the app bundle; only read during generation,
///   not at launch. POSTROLL_PROJECT_DIR overrides it. Optional, because "we
///   do not know where the checkout is" is a real state and inventing a path
///   for it is what #648 was.
enum AppPaths {
    static let root: URL = resolveRoot()
    static let projectRoot: URL? = resolveProjectRoot()

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

    /// The Info.plist key the build stamps with the checkout it was built from,
    /// written by the app target's "Record the checkout this build was made
    /// from" phase in project.yml. Read back here at runtime.
    ///
    /// A script rather than an `INFOPLIST_KEY_` build setting, which was tried
    /// first and does not work: Xcode maps that prefix onto a known set of
    /// Info.plist keys only, so the setting reached both project.yml and the
    /// generated .xcodeproj and the built app had no such key.
    ///
    /// The name is spelled in two files that cannot share a definition, so
    /// tests/test_project_root_recorded.py checks the two halves against each
    /// other rather than each against a third idea of what it is called.
    static let projectRootInfoKey = "POSTROLLProjectRoot"

    /// What this build recorded, if anything. Absent in the test bundle, which
    /// deliberately does not stamp one, and in any bundle built before #648.
    static func recordedProjectRoot(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: projectRootInfoKey) as? String
    }

    /// Where the Python code lives — separate from data so the data root can sit
    /// outside the TCC-protected Documents folder.
    ///
    /// Discovered rather than assumed (#648). This used to return a hardcoded
    /// `~/Documents/PostRoll`, and when the project moved out of iCloud Drive on
    /// 2026-08-16 that folder stopped existing: generation, the collage
    /// watermark and the brand-voice seed all resolved under a directory that is
    /// not there, and nothing said so. Pointing the same hardcode somewhere new
    /// would only reschedule that for the next move, so the build records where
    /// it was made from and this reads it back. Moving the checkout and
    /// rebuilding now fixes itself.
    ///
    /// Deriving it from the app bundle's OWN location cannot work: an installed
    /// build lives in /Applications and a Debug build lives in DerivedData, and
    /// neither is inside the checkout.
    ///
    /// Returns nil when nothing was recorded and nothing was overridden. That is
    /// deliberate: a fabricated path is indistinguishable from a real one to
    /// every caller downstream, which is precisely how the old defect stayed
    /// quiet. Callers ask `projectRootProblem` what to say about it.
    static func resolveProjectRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        recorded: String? = recordedProjectRoot()
    ) -> URL? {
        if let override = environment["POSTROLL_PROJECT_DIR"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        guard let recorded,
              !recorded.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // Standardized so a path carrying a `..` or a trailing slash compares
        // and prints the same way as one that does not. The build already
        // resolves what it records, so this is belt and braces there, and it is
        // the only cleanup a hand-set POSTROLL_PROJECT_DIR gets.
        return URL(fileURLWithPath: recorded, isDirectory: true).standardizedFileURL
    }

    /// Why the Python checkout cannot be used, or nil when it can.
    ///
    /// Three causes, kept apart because the answer to each is different and a
    /// person told the wrong one goes looking in the wrong place (L11).
    enum ProjectRootProblem: Equatable {
        /// This build stamped no checkout path at all, so it was not built by
        /// the install script.
        case notRecorded
        /// A path is known and there is no folder there. The ordinary case: the
        /// project was moved after this build was made.
        case missing(URL)
        /// The folder is there but the Python package is not in it.
        case notACheckout(URL)
        /// A real checkout, with no Python environment inside it (#651).
        ///
        /// Its own case rather than folded into `notACheckout`, because the
        /// answer is different: the code is present and correct, and what is
        /// missing has to be rebuilt rather than found. Reinstalling the app
        /// does not put one back, so a message offering that would send Dan
        /// round a loop that cannot end (L111).
        case noEnvironment(URL)
    }

    /// Whether `root` can actually be used to run the Python.
    ///
    /// The `postroll` package is what the app runs with `-m`, so its presence is
    /// the thing worth checking rather than the folder merely existing.
    static func projectRootProblem(
        _ root: URL?, fileManager fm: FileManager = .default
    ) -> ProjectRootProblem? {
        guard let root else { return .notRecorded }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .missing(root) }
        guard fm.fileExists(atPath: root.appendingPathComponent("postroll").path) else {
            return .notACheckout(root)
        }
        // The interpreter the app actually runs. Without it the pipeline's
        // packages are not present, and every run fails on an import far from
        // the thing that is wrong (#651).
        guard fm.fileExists(atPath: root.appendingPathComponent("venv/bin/python3").path) else {
            return .noEnvironment(root)
        }
        return nil
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

    /// The suffix each run appends to the event id, one entry per run (#1128).
    ///
    /// One list rather than a name spelled at each writer and again in the
    /// sweep that has to recognise them. It had already drifted: `-ocr` was
    /// added in #467 and `ProgressFileCleanup` never learned it, so every OCR
    /// progress file of every deleted event is still on disk. A hand-written
    /// list in the reader exempts whatever it forgot from the check meant to
    /// catch it (L96), so both halves read this (L41).
    ///
    /// The empty string is the caption run's, which predates the others and
    /// writes `<uuid>.json` with no suffix at all.
    static let progressRunSuffixes = ["", "-media", "-ocr", "-blog", "-blog-photos"]

    private static func progressFile(forEventID id: UUID, suffix: String) -> URL {
        progressDir.appendingPathComponent("\(id.uuidString)\(suffix).json")
    }

    /// Every progress file this app can write for one event.
    ///
    /// What the sweep is held to, and what proves no two runs share a path.
    static func everyProgressFile(forEventID id: UUID) -> [URL] {
        progressRunSuffixes.map { progressFile(forEventID: id, suffix: $0) }
    }

    static func progressFile(forEventID id: UUID) -> URL {
        progressFile(forEventID: id, suffix: "")
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
        progressFile(forEventID: id, suffix: "-media")
    }

    /// Where the program OCR run reports its step (#467).
    ///
    /// Its own file for the same reason as the media one: OCR is a different
    /// run with a different lifetime, and sharing a path would have each
    /// overwrite the other's label.
    static func ocrProgressFile(forEventID id: UUID) -> URL {
        progressFile(forEventID: id, suffix: "-ocr")
    }

    /// Where a blog revision or photo swap reports its step (#1128).
    ///
    /// Its own file for the same reason as the media one. Neither of those two
    /// runs had a progress file at all: each is several sequential Claude
    /// calls, one of them image-carrying, and the app drew a bare indefinite
    /// spinner for the whole of it. The repair pass adds up to seven more calls
    /// to each path.
    static func blogProgressFile(forEventID id: UUID) -> URL {
        progressFile(forEventID: id, suffix: "-blog")
    }

    /// Where a blog PHOTO SWAP reports its step, separate from the revision's
    /// file above (#1128).
    ///
    /// Its own file rather than shared with the revision. The two cannot
    /// currently run at once, but only because of where the controls sit on
    /// one screen: `CaptionWorkManager` tracks them under different keys and
    /// would happily run both. An invariant that lives in a view's layout is
    /// one a later layout change removes silently (L204), and the cost of not
    /// relying on it is one more entry in the list above.
    static func blogPhotoSwapProgressFile(forEventID id: UUID) -> URL {
        progressFile(forEventID: id, suffix: "-blog-photos")
    }
    /// Where a RETRY of the repairs reports its step (#1160).
    ///
    /// Its own file, for the reason the swap's is its own: the runs are tracked
    /// under different keys and nothing but the current layout stops two
    /// starting, and an invariant that lives in a view's layout is one a later
    /// layout change removes silently (L204).
    static func blogRepairRetryProgressFile(forEventID id: UUID) -> URL {
        progressFile(forEventID: id, suffix: "-blog-retry")
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
    /// Nil when the checkout cannot be located, rather than a path under a
    /// folder that does not exist (#648).
    static var brandVoiceSeed: URL? {
        projectRoot?.appendingPathComponent("postroll/assets/brand-voice.md")
    }

    /// Copies the checkout's brand-voice.md into the data root once, if the
    /// writable copy is absent. Called lazily at generation/append time (never at
    /// launch), so the single Documents read is a one-time migration that also
    /// carries over any notes the user already accumulated in the old location.
    /// No checkout means no seed to copy. Nothing is said about it here because
    /// nothing can run without the checkout anyway: the caller refuses first,
    /// by name, before any of this is reached.
    static func ensureBrandVoiceSeeded() {
        guard let seed = brandVoiceSeed else { return }
        seedBrandVoice(into: root, from: seed)
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

        /// Where an in-flight app update reports the step it is on (#686).
        ///
        /// The same shape as a generation's step file, so the sheet shows it
        /// through the one progress indicator this app has rather than a second
        /// one grown beside it. Not keyed by event: there is one PostRoll and
        /// only ever one update of it.
        var updateProgressFile: URL {
            progressDir.appendingPathComponent("app-update.json")
        }

        /// Where an app update records how it ended.
        ///
        /// Separate from the step file because they answer different questions
        /// and are read at different times: the step file says where the work
        /// is and is read on a timer while the app is open, this says how it
        /// finished and is read at the next launch, which is usually the only
        /// place a failure after the install step can still be seen (L148).
        var updateOutcomeFile: URL {
            progressDir.appendingPathComponent("app-update-outcome.json")
        }

        /// Everything the update said, for when the outcome's last lines are
        /// not enough. Its own file rather than the shared postroll.log: a run
        /// diagnosed from an unscoped tail of a shared log is how a UUID
        /// containing "413" once turned a 401 into "photos too large" (#90).
        var updateLogFile: URL {
            logsDir.appendingPathComponent("app-update.log")
        }
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
        /// The SOURCE was not there, so there was nothing to copy (#971).
        ///
        /// Its own state rather than one more message nobody can branch on. A
        /// file that is gone and a copy that could not be made need opposite
        /// responses: the first belongs to the missing-media flow and must not
        /// be re-attempted every launch, the second is worth retrying and worth
        /// telling somebody about (L11, L35).
        ///
        /// Defaulted, so the call sites that construct a real copy failure are
        /// unchanged and cannot accidentally claim this one.
        var sourceIsMissing: Bool = false
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
        // Before ANY work (#971). Measured on the live store on 2026-08-29,
        // 1,514 stored paths point at files that are no longer there, and each
        // one cost a createDirectory, a destination check, a doomed copyItem
        // and an NSLog on every cold launch, on the main thread before the
        // first frame. None of it could ever succeed.
        //
        // Reported as its own state rather than as a copy failure, because the
        // two need opposite responses and the caller has to be able to tell
        // them apart (L11).
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(ImportCopyFailure(
                fileName: url.lastPathComponent,
                message: "the file is no longer at \(url.path)",
                sourceIsMissing: true))
        }
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

/// What Dan is told when PostRoll cannot reach its own code folder (#648).
///
/// Kept out of the views so the wording can be pinned by a test, the same way
/// `ImportFailureText` is.
///
/// The sentences say "code folder" rather than "project root" or "checkout",
/// because Dan does not use the terminal and the thing he actually did was move
/// a folder in Finder. Each one names the path it looked in.
///
/// They mention photos only to say his are NOT affected, which is worth telling
/// someone who has just read that the app cannot find part of itself. What none
/// of them does is send him to CHANGE them: the message this replaces told him
/// to check that his photos were still in their original locations, and offered
/// the route back to the photo screen, over a folder that had nothing to do with
/// them (L11).
enum ProjectRootText {
    static func message(_ problem: AppPaths.ProjectRootProblem) -> String {
        switch problem {
        case .notRecorded:
            return "PostRoll cannot tell where its own code folder is, so it cannot generate "
                 + "anything. This copy of the app was built without recording one, which "
                 + "usually means it was not installed by the usual build. Reinstall PostRoll "
                 + "from the project folder and it will record the right place. Your photos "
                 + "and saved events are not affected."
        case .missing(let root):
            return "PostRoll cannot find its own code folder, so it cannot generate anything. "
                 + "It looked in \(root.path), and there is no folder there. If you moved the "
                 + "project, reinstall PostRoll from where it is now and it will point at the "
                 + "new place. Your photos and saved events are not affected."
        // "code folder" in all three, deliberately: one word for one thing, so
        // two of these read side by side cannot look like different subjects
        // (L118).
        case .notACheckout(let root):
            return "PostRoll found \(root.path), but its code folder is not inside it, so it "
                 + "cannot generate anything. If you moved the project, reinstall PostRoll from "
                 + "where it is now. Your photos and saved events are not affected."
        // No reinstall offered here, on purpose. The code folder is present and
        // correct; what is missing is the Python environment inside it, and
        // installing the app again does not create one. Telling him to reinstall
        // would be advice that cannot change the state he is in (L111).
        case .noEnvironment(let root):
            return "PostRoll's Python environment is missing from \(root.path), so it cannot "
                 + "generate anything. The code is all there, but the packages it runs on are "
                 + "not, and they have to be set up again in that folder before anything will "
                 + "work. Your photos and saved events are not affected."
        }
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
