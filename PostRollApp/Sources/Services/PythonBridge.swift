import Foundation

// PythonBridgeError and PythonBridgeLog live in PythonBridgeError.swift
// (kept dependency-light so PostRollTests can compile them directly).

actor PythonBridge {
    static let shared = PythonBridge()

    /// Sentinel values that mark "I looked this up and there's no Instagram."
    /// Stored in the handle book so we don't re-search, but not passed to captions.
    private static let handleSentinels: Set<String> = [
        "unknown", "n/a", "na", "none", "-", "no", "skip",
    ]

    /// Drops later case-insensitive repeats, keeping the first spelling seen.
    /// Credits arrive from several places (event handles, performer checkboxes,
    /// typed-in extras, per-photo tags) and the same person routinely turns up
    /// in more than one.
    nonisolated static func dedupedPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let key = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(value)
        }
        return out
    }

    /// Whether this value may be offered to a caption as an account to mention.
    ///
    /// Two questions, both of which have to be no (L118). A SENTINEL is a
    /// recorded answer: somebody looked and there is no Instagram, and it is
    /// stored so nobody searches again. A value that is not SHAPED like a
    /// handle is a different thing entirely, and until #899 nothing asked it:
    /// a company's row carried its own display name, "DPR Dance", this
    /// returned true, and the caption prompt was handed `@DPR Dance` as an
    /// account to mention. The model wrote it, and `@DPR` belongs to somebody.
    ///
    /// Every list built from performers reads this, so all of them agree: the
    /// tag suggestions, the caption credits, the duplicate marks and the
    /// handle book. A row failing it is credited by NAME instead, which is
    /// what should have happened for that company from the start.
    nonisolated static func isRealHandle(_ handle: String) -> Bool {
        var h = handle.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("@") { h = String(h.dropFirst()) }
        guard !h.isEmpty, !handleSentinels.contains(h) else { return false }
        return CaptionBlocks.isHandleShaped(handle)
    }

    // nonisolated lets these be read from Task.detached without hopping back to the actor
    /// Nil when this build recorded no checkout and none was overridden (#648).
    /// Every run goes through `preflight`, which turns that into a named
    /// refusal rather than letting it become a path under a folder that is not
    /// there.
    nonisolated let projectRoot: URL?

    private init() {
        // The Python code (venv, source, preview output) lives in the project
        // checkout, separate from the user data root (AppPaths.root).
        projectRoot = AppPaths.projectRoot
    }

    /// The interpreter a run uses, which is always the checkout's own (#651).
    ///
    /// There is deliberately no fallback to a Python found on the machine. One
    /// used to be picked silently from Homebrew, /usr/local or /usr/bin when
    /// the checkout had no environment, and a system Python does not have the
    /// packages the pipeline imports, so the run failed later, somewhere else,
    /// with an import error that named none of this. `preflight` refuses by
    /// name before it gets that far, which means this path is only ever reached
    /// with an environment that exists.
    nonisolated static func interpreter(in projectRoot: URL) -> String {
        projectRoot.appendingPathComponent("venv/bin/python3").path
    }

    /// The checkout, or a refusal naming why it cannot be used (#648).
    ///
    /// Called before anything is launched. It has to be here rather than left
    /// to the failure classifier afterwards, because what comes back from a run
    /// that went ahead is only the shell's `cd` line, and at that point the
    /// three causes (nothing recorded, folder gone, folder is not a checkout)
    /// are no longer distinguishable from each other or from a missing photo.
    ///
    /// A pure function taking the root rather than reading the static one, so
    /// each outcome it enumerates can be built and seen (L151).
    nonisolated static func preflight(projectRoot: URL?,
                                      fileManager: FileManager = .default) throws -> URL {
        if let problem = AppPaths.projectRootProblem(projectRoot, fileManager: fileManager) {
            throw PythonBridgeError.projectRootUnavailable(problem)
        }
        // Non-nil whenever the problem is nil: `projectRootProblem` answers
        // `.notRecorded` for a nil root, so this cannot be reached with one.
        guard let projectRoot else {
            throw PythonBridgeError.projectRootUnavailable(.notRecorded)
        }
        return projectRoot
    }

    // MARK: - Public API

    // MARK: - Week generation

    /// What a week run that exited non-zero actually left behind.
    ///
    /// A halt is not a crash. `generate_week` stops the whole week when it
    /// recognises a usage cap, saves everything finished so far, records why in
    /// `stopped_reason`, and then raises, which exits non-zero. Before #262 that
    /// non-zero exit was the end of it: the results file was never opened, so
    /// the reason and every finished day went with the temp directory, and the
    /// halt screen #257 built could never appear.
    enum WeekRunOutcome {
        /// The run stopped at a cap. The days inside are real.
        case halted(WeekGenerationResult)
        /// An ordinary failure, carrying the original error rather than a
        /// summary of it, plus anything worth keeping.
        ///
        /// `salvaged` is the reason this is not just an error. `generate_week`
        /// persists after every day precisely so a kill at any point keeps what
        /// finished (#206), and the case that motivated it is the app's own
        /// 1800s watchdog: a SIGTERM raises nothing in Python, so the file is
        /// left with `complete: false` and no stop reason. Nothing read it, so
        /// every caption that had generated in those thirty minutes was thrown
        /// away with the temp directory, which is the outcome #206 was written
        /// to prevent (#262).
        case failed(Error, salvaged: WeekGenerationResult?)
    }

    /// Decide what a failed run left behind, from its output file's bytes.
    ///
    /// Pure and separate from the subprocess call so the shapes it must refuse
    /// can be enumerated. Refusing matters more than accepting here: unreadable
    /// leftovers must surface the original error rather than decode to a blank
    /// week, because a blank week that reads as finished is worse than a visible
    /// failure (L10).
    nonisolated static func weekOutcome(forFailedRun data: Data?,
                                        underlying: Error) -> WeekRunOutcome {
        guard let data,
              var week = try? JSONDecoder().decode(WeekGenerationResult.self, from: data)
        else { return .failed(underlying, salvaged: nil) }

        week.stampOriginals()

        // A blank reason is not a halt: the key is written on every save, so
        // treating "present" as "halted" would offer the paid re-run after every
        // ordinary crash.
        let reason = week.stoppedReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !reason.isEmpty { return .halted(week) }

        // Not a halt, but the run may still have finished days before it died.
        // Nothing to salvage from an empty week, and offering one would replace
        // a good saved week with a blank.
        return .failed(underlying, salvaged: week.hasAnyContent ? week : nil)
    }

    /// How long each phase of a week run took, as generate_week reports it.
    ///
    /// A phase that did not run stays nil rather than becoming zero: a week with
    /// no blog photos never timed a blog, and scoring that as zero seconds pulls
    /// the rolling-mean estimate down with a measurement nobody took.
    struct WeekTiming: Equatable {
        var captions: Double?
        var blog: Double?
        var packaging: Double?
    }

    /// Parses the timing sidecar. A pure seam so the nil-not-zero rule is
    /// testable without running a generation.
    nonisolated static func parseWeekTiming(_ raw: [String: Double?]) -> WeekTiming {
        WeekTiming(captions:  raw["captions"]  ?? nil,
                   blog:      raw["blog"]      ?? nil,
                   packaging: raw["packaging"] ?? nil)
    }

    /// Run week generation. Pass `onlyDays` to regenerate a subset of days/blog
    /// without touching days that already succeeded.
    ///
    /// Throws `WeekGenerationHalted` when the run stopped at a usage cap, so the
    /// caller can save what finished and offer the two ways forward rather than
    /// showing a crash.
    func runWeekGeneration(event: Event, onlyDays: Set<String>? = nil,
                           forcePaidPath: Bool = false) async throws -> WeekGenerationResult {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_manifest_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_week_\(UUID().uuidString).json")
        let timingFile   = tmp.appendingPathComponent("postroll_timing_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
            try? FileManager.default.removeItem(at: timingFile)
        }

        // Build manifest
        let manifest = try buildManifest(event: event, onlyDays: onlyDays)
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestFile)

        // Run Python. The progress file is per event and lives at a known path
        // rather than in the temp dir with the others, because the screens that
        // show this run's status read it directly (#95, #96). Cleared first so
        // a previous run's last step cannot be shown as this one's.
        let progressFile = AppPaths.progressFile(forEventID: event.id)
        try? FileManager.default.createDirectory(
            at: AppPaths.progressDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: progressFile)

        let args = [
            "-m", "postroll.ai.generate_week",
            "--manifest", manifestFile.path,
            "--output",   outputFile.path,
            "--timing",   timingFile.path,
            "--progress", progressFile.path,
        ]
        // Left in place on the way out: the last step of a finished run is
        // marked done, and a run that DIED leaves the step it died in, which is
        // the most useful thing anyone can be told about it.
        do {
            try await runProcess(args: args, forcePaidPath: forcePaidPath)
        } catch {
            // The results file outlives a non-zero exit, and on a halt it holds
            // the reason plus every day that finished. Reading it here is what
            // makes #257's halt screen reachable at all (#262).
            switch Self.weekOutcome(forFailedRun: try? Data(contentsOf: outputFile),
                                    underlying: error) {
            case .halted(let week):
                throw WeekGenerationHalted(week: week)
            case .failed(let real, let salvaged):
                guard let salvaged else { throw real }
                throw WeekGenerationFailedWithPartial(underlying: real, week: salvaged)
            }
        }

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        do {
            var result = try JSONDecoder().decode(WeekGenerationResult.self, from: data)
            result.stampOriginals()

            // Only record per-phase timings when at least one caption or blog
            // actually got produced. Pure-error runs are usually <10s and would
            // pull the rolling-mean estimate down toward zero.
            if result.hasAnyContent,
               let timingData = try? Data(contentsOf: timingFile),
               let raw = try? JSONDecoder().decode([String: Double?].self, from: timingData) {
                let timing = Self.parseWeekTiming(raw)
                TimingStore.shared.recordGenerationPhases(
                    captions:  timing.captions,
                    blog:      timing.blog,
                    packaging: timing.packaging
                )
            }

            return result
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Media generation (stories + collage)

    /// Generates story images for each day and a masonry collage for Wednesday.
    /// Throws on Python error; individual day failures are logged but non-fatal.
    /// Pass `days = nil` (the default) to render the whole week or a specific
    /// set to scope generation to just those days.
    /// Returns the images written AND the per-day failures Python reported.
    ///
    /// The errors used to be dropped here while the preview path read them, so
    /// a day that failed during a real export left a folder quietly missing an
    /// asset and said nothing (#262).
    func runMediaGeneration(event: Event, outputDir: URL,
                            days: [String]? = nil) async throws -> PreviewGenerationResult {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_media_manifest_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_media_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let manifestData = try JSONSerialization.data(
            withJSONObject: buildMediaManifest(event: event), options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestFile)

        // Its own progress file, separate from the caption run's, because the
        // two run at the same time and would otherwise overwrite each other's
        // label (#234).
        let progressFile = AppPaths.mediaProgressFile(forEventID: event.id)
        try? FileManager.default.createDirectory(
            at: AppPaths.progressDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: progressFile)

        var args = [
            "-m", "postroll.ai.generate_media",
            "--manifest",   manifestFile.path,
            "--output-dir", outputDir.path,
            "--output",     outputFile.path,
            "--progress",   progressFile.path,
            "--final-export",
        ]
        if let days, !days.isEmpty {
            args += ["--only-days"] + days
        }
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PythonBridgeError.invalidOutput(
                "The media run's result file could not be read.")
        }
        return Self.parseMediaOutput(json)
    }

    /// Render `count` candidate collage layouts for `day` (each a distinct seed)
    /// into a temp directory, for the in-app layout gallery. The caller stores
    /// the chosen candidate's `seed` as the day's collageSeed so the final
    /// render reproduces it. Returns the candidates (empty on failure).
    func renderCollageCandidates(event: Event, day: DayName, count: Int = 6) async throws -> [CollageCandidate] {
        guard let pd = event.days[day.rawValue], !pd.photoPaths.isEmpty else { return [] }
        // `effectiveCount`, like every other place that asks how many of a
        // day's photos are actually posted (#1010).
        let photoCount = event.effectivePostingPreset
            .effectiveCount(for: day, assigned: pd.photoPaths.count) ?? pd.photoPaths.count
        let photos = Array(pd.photoPaths.prefix(photoCount)).map { $0.path }
        guard !photos.isEmpty else { return [] }

        let tmp = FileManager.default.temporaryDirectory
        // Deterministic per-day output dir (issue #64): a cancelled or rapidly
        // re-opened render reuses the same directory instead of orphaning a fresh
        // UUID dir each time, so the temp footprint stays bounded to one dir per
        // collage day. Clear it first so a prior partial render can't leave stale
        // candidate PNGs that outlive their seeds.
        let outDir = tmp.appendingPathComponent("postroll_collage_candidates_\(day.rawValue)")
        try? FileManager.default.removeItem(at: outDir)
        let jsonFile = tmp.appendingPathComponent("postroll_collage_candidates_\(UUID().uuidString).json")
        let cropFile = tmp.appendingPathComponent("postroll_collage_crops_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: jsonFile)
            try? FileManager.default.removeItem(at: cropFile)
            // Leave outDir PNGs in place — the caller reads them for the gallery
            // and CollageCandidateCache removes the dir when superseded.
        }

        let logo = projectRoot?.appendingPathComponent("postroll/assets/logo-black.png").path
        var args = [
            "-m", "postroll.media.generate_collage",
            "--photos",
        ] + photos
        args += [
            "--event", event.name,
            "--org", event.org,
            "--venue", event.venue,
            "--candidates", String(count),
            "--candidates-out", outDir.path,
            "--candidates-json", jsonFile.path,
        ]
        if let logo, FileManager.default.fileExists(atPath: logo) {
            args += ["--logo", logo]
        }
        // Pass the day's saved per-photo crop offsets so the gallery thumbnails
        // match the final collage (#62). Only when at least one is non-default.
        let offsets = Array(pd.photoPaths.prefix(photoCount)).map { url -> [Double] in
            let o = pd.collageCropOffsets[url.absoluteString] ?? CropOffset()
            return [o.x, o.y, o.scale]
        }
        args += try Self.cropOffsetsArgument(offsets: offsets, writingTo: cropFile)
        try await runProcess(args: args)

        return try Self.decodeCollageCandidates(from: jsonFile)
    }

    /// The `--crop-offsets-json` argument for a layout run, or nothing when the
    /// day carries no crops worth sending.
    ///
    /// The argument is produced only after the file it names is on disk. It
    /// used to be appended whether or not the write behind it worked, and
    /// Python reads that path unguarded, so a failed write reached Dan as a
    /// FileNotFoundError about a temp file rather than as anything about his
    /// crops (#360).
    ///
    /// Refusing beats carrying on without them: options rendered from the
    /// wrong crops look like real options, and he would choose a layout from
    /// thumbnails that do not match what gets exported (L75).
    nonisolated static func cropOffsetsArgument(
        offsets: [[Double]], writingTo cropFile: URL
    ) throws -> [String] {
        guard offsets.contains(where: { $0[0] != 0 || $0[1] != 0 || $0[2] != 1.0 })
        else { return [] }

        do {
            let cropData = try JSONSerialization.data(withJSONObject: offsets)
            try cropData.write(to: cropFile)
        } catch {
            throw PythonBridgeError.invalidOutput(
                "Your saved crops for this day couldn't be handed to the layout "
                + "renderer, so the options would have ignored them: "
                + error.localizedDescription)
        }
        return ["--crop-offsets-json", cropFile.path]
    }

    /// Read the layout gallery's result file.
    ///
    /// Everything that can go wrong here is technical, and none of it means the
    /// day has no photos. That distinction is the whole point: the two
    /// no-photos branches return before Python is ever run, so an empty array
    /// out of `renderCollageCandidates` now means only what the view's message
    /// says it means, and a read or decode failure carries its own reason
    /// instead of borrowing that one (#358).
    nonisolated static func decodeCollageCandidates(from jsonFile: URL) throws -> [CollageCandidate] {
        let data: Data
        do {
            data = try Data(contentsOf: jsonFile)
        } catch {
            throw PythonBridgeError.outputMissing
        }

        let candidates: [CollageCandidate]
        do {
            candidates = try JSONDecoder().decode([CollageCandidate].self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(
                "The layout options file could not be read: \(error.localizedDescription)")
        }

        // Photos were already proven present, so a run that produced nothing
        // is a broken run rather than an empty day.
        guard !candidates.isEmpty else {
            throw PythonBridgeError.invalidOutput(
                "The layout run finished without producing any options.")
        }
        return candidates
    }

    /// Result of a preview-generation run. `paths` mirrors Python's per-day
    /// output dict; `errors` carries the per-day failure messages Python writes
    /// when a day couldn't be generated (e.g. missing photo, ffmpeg crash). A
    /// successful run for a given day means `paths[day]` is non-empty AND
    /// `errors[day]` is absent.
    struct PreviewGenerationResult {
        let paths: [String: [String: String]]
        let errors: [String: String]
        /// Per-day notes about a day that DID render: a chosen optional photo
        /// that has moved, say. Deliberately not `errors`: the two need
        /// opposite responses, and while they shared one field a day whose
        /// only complaint was a missing optional input read as a day with no
        /// graphics at all (#265).
        var warnings: [String: String] = [:]
        /// Friday's Stage 2 selection plan, decoded straight from
        /// generate_media.py's friday_clip_plan when a clip reel was
        /// rendered. nil when no reel was attempted this run.
        var fridayClipPlan: FridayClipPlan? = nil
        /// Thursday/Friday's cover-image pick, decoded straight from
        /// generate_media.py's cover_pick, keyed by day name. Only present
        /// for a day when a fresh pick was made this run (the sticky gate
        /// reusing a persisted pick emits no cover_pick at all).
        var coverPicks: [String: CoverPick] = [:]

        /// Every PNG this run produced, across all days. What the export path
        /// wants: it does not care which day an image belongs to, only that the
        /// file is there to copy.
        var imagePaths: [URL] {
            Self.dayOrder
                .compactMap { paths[$0] }
                .flatMap { $0.values }
                .filter { $0.hasSuffix(".png") }
                .map { URL(fileURLWithPath: $0) }
        }

        static let dayOrder = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"]
    }

    /// Parses generate_media.py's whole output: per-day assets, per-day
    /// failures, and the two nested objects.
    ///
    /// One parse for both callers. The export path used to have its own copy
    /// that read the day entries and ignored `errors` entirely, so a day that
    /// failed during a real export was silent while the same failure during a
    /// preview run was reported. An error surfaced on one path only is an error
    /// nobody sees on the path that matters (#262).
    nonisolated static func parseMediaOutput(
        _ json: [String: Any],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> PreviewGenerationResult {
        var paths: [String: [String: String]] = [:]
        var fridayClipPlan: FridayClipPlan? = nil
        var coverPicks: [String: CoverPick] = [:]

        for dayKey in PreviewGenerationResult.dayOrder {
            guard let dayDict = json[dayKey] as? [String: Any] else { continue }
            let parsed = parsePreviewDayEntry(dayDict, fileExists: fileExists)
            if !parsed.paths.isEmpty { paths[dayKey] = parsed.paths }
            if dayKey == "friday" { fridayClipPlan = parsed.fridayClipPlan }
            if let pick = parsed.coverPick { coverPicks[dayKey] = pick }
        }

        return PreviewGenerationResult(
            paths: paths,
            errors: (json["errors"] as? [String: String]) ?? [:],
            warnings: (json["warnings"] as? [String: String]) ?? [:],
            fridayClipPlan: fridayClipPlan,
            coverPicks: coverPicks)
    }

    /// Parses one day's entry from generate_media.py's output JSON. Values
    /// are a mix of plain string paths (e.g. "reel", "story") and, for
    /// Friday, a nested friday_clip_plan object (and for Thursday/Friday, a
    /// nested cover_pick object), so the whole dict can't be cast to
    /// [String: String]. That cast fails outright the moment a nested value
    /// shows up, silently dropping every path for that day, not just the
    /// nested object. `fileExists` is injectable so this is testable
    /// without touching the real filesystem.
    nonisolated static func parsePreviewDayEntry(
        _ dayDict: [String: Any],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (paths: [String: String], fridayClipPlan: FridayClipPlan?, coverPick: CoverPick?) {
        var paths: [String: String] = [:]
        for (key, value) in dayDict {
            guard key != "friday_clip_plan", key != "cover_pick",
                  let path = value as? String, fileExists(path) else { continue }
            paths[key] = path
        }

        var plan: FridayClipPlan? = nil
        if let planObject = dayDict["friday_clip_plan"],
           let data = try? JSONSerialization.data(withJSONObject: planObject) {
            plan = try? JSONDecoder().decode(FridayClipPlan.self, from: data)
        }

        var coverPick: CoverPick? = nil
        if let pickObject = dayDict["cover_pick"],
           let data = try? JSONSerialization.data(withJSONObject: pickObject) {
            coverPick = try? JSONDecoder().decode(CoverPick.self, from: data)
        }

        return (paths, plan, coverPick)
    }

    /// Generates preview graphics (Tuesday + Thursday reels included) to a
    /// stable preview directory. Run after text generation so the user can
    /// see the graphics in the caption review step.
    ///
    /// Throws when the Python process itself fails. Per-day failures are
    /// non-fatal and surfaced via `PreviewGenerationResult.errors`.
    func runPreviewGeneration(event: Event, days: [String]? = nil) async throws -> PreviewGenerationResult {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_preview_manifest_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_preview_\(UUID().uuidString).json")
        // Previews live under the data root (Application Support once migrated),
        // not the Documents project checkout, so the caption review screen can
        // reload them without a TCC prompt. Python honors --output-dir.
        let previewRoot  = AppPaths.previewDir

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let manifestData = try JSONSerialization.data(
            withJSONObject: buildMediaManifest(event: event), options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestFile)

        // Same reason as runMediaGeneration: its own file, since captions and
        // graphics run in parallel (#234).
        let progressFile = AppPaths.mediaProgressFile(forEventID: event.id)
        try? FileManager.default.createDirectory(
            at: AppPaths.progressDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: progressFile)

        var args = [
            "-m", "postroll.ai.generate_media",
            "--manifest",   manifestFile.path,
            "--output-dir", previewRoot.path,
            "--output",     outputFile.path,
            "--progress",   progressFile.path,
            // No --static-only: reels (Tuesday + Thursday) are generated so the
            // user can preview them in the caption review step before exporting.
        ]
        if let days, !days.isEmpty {
            args += ["--only-days"] + days
        }
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            return PreviewGenerationResult(paths: [:], errors: [:])
        }

        let data = try Data(contentsOf: outputFile)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PreviewGenerationResult(paths: [:], errors: [:])
        }

        return Self.parseMediaOutput(json)
    }

    /// Builds the Thursday reel's still preview PNG + layout sidecar (no ffmpeg encode).
    /// ~1-2s. Used to open the per-photo crop editor without re-rendering the full video.
    /// Returns the PNG URL on success, nil on failure (e.g. no photos).
    @discardableResult
    func runBuildReelPreview(event: Event, day: DayName = .thursday) async throws -> URL? {
        guard let pd = event.days[day.rawValue], !pd.photoPaths.isEmpty else { return nil }

        // Write the preview PNG next to the existing reel MP4 — derived from
        // previewMediaPaths so we never have to reconstruct Python's slug.
        // Caption review is only reachable after assets are generated, so the
        // reel path is guaranteed to exist at this point.
        guard let reelPathStr = event.previewMediaPaths[day.rawValue]?["reel"] else {
            return nil
        }
        let previewDir = URL(fileURLWithPath: reelPathStr).deletingLastPathComponent()
        let previewPNG = previewDir.appendingPathComponent("reel_preview.png")

        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_reel_preview_manifest_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: manifestFile)
        }

        let offsets: [[Double]] = pd.photoPaths.map { url in
            let o = pd.reelCropOffsets[url.absoluteString] ?? CropOffset()
            return [o.x, o.y, o.scale]
        }
        let manifest = Self.buildReelPreviewManifest(day: pd, cropOffsets: offsets)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestFile)

        try await runProcess(args: [
            "-m", "postroll.ai.build_reel_preview",
            "--manifest", manifestFile.path,
            "--output",   previewPNG.path,
        ])

        guard FileManager.default.fileExists(atPath: previewPNG.path) else { return nil }
        return previewPNG
    }

    /// What an audio swap actually did, as reported by swap_reel_audio.py.
    ///
    /// All three fields are read (#262). `reelPath` is the file the swap
    /// verifiably wrote, so the player reloads what exists rather than what was
    /// asked for. `tags` says what the track was matched on, and is empty for a
    /// file Dan supplied himself, because that was not matched on anything.
    struct ReelAudioSwapResult: Sendable, Equatable {
        let reelPath: String
        let audioSource: String
        let tags: String

        /// Whether there is anything to tell Dan about how this track was
        /// chosen. False for his own upload, so the app does not claim to have
        /// matched a file he picked by hand.
        var wasMatchedOnTags: Bool { !tags.isEmpty }
    }

    /// Parses swap_reel_audio.py's result. Pure, so the shapes it must refuse
    /// are testable without a subprocess.
    ///
    /// Refuses a payload missing either path rather than filling one in: the
    /// reel path is what the player reloads and the audio source is what gets
    /// recorded on the day, and a guessed value for either points the app at a
    /// file this run may never have written (L75).
    nonisolated static func parseSwapReelAudioOutput(_ json: [String: Any]) -> ReelAudioSwapResult? {
        guard let reelPath = json["reel"] as? String,
              let audioSource = json["audio_source"] as? String else { return nil }
        // Tolerated when absent: a result from an older build carries no tags,
        // and that is a swap that worked, not one that failed.
        let tags = (json["tags"] as? String) ?? ""
        return ReelAudioSwapResult(reelPath: reelPath, audioSource: audioSource, tags: tags)
    }

    /// Swap the audio track on an existing reel without re-rendering video.
    /// Uses ffmpeg stream-copy on the video + a fresh Jamendo track. ~3-5s, no API calls.
    ///
    /// Throws rather than returning nil when there is nothing to swap. The
    /// caller clears Dan's uploaded track BEFORE calling, so that it fetches
    /// fresh, and only the failure path puts it back (#118). A silent nil meant
    /// the success branch ran instead: the app announced the swap had worked,
    /// no audio had changed, and his own file was left referenced by nothing,
    /// which makes it a candidate for the next launch's orphan sweep.
    @discardableResult
    func runSwapReelAudio(event: Event, day: DayName) async throws -> ReelAudioSwapResult {
        try await swapReelAudio(event: event, day: day, audioPath: nil)
    }

    /// Like `runSwapReelAudio` but uses a user-provided audio file instead of
    /// fetching from Jamendo.
    @discardableResult
    func runSwapReelAudioWithFile(event: Event, day: DayName,
                                  audioPath: String) async throws -> ReelAudioSwapResult {
        try await swapReelAudio(event: event, day: day, audioPath: audioPath)
    }

    /// One implementation for both entry points. They differed only in a single
    /// argument, and keeping two copies meant every fix to the result handling
    /// had to be made twice or land in one of them.
    private func swapReelAudio(event: Event, day: DayName,
                               audioPath: String?) async throws -> ReelAudioSwapResult {
        guard let reelPath = event.previewMediaPaths[day.rawValue]?["reel"],
              FileManager.default.fileExists(atPath: reelPath) else {
            throw PythonBridgeError.invalidOutput(
                "There is no rendered \(day.displayName) reel to swap the audio on. "
                + "Generate the graphics for that day first.")
        }

        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_swap_manifest_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_swap_result_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let manifest = Self.buildSwapReelAudioManifest(event: event)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestFile)

        var args = [
            "-m", "postroll.ai.swap_reel_audio",
            "--reel", reelPath,
            "--manifest", manifestFile.path,
            "--output", outputFile.path,
        ]
        if let audioPath { args += ["--audio", audioPath] }
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }
        let data = try Data(contentsOf: outputFile)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = Self.parseSwapReelAudioOutput(json) else {
            throw PythonBridgeError.invalidOutput(
                "The audio swap finished but did not report what it did, so the "
                + "reel cannot be trusted to have the right track.")
        }
        return parsed
    }

    /// What a manual Friday re-render did, as reported by
    /// render_friday_override.py.
    ///
    /// `titleCardSkipped` is the reason the reel carries no title, and is nil
    /// for a reel that has one and for a reel Dan muted the title on: he made
    /// that choice here, in the app, so reporting it back would put a notice on
    /// every deliberately untitled reel (#824). It is non-nil only when the
    /// card was meant to be there and is not, which is a thing he cannot see by
    /// looking at the reel unless something says so.
    struct FridayOverrideResult: Sendable, Equatable {
        let reelPath: String
        let titleCardSkipped: String?
    }

    /// Parses render_friday_override.py's result. Pure, so the shapes it must
    /// refuse are testable without a subprocess.
    ///
    /// Refuses a payload with no reel path rather than filling one in: that
    /// path is what the player reloads, and a guessed one points the app at a
    /// file this run may never have written (L75).
    ///
    /// An empty `title_card_skipped` becomes nil, so "the title is on the reel"
    /// and "this reel has no title and here is why" cannot be confused by a
    /// caller that only checks for a value.
    nonisolated static func parseFridayOverrideOutput(_ json: [String: Any]) -> FridayOverrideResult? {
        guard let reelPath = json["reel"] as? String, !reelPath.isEmpty else { return nil }
        let skipped = (json["title_card_skipped"] as? String) ?? ""
        return FridayOverrideResult(reelPath: reelPath,
                                    titleCardSkipped: skipped.isEmpty ? nil : skipped)
    }

    /// Re-renders the Friday reel from the user's manual override
    /// (reorder/include-exclude/swap), skipping Stage 1/2 entirely. Manual
    /// edits never re-invoke Claude (feedback_collage_edits_no_python_regen).
    /// Overwrites the existing reel path in place, mirroring
    /// runSwapReelAudio, so the reel player picks up the change with no new
    /// path wiring. Returns what the render reported, nil when there's no
    /// override or no existing reel to overwrite.
    @discardableResult
    func runRenderFridayOverride(event: Event) async throws -> FridayOverrideResult? {
        guard let fri = event.days[DayName.friday.rawValue],
              let override = fri.fridayClipOverride, !override.isEmpty,
              let reelPath = event.previewMediaPaths[DayName.friday.rawValue]?["reel"] else {
            return nil
        }

        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_friday_override_manifest_\(UUID().uuidString).json")
        let resultFile = tmp.appendingPathComponent("postroll_friday_override_result_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: resultFile)
        }

        let manifest = Self.buildFridayOverrideManifest(event: event, override: override)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestFile)

        try await runProcess(args: [
            "-m", "postroll.ai.render_friday_override",
            "--manifest", manifestFile.path,
            "--output", reelPath,
            "--result", resultFile.path,
        ])

        guard FileManager.default.fileExists(atPath: reelPath) else { return nil }

        // The reel exists, so the render worked; what the result file adds is
        // what happened to the title card. A missing or unreadable one is not a
        // failed render, so the reel is still returned: it is the app that
        // cannot then say whether the title landed, and claiming it did would
        // be the wrong half to guess at.
        guard let data = try? Data(contentsOf: resultFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = Self.parseFridayOverrideOutput(json) else {
            return FridayOverrideResult(reelPath: reelPath, titleCardSkipped: nil)
        }
        return parsed
    }

    /// Builds the render_friday_override.py manifest: fridayClipOverride
    /// entries reordered by `order` and filtered to `included`, each
    /// carrying over its transition from the original AI plan (matched by
    /// clip path) since ReelClipOverride has no transition field of its
    /// own. A swap-in clip the AI never selected defaults to "cut".
    /// A pure function (no actor-isolated state), so nonisolated: callable
    /// directly, and internal (not private) so PostRollTests can pin the
    /// exact wire format render_friday_override.py expects.
    // MARK: - Manifest builders
    //
    // Every manifest is assembled in exactly one pure function (#266, #270).
    // Not a tidying exercise: the Friday manifest used to be half built by a
    // helper and half by its caller, which is how the key that keeps Dan's own
    // music came to be in neither, and a manifest with no single home has
    // nowhere its completeness can be seen or asserted. Each of these is
    // covered by `manifests` in tests/fixtures/bridge_payload_contract.json.

    /// The Thursday strip preview the per-photo crop editor opens.
    nonisolated static func buildReelPreviewManifest(day pd: PostingDay,
                                                     cropOffsets: [[Double]]) -> [String: Any] {
        var manifest: [String: Any] = [
            "photos": pd.photoPaths.map { $0.path },
        ]
        if let seed = pd.reelSeed { manifest["seed"] = seed }
        // Only when something was actually moved: an all-default set would ask
        // Python to apply crops that are not crops.
        if cropOffsets.contains(where: { $0[0] != 0 || $0[1] != 0 || $0[2] != 1.0 }) {
            manifest["crop_offsets"] = cropOffsets
        }
        return manifest
    }

    /// Replacing a rendered reel's music without re-encoding the video.
    nonisolated static func buildSwapReelAudioManifest(event: Event) -> [String: Any] {
        [
            "shoot_type": event.shootType.pythonValue,
            // What the Jamendo mood tags are derived from. Empty when the
            // programme has no works, which matches on shoot type alone.
            "pieces": (event.ocrResult?.pieces ?? []).map {
                ["title": $0.title, "composer": $0.composer]
            },
        ]
    }

    /// Rewriting one day's caption from a plain-English instruction.
    nonisolated static func buildCaptionRevisionManifest(
        event: Event, day: DayName, program: Any, existing: Any, feedback: String
    ) -> [String: Any] {
        // The same credit lists the week manifest sends for this day (#476).
        // Without them the hashtag gate judged against the programme alone, so
        // a person credited by plain name or tagged on a photo could keep a
        // hashtag on a revision that generation would have stripped, and the
        // credit checks (#475) had no tag list to judge a handle against.
        //
        // Sent even when empty, unlike the week manifest's per-day entries:
        // there, an absent key means the day itself carries nothing, while
        // here an absent key would be indistinguishable from an app version
        // that does not send them, and Python's fallback is a different rule
        // rather than an error.
        let credits = CaptionCreditInputs.forDay(event.days[day.rawValue], event: event)
        return [
            "event":         event.name,
            "org":           event.org,
            "venue":         event.venue,
            "venue_context": event.venueContext,
            "date":          event.isoDate,
            "shoot_type":    event.shootType.pythonValue,
            "day":           day.rawValue,
            "program":       program,
            "existing":      existing,
            "feedback":      feedback,
            "tag_handles":   credits.handles,
            "name_mentions": credits.names,
            "photo_tags":    credits.photoTags,
        ]
    }

    /// Rewriting the blog post from a plain-English instruction.
    nonisolated static func buildBlogRevisionManifest(
        event: Event, program: Any, existing: Any, feedback: String
    ) -> [String: Any] {
        [
            "event":         event.name,
            "org":           event.org,
            "venue":         event.venue,
            "venue_context": event.venueContext,
            "date":          event.isoDate,
            "shoot_type":    event.shootType.pythonValue,
            "program":       program,
            "existing":      existing,
            "feedback":      feedback,
            // #962: the names the blog's photos carry on disk. Without them
            // Python skips both filename rules by its own documented refusal,
            // so the one thing a revision can break that the prompt explicitly
            // forbids, renaming a [PHOTO:] marker, was the one thing this path
            // could not see. The bare NAME, not the path: a marker is compared
            // against the `Photo N:` label the model was shown.
            //
            // This is the photos AVAILABLE to the post, not the photos in it,
            // because generation subsamples to seven when more are assigned.
            // Python narrows it against the body being revised; sending the
            // narrowed set from here would mean parsing markers in two
            // languages, and the two would drift.
            "photo_filenames": event.blogPhotoPaths.map { $0.lastPathComponent },
        ]
    }

    /// Rewriting the blog around a different set of photos.
    ///
    /// `event` is optional because one caller has no event to hand. Python
    /// tolerates both absences, so this is a real conditional rather than a
    /// forgotten key, and the contract records the condition.
    nonisolated static func buildBlogPhotoSwapManifest(
        currentBody: String, photoPaths: [URL], event: Event?
    ) -> [String: Any] {
        var manifest: [String: Any] = [
            "body":        currentBody,
            "photo_paths": photoPaths.map { $0.path },
        ]
        guard let event else { return manifest }
        manifest["venue"] = event.venue
        if let ocr = event.ocrResult,
           let program = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(ocr)) {
            manifest["program"] = program
        }
        return manifest
    }

    /// Reading the Instagram export to find what performed.
    nonisolated static func buildAnalyticsManifest(
        posts: Any, orgBands: [String: String], globalHashtags: [String]
    ) -> [String: Any] {
        [
            "posts":                      posts,
            "org_bands":                  orgBands,
            "global_hashtags_to_exclude": globalHashtags,
        ]
    }

    /// Inferring a brand-voice rule from the edits Dan made to generated text.
    nonisolated static func buildLearnFromEditsManifest(
        brandVoice: String, edits: [[String: String]]
    ) -> [String: Any] {
        [
            // Always sent, even when empty: Python loads the file itself when
            // this is missing, and two copies of the voice that can disagree is
            // worse than one that is occasionally blank.
            "brand_voice": brandVoice,
            "edits":       edits,
        ]
    }

    /// The whole manifest render_friday_override.py reads, assembled in one
    /// place (#266).
    ///
    /// Half of it used to be added by the caller after the fact, which is how
    /// `audio` came to be missing: Python reads it to keep a track Dan uploaded,
    /// and nothing here sent it, so every re-render of a hand-edited Friday
    /// threw his own music away and fetched a stranger's. A key the app does not
    /// send does not fail; Python's default just quietly wins.
    nonisolated static func buildFridayOverrideManifest(
        event: Event, override: [ReelClipOverride]
    ) -> [String: Any] {
        let fri = event.days[DayName.friday.rawValue]
        var manifest = buildFridayOverrideSelections(
            override: override, originalPlan: fri?.fridayClipPlan)

        manifest["event_name"] = event.name
        manifest["shoot_type"] = event.shootType.pythonValue
        manifest["pieces"] = (event.ocrResult?.pieces ?? []).map {
            ["title": $0.title, "composer": $0.composer]
        }
        manifest["duck_gain_db"]     = fri?.fridayAudioDuckDB ?? -15.0
        manifest["mute_clip_audio"]  = fri?.fridayAudioMuted ?? false
        manifest["title_card_muted"] = fri?.titleCardMuted ?? false
        // Only when there is one: its absence is what tells Python to fetch a
        // fresh track, so sending an empty string would be a different request.
        if let audio = fri?.audioPath { manifest["audio"] = audio.path }
        return manifest
    }

    nonisolated static func buildFridayOverrideSelections(
        override: [ReelClipOverride], originalPlan: FridayClipPlan?
    ) -> [String: Any] {
        let transitionByPath = Dictionary(
            (originalPlan?.selections ?? []).map { ($0.clipPath, $0.transition.rawValue) },
            uniquingKeysWith: { first, _ in first }
        )
        let selections: [[String: Any]] = override
            .filter { $0.included }
            .sorted { $0.order < $1.order }
            .map { entry in
                [
                    "clip_path": entry.clipPath,
                    "trim_in": entry.trimIn,
                    "trim_out": entry.trimOut,
                    "transition": transitionByPath[entry.clipPath] ?? "cut",
                    "crop_x": entry.cropX,
                    "crop_y": entry.cropY,
                ]
            }
        return ["selections": selections]
    }

    /// Builds the media manifest dict shared by runMediaGeneration and runPreviewGeneration.
    /// A pure function of `event` (no actor-isolated state), so nonisolated:
    /// callable directly, and internal (not private) so PostRollTests can
    /// pin the per-day inclusion guard and field wiring directly.
    nonisolated func buildMediaManifest(event: Event) -> [String: Any] {
        var daysDict: [String: Any] = [:]
        for dayName in DayName.allCases {
            let pd = event.days[dayName.rawValue]
            guard ManifestDay.isIncluded(pd), let pd else { continue }
            // The inclusion rule and the fields both pipelines need live in
            // ManifestDay, so a new shared field reaches the caption run too
            // rather than only this one (#138).
            var entry = ManifestDay.sharedEntry(pd, day: dayName)
            switch dayName {
            case .tuesday:
                if let rec  = pd.screenRecordingPath { entry["screen_recording"]  = rec.path }
                if let raw  = pd.rawPhotoPath        { entry["raw_photo"]         = raw.path }
                if let edit = pd.editedPhotoPath     { entry["edited_photo"]      = edit.path }
                if let bw   = pd.bwPhotoPath         { entry["bw_photo"]          = bw.path }
                if let aud  = pd.audioPath           { entry["audio"]             = aud.path }
                entry["target_duration"] = pd.reelTargetDuration
            case .thursday:
                if let aud  = pd.audioPath           { entry["audio"]             = aud.path }
                entry["scroll_duration"] = pd.scrollDuration
                if let seed = pd.reelSeed            { entry["reel_seed"]         = seed }
                let offsets = pd.photoPaths.map { url -> [Double] in
                    let o = pd.reelCropOffsets[url.absoluteString] ?? CropOffset()
                    return [o.x, o.y, o.scale]
                }
                if offsets.contains(where: { $0[0] != 0 || $0[1] != 0 || $0[2] != 1.0 }) {
                    entry["crop_offsets"] = offsets
                }
            case .friday:
                if let raw  = pd.rawPhotoPath        { entry["raw_photo"]         = raw.path }
                if let edit = pd.editedPhotoPath     { entry["edited_photo"]      = edit.path }
                if let bw   = pd.bwPhotoPath         { entry["bw_photo"]          = bw.path }
                entry["clip_duck_db"] = pd.fridayAudioDuckDB
                entry["clip_audio_muted"] = pd.fridayAudioMuted
                entry["title_card_muted"] = pd.titleCardMuted
            default:
                break
            }
            // Collage-carousel days (Wednesday always; Sunday/Monday under the
            // balanced preset) carry the collage seed, per-cell crop offsets, and
            // any user-dragged frame layout so Python reproduces the live editor.
            if event.effectivePostingPreset.isCollageCarousel(dayName) {
                if let seed = pd.collageSeed { entry["collage_seed"] = seed }
                let offsets = pd.photoPaths.map { url -> [Double] in
                    let o = pd.collageCropOffsets[url.absoluteString] ?? CropOffset()
                    return [o.x, o.y, o.scale]
                }
                if offsets.contains(where: { $0[0] != 0 || $0[1] != 0 || $0[2] != 1.0 }) {
                    entry["crop_offsets"] = offsets
                }
                // Reconciled against the day's current photos: a layout left over
                // from a different photo set names files that may no longer exist,
                // and Python opens every cell path (a missing one killed the whole
                // collage). nil falls back to the automatic masonry layout.
                if let cellOverride = CollageCell.usable(pd.collageCellOverride, forPhotos: pd.photoPaths) {
                    entry["cell_layout"] = cellOverride.map { [
                        "photo_path": $0.photoPath,
                        "x": $0.x, "y": $0.y,
                        "w": $0.w, "h": $0.h,
                    ] as [String: Any] }
                }
            }
            daysDict[dayName.rawValue] = entry
        }
        // Simplified pieces list for audio tag derivation (title + composer only)
        let pieces: [[String: String]] = (event.ocrResult?.pieces ?? []).map {
            ["title": $0.title, "composer": $0.composer]
        }
        return [
            "event":      event.name,
            "org":        event.org,
            "venue":      event.venue,
            "date":       event.isoDate,
            "shoot_type": event.shootType.pythonValue,
            "pieces":     pieces,
            "days":       daysDict,
            "preset":     event.effectivePostingPreset.rawValue,
        ]
    }

    // MARK: - Caption revision

    func runCaptionRevision(
        event: Event,
        day: DayName,
        feedback: String,
        currentCaption: DayCaption
    ) async throws -> DayCaption {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_revise_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_revised_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        guard let ocr = event.ocrResult else {
            throw PythonBridgeError.invalidOutput("No OCR result. Complete the OCR step first.")
        }
        let ocrData = try JSONEncoder().encode(ocr)
        guard let programDict = try JSONSerialization.jsonObject(with: ocrData) as? [String: Any] else {
            throw PythonBridgeError.invalidOutput("Could not serialise OCR result.")
        }

        // Serialize current caption for the Python manifest
        let captionData = try JSONEncoder().encode(currentCaption)
        guard let captionDict = try JSONSerialization.jsonObject(with: captionData) as? [String: Any] else {
            throw PythonBridgeError.invalidOutput("Could not serialise current caption.")
        }

        let manifest = Self.buildCaptionRevisionManifest(
            event: event, day: day, program: programDict,
            existing: captionDict, feedback: feedback)

        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestFile)

        let args = [
            "-m", "postroll.ai.revise_caption",
            "--manifest", manifestFile.path,
            "--output",   outputFile.path,
        ]
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        do {
            var revised = try JSONDecoder().decode(DayCaption.self, from: data)
            // Preserve the original generated caption through revisions
            if revised.generatedCaption.isEmpty {
                revised.generatedCaption = currentCaption.generatedCaption.isEmpty
                    ? currentCaption.caption
                    : currentCaption.generatedCaption
            }
            return revised
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Blog revision

    func runBlogRevision(
        event: Event,
        feedback: String,
        currentBlog: BlogOutput
    ) async throws -> BlogOutput {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_revise_blog_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_revised_blog_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        guard let ocr = event.ocrResult else {
            throw PythonBridgeError.invalidOutput("No OCR result. Complete the OCR step first.")
        }
        let ocrData = try JSONEncoder().encode(ocr)
        guard let programDict = try JSONSerialization.jsonObject(with: ocrData) as? [String: Any] else {
            throw PythonBridgeError.invalidOutput("Could not serialise OCR result.")
        }

        let blogData = try JSONEncoder().encode(currentBlog)
        guard let blogDict = try JSONSerialization.jsonObject(with: blogData) as? [String: Any] else {
            throw PythonBridgeError.invalidOutput("Could not serialise current blog.")
        }

        let manifest = Self.buildBlogRevisionManifest(
            event: event, program: programDict, existing: blogDict, feedback: feedback)

        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestFile)

        let args = [
            "-m", "postroll.ai.revise_blog",
            "--manifest", manifestFile.path,
            "--output",   outputFile.path,
        ]
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        do {
            var revised = try JSONDecoder().decode(BlogOutput.self, from: data)
            if revised.generatedBody.isEmpty {
                revised.generatedBody = currentBlog.generatedBody.isEmpty
                    ? currentBlog.body
                    : currentBlog.generatedBody
            }
            return revised
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Blog photo swap

    /// Replace [PHOTO: ...] markers in the existing blog body with new markers
    /// for a different set of photos. All prose is preserved verbatim.
    /// `event` carries the program and venue so the swapped-in alt text can be
    /// held to the same naming rules and the same deterministic checks as the
    /// generate and revise paths (#201).
    func runBlogPhotoSwap(currentBody: String, photoPaths: [URL],
                          event: Event? = nil) async throws -> BlogOutput {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_swap_photos_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_swapped_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let manifest = Self.buildBlogPhotoSwapManifest(
            currentBody: currentBody, photoPaths: photoPaths, event: event)
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestFile)

        let args = [
            "-m", "postroll.ai.swap_blog_photos",
            "--manifest", manifestFile.path,
            "--output",   outputFile.path,
        ]
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        do {
            return try JSONDecoder().decode(BlogOutput.self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Cover image regeneration

    struct CoverRegenerationResult {
        let coverPath: String
        /// Present only for a fresh AI pick (regenerate mode); absent for a
        /// manual override, since there's no AI rationale for the user's
        /// own choice.
        let coverPick: CoverPick?
    }

    /// Builds the single-day manifest postroll.ai.generate_cover expects.
    /// Pure function of `event` (no actor-isolated state), so nonisolated
    /// and directly testable without a subprocess. nil when there's no day
    /// to generate for, or no existing rendered cover to regenerate (this
    /// call only ever refreshes an already-rendered cover, never produces
    /// the first one for a day).
    nonisolated static func buildCoverManifest(event: Event, day: DayName, overrideSource: URL?) -> [String: Any]? {
        guard let pd = event.days[day.rawValue] else { return nil }
        guard let coverPath = event.previewMediaPaths[day.rawValue]?["cover"] else { return nil }

        var dayInfo: [String: Any] = ["photos": pd.photoPaths.map { $0.path }]
        if day == .friday, let plan = pd.fridayClipPlan, !plan.selections.isEmpty {
            dayInfo["clips_plan"] = [
                "selections": plan.selections.map { sel -> [String: Any] in
                    [
                        "clip_path": sel.clipPath,
                        "trim_in": sel.trimIn,
                        "trim_out": sel.trimOut,
                        "transition": sel.transition.rawValue,
                    ]
                },
                "rationale": plan.rationale,
            ]
        }

        var manifest: [String: Any] = [
            "day":       day.rawValue,
            "event":     event.name,
            "org":       event.org,
            "venue":     event.venue,
            "day_info":  dayInfo,
            "output_path": coverPath,
        ]
        if let overrideSource { manifest["override_source"] = overrideSource.path }
        return manifest
    }

    /// Parses postroll.ai.generate_cover's output JSON. nil when the
    /// required "cover" path is missing (a malformed or empty response).
    nonisolated static func parseCoverRegenerationOutput(_ json: [String: Any]) -> CoverRegenerationResult? {
        guard let coverPath = json["cover"] as? String else { return nil }
        var pick: CoverPick? = nil
        if let pickObject = json["cover_pick"],
           let pickData = try? JSONSerialization.data(withJSONObject: pickObject) {
            pick = try? JSONDecoder().decode(CoverPick.self, from: pickData)
        }
        return CoverRegenerationResult(coverPath: coverPath, coverPick: pick)
    }

    /// Regenerates just cover.png for one day (#141), far cheaper than a
    /// full runPreviewGeneration for that day: no reel re-render, and for
    /// Friday specifically no clip re-cut (Stage 1/2 + ffmpeg). Routes to
    /// postroll.ai.generate_cover, which re-picks via Claude from the day's
    /// own photos (Thursday) or frames re-extracted from the already-
    /// persisted fridayClipPlan (Friday, never a fresh recut). When
    /// `overrideSource` is given instead, renders directly from it with no
    /// Claude call at all (the manual "choose a different photo/frame"
    /// escape hatch).
    func runCoverRegeneration(event: Event, day: DayName, overrideSource: URL? = nil) async throws -> CoverRegenerationResult {
        guard let manifest = Self.buildCoverManifest(event: event, day: day, overrideSource: overrideSource) else {
            throw PythonBridgeError.invalidOutput("No existing cover to regenerate for \(day.displayName).")
        }

        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_cover_manifest_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_cover_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestFile)

        try await runProcess(args: [
            "-m", "postroll.ai.generate_cover",
            "--manifest", manifestFile.path,
            "--output",   outputFile.path,
        ])

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }
        let data = try Data(contentsOf: outputFile)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = Self.parseCoverRegenerationOutput(json) else {
            throw PythonBridgeError.invalidOutput("Cover regeneration did not produce a cover path.")
        }
        return result
    }

    // MARK: - Manifest builder

    /// A pure function of `event` (no actor-isolated state), so nonisolated:
    /// callable directly, and internal (not private) so PostRollTests can
    /// pin the per-day inclusion guard and field wiring directly.
    nonisolated func buildManifest(event: Event, onlyDays: Set<String>? = nil) throws -> [String: Any] {
        // Serialize OCRResult via JSONEncoder so CodingKeys produce snake_case
        guard let ocr = event.ocrResult else {
            throw PythonBridgeError.invalidOutput("No OCR result. Complete the OCR step first.")
        }
        let ocrData = try JSONEncoder().encode(ocr)
        guard let programDict = try JSONSerialization.jsonObject(with: ocrData) as? [String: Any] else {
            throw PythonBridgeError.invalidOutput("Could not serialise OCR result.")
        }

        // Build per-day entries, optionally filtered to a subset
        let performers = ocr.performers
        var daysDict: [String: Any] = [:]
        for dayName in DayName.allCases {
            if let only = onlyDays, !only.contains(dayName.rawValue) { continue }
            let pd = event.days[dayName.rawValue]
            guard ManifestDay.isIncluded(pd), let pd else { continue }
            var dayEntry = ManifestDay.sharedEntry(pd, day: dayName)
            // Friday clip reel: the persisted Stage 2 plan (already selected/
            // ordered/trimmed by generate_media.py, decoded back into
            // fridayClipPlan) is sent along so generate_week.py can re-extract
            // representative frames for the caption call without redoing
            // Stage 1/2 selection.
            if dayName == .friday {
                if let plan = pd.fridayClipPlan, !plan.selections.isEmpty {
                    dayEntry["clips_plan"] = [
                        "selections": plan.selections.map { sel -> [String: Any] in
                            [
                                "clip_path": sel.clipPath,
                                "trim_in": sel.trimIn,
                                "trim_out": sel.trimOut,
                                "transition": sel.transition.rawValue,
                            ]
                        },
                        "rationale": plan.rationale,
                    ]
                }
            }

            // Event-wide handles (org, venue) + selected performer handles +
            // manual day handles + per-photo tags, deduped case-insensitively
            // so someone picked two ways is credited once. Derived in one place
            // because the revision manifest sends the same lists (#476).
            let credits = CaptionCreditInputs.forDay(pd, event: event)
            if !credits.handles.isEmpty { dayEntry["tag_handles"]   = credits.handles }
            if !credits.names.isEmpty   { dayEntry["name_mentions"] = credits.names }
            if !pd.notes.isEmpty        { dayEntry["notes"]         = pd.notes }
            if !credits.photoTags.isEmpty { dayEntry["photo_tags"] = credits.photoTags }
            daysDict[dayName.rawValue] = dayEntry
        }

        var manifest: [String: Any] = [
            "event":         event.name,
            "org":           event.org,
            "venue":         event.venue,
            "venue_context": event.venueContext,
            "date":          event.isoDate,
            "shoot_type":    event.shootType.pythonValue,
            "program":       programDict,
            "days":          daysDict,
            "preset":        event.effectivePostingPreset.rawValue,
        ]

        // Wednesday's collage photos (always 10 or fewer) are reused as
        // Thursday's caption context — small, curated, never blows past the
        // Claude request size limit. Always include them in the manifest so
        // they're available even when the user retries just Thursday and
        // Wednesday is otherwise filtered out of `daysDict`.
        if let wednesday = event.days[DayName.wednesday.rawValue],
           !wednesday.photoPaths.isEmpty {
            manifest["caption_context_photos"] = [
                "wednesday": wednesday.photoPaths.map { $0.path }
            ]
        }
        // Include blog photos only when not filtering, or when "blog" is in the retry set
        let includeBlog = onlyDays == nil || onlyDays?.contains("blog") == true
        if includeBlog, !event.blogPhotoPaths.isEmpty {
            manifest["blog_photos"] = event.blogPhotoPaths.map { $0.path }
        }
        if !event.eventURL.isEmpty {
            manifest["event_url"] = event.eventURL
        }
        return manifest
    }

    func fetchWebPerformers(eventURL: String) async throws -> [Performer] {
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_web_performers_\(UUID().uuidString).json")

        defer { try? FileManager.default.removeItem(at: outputFile) }

        let args = [
            "-m", "postroll.ai.enrich_program",
            "--fetch-performers", eventURL,
            "--output", outputFile.path,
        ]
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        do {
            let performers = try JSONDecoder().decode([Performer].self, from: data)
            return performers.map(coalesceDescription)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Handle Suggestions

    struct HandleSuggestion: Codable, Sendable {
        var name: String
        var handle: String?
        var profileURL: String?
        var confidence: String
        var note: String?

        /// The custom decoder below removes the memberwise one, and a test that
        /// has to hand build JSON to make a value is asserting against its own
        /// idea of the payload rather than against the type (#707).
        init(name: String, handle: String?, profileURL: String? = nil,
             confidence: String = "high", note: String? = nil) {
            self.name = name
            self.handle = handle
            self.profileURL = profileURL
            self.confidence = confidence
            self.note = note
        }

        enum CodingKeys: String, CodingKey {
            case name, handle, confidence, note
            case profileURL = "profile_url"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name       = (try? c.decode(String.self, forKey: .name)) ?? ""
            handle     = try? c.decode(String.self, forKey: .handle)
            profileURL = try? c.decode(String.self, forKey: .profileURL)
            confidence = (try? c.decode(String.self, forKey: .confidence)) ?? "low"
            note       = try? c.decode(String.self, forKey: .note)
        }
    }

    func suggestHandles(performers: [Performer], org: String, venue: String, event: String) async throws -> [HandleSuggestion] {
        let inputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_suggest_input_\(UUID().uuidString).json")
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_suggest_output_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: inputFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        // Build the input JSON
        let performerDicts: [[String: String]] = performers.map {
            ["name": $0.name, "role": $0.role, "voice_or_instrument": $0.voiceOrInstrument]
        }
        let inputDict: [String: Any] = [
            "performers": performerDicts,
            "org": org,
            "venue": venue,
            "event": event,
        ]
        let inputData = try JSONSerialization.data(withJSONObject: inputDict)
        try inputData.write(to: inputFile)

        let args = [
            "-m", "postroll.ai.enrich_program",
            "--suggest-handles", inputFile.path,
            "--output", outputFile.path,
        ]

        do {
            try await runProcess(args: args)
        } catch {
            // runProcess stderr is empty (redirected to log file) — provide a useful message
            throw PythonBridgeError.invalidOutput(
                "Handle lookup failed. The web search may have timed out. Try again with fewer performers, or check \(AppPaths.logsDirDisplayPath)."
            )
        }

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.invalidOutput(
                "Handle lookup produced no output. Check \(AppPaths.logsDirDisplayPath) for details."
            )
        }

        let data = try Data(contentsOf: outputFile)
        do {
            return try JSONDecoder().decode([HandleSuggestion].self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Piece Notes (web)

    /// One result from fetch-piece-notes — title/composer echo the input so we
    /// can match by content in case the Claude call returns them out of order.
    struct PieceNoteResult: Codable, Sendable {
        var title: String
        var composer: String
        var notes: String?

        /// The custom decoder below removes the memberwise one, and a test that
        /// has to hand build JSON to make a value is a test asserting against
        /// its own idea of the payload rather than against the type (#693).
        init(title: String, composer: String, notes: String?) {
            self.title = title
            self.composer = composer
            self.notes = notes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title    = (try? c.decode(String.self, forKey: .title))    ?? ""
            composer = (try? c.decode(String.self, forKey: .composer)) ?? ""
            notes    = try? c.decode(String.self, forKey: .notes)
        }

        enum CodingKeys: String, CodingKey { case title, composer, notes }
    }

    /// Fetch short web-sourced program notes for the given pieces.
    /// Caller filters to pieces with empty notes — this method sends whatever
    /// it's given.
    func fetchPieceNotes(pieces: [Piece], org: String, event: String) async throws -> [PieceNoteResult] {
        let inputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_piece_notes_in_\(UUID().uuidString).json")
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_piece_notes_out_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: inputFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let pieceDicts: [[String: String]] = pieces.map {
            ["title": $0.title, "composer": $0.composer]
        }
        let inputDict: [String: Any] = [
            "pieces": pieceDicts,
            "org": org,
            "event": event,
        ]
        let inputData = try JSONSerialization.data(withJSONObject: inputDict)
        try inputData.write(to: inputFile)

        let args = [
            "-m", "postroll.ai.enrich_program",
            "--fetch-piece-notes", inputFile.path,
            "--output", outputFile.path,
        ]
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        do {
            return try JSONDecoder().decode([PieceNoteResult].self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Flag Issues

    /// Run postroll.ai.flag_issues against the OCR result + program images.
    /// Returns the flags Claude raised — empty array means OCR looked clean.
    /// - Parameter visionText: the text layer Apple Vision baked into the program
    ///   PDF at upload time, when it is available and current. Passing it turns on
    ///   the spelling cross-check in `flag_issues` (#209): every performer name and
    ///   handle the program's own text cannot confirm comes back as a flag. Passing
    ///   nil runs the model review alone, and the caller is responsible for telling
    ///   Dan the check did not run, because a silently skipped cross-check looks
    ///   exactly like a program with nothing wrong in it.
    func runFlagIssues(
        ocr: OCRResult,
        imagePaths: [URL],
        visionText: String? = nil
    ) async throws -> [OCRFlag] {
        guard !imagePaths.isEmpty else { return [] }

        let programFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_flag_program_\(UUID().uuidString).json")
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_flag_out_\(UUID().uuidString).json")
        let visionFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_flag_vision_\(UUID().uuidString).txt")

        defer {
            try? FileManager.default.removeItem(at: programFile)
            try? FileManager.default.removeItem(at: outputFile)
            try? FileManager.default.removeItem(at: visionFile)
        }

        let programData = try JSONEncoder().encode(ocr)
        try programData.write(to: programFile)

        var args = ["-m", "postroll.ai.flag_issues", "--program", programFile.path]
        for url in imagePaths {
            args.append("--image")
            args.append(url.path)
        }
        if let visionText {
            try visionText.write(to: visionFile, atomically: true, encoding: .utf8)
            args.append("--vision-text")
            args.append(visionFile.path)
        }
        args.append("--output")
        args.append(outputFile.path)

        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        do {
            return try JSONDecoder().decode([OCRFlag].self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Flag review (natural-language reflow)

    /// Result of asking Claude to reflow one flag given the user's plain-English correction.
    struct FlagReviewResponse: Decodable, Sendable {
        let assistantReply: String
        let patch: [PatchOp]?
        let resolved: Bool

        enum CodingKeys: String, CodingKey {
            case assistantReply = "assistant_reply"
            case patch, resolved
        }
    }

    /// One patch operation produced by review_flag.py. Stored as a JSON-passthrough
    /// dict so we can hand it straight back to Python to apply (the apply path is
    /// already implemented there). We don't introspect the patch on the Swift side
    /// beyond showing the assistant_reply summary.
    struct PatchOp: Codable, Sendable {
        let raw: [String: JSONValue]

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            raw = try c.decode([String: JSONValue].self)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(raw)
        }
    }

    /// One-shot natural-language correction for a single flag. Calls
    /// `python -m postroll.ai.review_flag` with the current OCR data + flag +
    /// program images + the user's free-text feedback. Returns the model's
    /// reply, optional patch (already validated server-side), and resolved flag.
    /// Empty conversation — multi-turn isn't wired yet.
    func reviewFlag(
        flag: OCRFlag,
        ocr: OCRResult,
        imagePaths: [URL],
        userMessage: String
    ) async throws -> FlagReviewResponse {
        guard !imagePaths.isEmpty else {
            throw PythonBridgeError.invalidOutput("No program images available; can't run flag reflow.")
        }
        let tmp = FileManager.default.temporaryDirectory
        let programFile = tmp.appendingPathComponent("postroll_review_program_\(UUID().uuidString).json")
        let flagFile    = tmp.appendingPathComponent("postroll_review_flag_\(UUID().uuidString).json")
        let outputFile  = tmp.appendingPathComponent("postroll_review_out_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: programFile)
            try? FileManager.default.removeItem(at: flagFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let encoder = JSONEncoder()
        try encoder.encode(ocr).write(to: programFile)
        try encoder.encode(flag).write(to: flagFile)

        var args = [
            "-m", "postroll.ai.review_flag",
            "--program", programFile.path,
            "--flag",    flagFile.path,
            "--message", userMessage,
            "--output",  outputFile.path,
        ]
        for url in imagePaths {
            args.append("--image")
            args.append(url.path)
        }

        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }
        let data = try Data(contentsOf: outputFile)
        do {
            return try JSONDecoder().decode(FlagReviewResponse.self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    /// Apply a patch (as returned by reviewFlag) to OCR data by shelling out
    /// to `python -m postroll.ai.review_flag --apply-to`. The Python side has
    /// the canonical patch-application logic; rather than reimplement it in
    /// Swift, we round-trip through the same module.
    func applyFlagPatch(
        patch: [PatchOp],
        flag: OCRFlag,
        ocr: OCRResult,
        imagePaths: [URL]
    ) async throws -> OCRResult {
        // Apply the patch locally using a tiny inline Python helper —
        // we already have review_flag.apply_patch, but we don't want to
        // re-run Claude. Shell out to a small adhoc script via -c.
        let tmp = FileManager.default.temporaryDirectory
        let programFile = tmp.appendingPathComponent("postroll_apply_in_\(UUID().uuidString).json")
        let patchFile   = tmp.appendingPathComponent("postroll_apply_patch_\(UUID().uuidString).json")
        let outputFile  = tmp.appendingPathComponent("postroll_apply_out_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: programFile)
            try? FileManager.default.removeItem(at: patchFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let encoder = JSONEncoder()
        try encoder.encode(ocr).write(to: programFile)
        try encoder.encode(patch).write(to: patchFile)

        let script = """
            import json, sys
            from pathlib import Path
            from postroll.ai.review_flag import apply_patch
            ocr = json.loads(Path(sys.argv[1]).read_text())
            ops = json.loads(Path(sys.argv[2]).read_text())
            out = apply_patch(ocr, ops)
            Path(sys.argv[3]).write_text(json.dumps(out, ensure_ascii=False))
            """
        try await runProcess(args: ["-c", script, programFile.path, patchFile.path, outputFile.path])

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }
        let data = try Data(contentsOf: outputFile)
        do {
            return try JSONDecoder().decode(OCRResult.self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    /// What a failed OCR run left behind, when it left something usable (#479).
    ///
    /// Python writes the merged result after every batch, so a run stopped
    /// partway (an exception, or the watchdog's SIGTERM at 1800s) leaves the
    /// pages it had already read and paid for on disk. Without this read, that
    /// write protects nothing: the run reports as failed and the retry pays for
    /// those pages again.
    ///
    /// An EMPTY file is not a partial read. Nothing was recovered, so offering
    /// it would present a programme with nothing in it as a programme that had
    /// nothing in it. A file that does not parse is not one either.
    nonisolated static func salvagedOCR(at url: URL) -> OCRResult? {
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(OCRResult.self, from: data)
        else { return nil }

        let hasContent = !result.performers.isEmpty
            || !result.pieces.isEmpty
            || !result.scenes.isEmpty
            || ![result.organizationNotes, result.programNotes, result.venueNotes,
                 result.productionDetails, result.other]
                .allSatisfy(\.isEmpty)
        return hasContent ? result : nil
    }

    /// `mergeInto` turns this into a rescan of the pages an earlier run could
    /// not read: Python folds what comes back into the result passed here,
    /// rather than replacing it (#518). The merge itself is Python's, beside
    /// the one that already combines the batches of a single run, so this side
    /// keeps no second copy of that rule.
    /// `pageNumbers`, when given, says where each image sits in the whole
    /// uploaded programme, one per image (#558). A rescan is handed a subset,
    /// so without it Python would number page 7 as page 1 and the merge would
    /// strike the wrong page off the gap. Nil for a full scan.
    func runOCR(imagePaths: [URL], pageNumbers: [Int]? = nil, eventID: UUID? = nil,
                mergeInto previous: OCRResult? = nil) async throws -> OCRResult {
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_ocr_\(UUID().uuidString).json")

        defer { try? FileManager.default.removeItem(at: outputFile) }

        var args = ["-m", "postroll.ai.ocr_program", "--output", outputFile.path]

        var mergeFile: URL? = nil
        if let previous {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("postroll_ocr_prev_\(UUID().uuidString).json")
            // Written before the run and NOT with `try?`: if the stored result
            // cannot be handed over, the rescan must not go ahead as an
            // ordinary scan, because that would replace a programme that was
            // read and paid for with the two pages this run happens to read
            // (L105).
            try JSONEncoder().encode(previous).write(to: file, options: .atomic)
            mergeFile = file
            args += ["--merge-into", file.path]
        }
        defer { if let mergeFile { try? FileManager.default.removeItem(at: mergeFile) } }
        // Cleared before the run, so the screen cannot read the previous
        // attempt's last step and call this one alive (#467).
        if let eventID {
            let progressFile = AppPaths.ocrProgressFile(forEventID: eventID)
            try? FileManager.default.removeItem(at: progressFile)
            args += ["--progress", progressFile.path]
        }
        for path in imagePaths { args += ["--image", path.path] }
        // Refused here rather than sent short: Python takes one number per
        // image and a mismatched pair would record one page's gap against
        // another page's position, which every later rescan then acts on.
        if let pageNumbers {
            guard pageNumbers.count == imagePaths.count else {
                throw PythonBridgeError.invalidOutput(
                    "\(pageNumbers.count) page numbers for \(imagePaths.count) "
                    + "pages, so the rescan cannot say which page is which")
            }
            for number in pageNumbers { args += ["--page-number", String(number)] }
        }

        do {
            try await runProcess(args: args)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A stopped run may still have read most of a long programme.
            if let salvaged = Self.salvagedOCR(at: outputFile) {
                throw PythonBridgeError.partialOCR(
                    salvaged, reason: error.localizedDescription)
            }
            throw error
        }

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        do {
            var result = try JSONDecoder().decode(OCRResult.self, from: data)
            result.performers = result.performers.map(coalesceDescription)
            return result
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    /// When voiceOrInstrument is blank but role has a value (e.g. "conductor"),
    /// copy role into voiceOrInstrument so the Description field in the UI isn't empty.
    private func coalesceDescription(_ p: Performer) -> Performer {
        guard p.voiceOrInstrument.isEmpty, !p.role.isEmpty else { return p }
        var p = p
        p.voiceOrInstrument = p.role
        return p
    }

    // MARK: - Instagram analytics import

    func importMetaCSV(paths: [URL]) async throws -> MetaImportResult {
        let tmp = FileManager.default.temporaryDirectory
        let outputFile = tmp.appendingPathComponent("postroll_meta_import_\(UUID().uuidString).json")

        defer { try? FileManager.default.removeItem(at: outputFile) }

        var args = ["-m", "postroll.ai.import_meta_csv", "--output", outputFile.path]
        for path in paths { args += ["--csv", path.path] }

        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = AnalyticsDates.lenientDecoding
        do {
            return try decoder.decode(MetaImportResult.self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Instagram analytics generation

    func runAnalytics(
        posts: [IGPost],
        orgBands: [String: OrgFollowerBand],
        globalHashtags: [String]
    ) async throws -> InsightReport {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_analytics_manifest_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_analytics_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // Encode posts as JSON value, embed in manifest dict
        let postsData = try encoder.encode(posts)
        guard let postsJSON = try JSONSerialization.jsonObject(with: postsData) as? [[String: Any]] else {
            throw PythonBridgeError.invalidOutput("Could not serialise posts.")
        }

        // Encode org bands as [String: String]
        let orgBandsDict = Dictionary(uniqueKeysWithValues: orgBands.map { ($0.key, $0.value.rawValue) })

        let manifest = Self.buildAnalyticsManifest(
            posts: postsJSON, orgBands: orgBandsDict, globalHashtags: globalHashtags)

        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestFile)

        let args = [
            "-m", "postroll.ai.analyze_posts",
            "--manifest", manifestFile.path,
            "--output",   outputFile.path,
        ]
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = AnalyticsDates.lenientDecoding
        do {
            return try decoder.decode(InsightReport.self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Learn from edits

    /// Analyzes edited captions against what was generated and returns a brand voice suggestion.
    /// Returns nil if no meaningful new pattern was found or if Claude can't run.
    func runLearnFromEdits(result: WeekGenerationResult) async throws -> String? {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_learn_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_suggestion_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        // Build edits array from days where caption was changed after generation
        var edits: [[String: String]] = []
        for day in DayName.allCases {
            guard let cap = result[day], cap.wasEdited else { continue }
            edits.append([
                "day":               day.rawValue,
                "original_caption":  cap.generatedCaption,
                "approved_caption":  cap.caption,
            ])
        }
        guard !edits.isEmpty else { return nil }

        // Read brand voice from the writable data-root copy (seeded from the
        // checkout default on first use), not the TCC-protected Documents file.
        AppPaths.ensureBrandVoiceSeeded()
        let brandVoice = (try? String(contentsOf: AppPaths.brandVoiceFile, encoding: .utf8)) ?? ""

        let manifest = Self.buildLearnFromEditsManifest(brandVoice: brandVoice, edits: edits)
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted]
        )
        try manifestData.write(to: manifestFile)

        let args = [
            "-m", "postroll.ai.learn_from_edits",
            "--manifest", manifestFile.path,
            "--output",   outputFile.path,
        ]
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else { return nil }

        let data = try Data(contentsOf: outputFile)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self.parseLearnSuggestion(json)
    }

    /// The brand-voice rule learn_from_edits inferred, or nil when it produced
    /// none. A pure seam so the payload's one key is provably read (#262).
    nonisolated static func parseLearnSuggestion(_ json: [String: Any]) -> String? {
        guard let suggestion = (json["suggestion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !suggestion.isEmpty
        else { return nil }
        return suggestion
    }

    // MARK: - Brand voice

    /// Appends a user feedback note to brand-voice.md under a "## Caption revision notes" section.
    nonisolated func appendBrandVoiceNote(_ note: String) throws {
        AppPaths.ensureBrandVoiceSeeded()
        let file = AppPaths.brandVoiceFile
        var content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""

        let sectionHeader = "\n\n## Caption revision notes\n"
        if !content.contains("## Caption revision notes") {
            content += sectionHeader
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = formatter.string(from: Date())
        content += "\n- (\(date)) \(note)"

        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Appends an insight-derived suggestion to brand-voice.md under "## Insights-derived patterns".
    nonisolated func appendInsightNote(_ note: String) throws {
        AppPaths.ensureBrandVoiceSeeded()
        let file = AppPaths.brandVoiceFile
        var content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""

        let sectionHeader = "\n\n## Insights-derived patterns\n"
        if !content.contains("## Insights-derived patterns") {
            content += sectionHeader
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = formatter.string(from: Date())
        content += "\n- (\(date)) \(note)"

        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    /// How the Anthropic API key reaches the Python subprocess.
    ///
    /// The value goes in the process ENVIRONMENT and only the carrier variable's
    /// name appears in the script. The script is handed to zsh as a process
    /// argument, and argv is readable by any process running as the same user
    /// and is captured in sysdiagnose bundles and screen recordings, so a key
    /// embedded there was exposed on every generation, OCR and analytics call
    /// despite being stored in the Keychain (#81).
    ///
    /// The promotion happens in the script rather than by setting
    /// ANTHROPIC_API_KEY directly, because `zsh -l` sources the user's profile
    /// after launch and a profile export would otherwise win over the key the
    /// user entered in the app.
    ///
    /// Returns nothing at all when there is no stored key, so the profile's own
    /// export stands rather than being overwritten with an empty value.
    /// Tell Python where the app's data lives.
    ///
    /// `AppPaths.resolveRoot` chooses between Documents and Application Support
    /// on a migration marker; nothing in the Python package can reproduce that,
    /// so a Python-side guess would write the AI usage log (#207) to a folder
    /// the app never reads. The path is single-quoted for the shell script, and
    /// any apostrophe in it is escaped, because a home folder can contain one.
    static func dataDirExport(_ root: URL) -> String {
        "export POSTROLL_DATA_DIR=\(shellQuoted(root.path))"
    }

    /// A value the launch script can carry without the shell reading any of it.
    ///
    /// One implementation, because the same escaping is applied to a path, an
    /// argument and a branch name, and a second copy is one that can be got
    /// wrong on its own. Single quotes stop every expansion the shell would
    /// otherwise perform, and an apostrophe inside is closed, escaped and
    /// reopened, because a home folder and a branch name can both contain one.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// The line a run opens its log with (#661).
    ///
    /// The revision belongs here because the app runs the Python from the
    /// working tree: without it, a surprising output is diagnosed against
    /// whatever is checked out when somebody looks, which is not necessarily
    /// what ran.
    static func runHeader(marker: String, revision: CheckoutRevision.Reading) -> String {
        "Running [\(marker)] (\(CheckoutRevision.describe(revision))):"
    }

    static func apiKeyDelivery(_ key: String?) -> (environment: [String: String], scriptLines: String) {
        let carrier = "POSTROLL_ANTHROPIC_API_KEY"
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ([:], "")
        }
        let lines = """
            export ANTHROPIC_API_KEY="$\(carrier)"
            unset \(carrier)
            """
        return ([carrier: key], lines)
    }

    // MARK: - Private

    /// Runs the Python command via `zsh -l` so the user's login shell profile
    /// (and therefore ANTHROPIC_API_KEY etc.) are available even when the app
    /// is launched from Finder rather than a terminal.
    ///
    /// Supports Swift task cancellation: when the calling task is cancelled,
    /// the subprocess is terminated immediately via SIGTERM.
    /// How long any one Python run may take before it is killed.
    ///
    /// Named rather than left as a literal on the parameter below because
    /// anything that waits on a run has to sit OUTSIDE it: a caller's own
    /// deadline equal to this one races it, and whichever fires first decides
    /// what Dan is told. Spelling the number twice is how the two drift (L41).
    static let processTimeout: TimeInterval = 1800

    private func runProcess(args: [String], timeout: TimeInterval = processTimeout,
                            forcePaidPath: Bool = false) async throws {
        // Refuse here rather than let the script's `cd` fail and be read as a
        // missing photo (#648). Nothing has been launched or paid for yet.
        let root = try Self.preflight(projectRoot: projectRoot)
        // Derived from the root this run was cleared to use, so the interpreter
        // and the working directory can never come from different checkouts.
        let python = Self.interpreter(in: root)
        // Logs go under the data root (Application Support), NOT the Documents
        // checkout: an absolute log path lets the subprocess write there while
        // its cwd stays at the checkout, so generation no longer writes to the
        // TCC-protected Documents folder. cwd below stays at `root`.
        let logURL = AppPaths.logFile

        // Ensure logs directory exists
        let logsDir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Point Python at the writable brand voice copy in the data root (seeded
        // here so it exists before the subprocess reads it), keeping generation
        // off the TCC-protected Documents file.
        AppPaths.ensureBrandVoiceSeeded()
        let brandVoiceExport =
            "export POSTROLL_BRAND_VOICE=\(Self.shellQuoted(AppPaths.brandVoiceFile.path))"

        // Which code this run is about to execute (#661). Read off the checkout
        // it was cleared to use, on a detached task so a git that never answers
        // cannot hold the actor other runs are waiting on.
        let revision = await Task.detached(priority: .userInitiated) {
            CheckoutRevision.read(inRepo: root)
        }.value

        // Python cannot reproduce AppPaths' marker-gated choice between
        // Documents and Application Support, so the app tells it. The AI usage
        // log (#207) is written here.
        let dataDirExport = Self.dataDirExport(AppPaths.root)

        let quotedArgs = ([python] + args).map(Self.shellQuoted).joined(separator: " ")
        // This run's own stderr file. The shared log is truncated by whichever
        // run starts next, and that truncation swaps the inode under any run
        // already appending, so a shared file could lose this run's output
        // entirely and hand back somebody else's (#90).
        let runMarker = UUID().uuidString
        let runLogURL = PythonBridgeLog.runLogURL(in: logsDir, marker: runMarker)
        let runLogPath = Self.shellQuoted(runLogURL.path)
        // Quoted, not interpolated: the header carries a branch name, which is
        // whatever somebody typed, and the shell would otherwise expand it.
        let header = Self.shellQuoted(Self.runHeader(marker: runMarker, revision: revision))
        // Rotation moves here, out of the launch script, so it happens once
        // under a lock instead of racing every concurrent run.
        PythonBridgeLog.rotate(logURL)
        // `exec` replaces the shell with the Python process so that terminating
        // this Process object directly kills the Python subprocess, not just the
        // shell wrapper.
        let apiKey = Self.apiKeyDelivery(KeychainStore.readAPIKey())

        let script = """
            export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            [ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"
            \(apiKey.scriptLines)
            \(Transport.overrideExport(forcePaidPath: forcePaidPath))
            \(brandVoiceExport)
            \(dataDirExport)
            cd '\(root.path)'
            echo "[$(date '+%Y-%m-%d %H:%M:%S')]" \(header) \(quotedArgs) >> \(runLogPath)
            exec \(quotedArgs) 2>> \(runLogPath)
            """

        // The subprocess plumbing lives in ProcessRunner so its timeout,
        // cancellation and empty-stderr paths are covered by tests against real
        // executables rather than only by hand (#86).
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-l", "-c", script],
            environment: apiKey.environment.isEmpty
                ? nil
                : ProcessInfo.processInfo.environment.merging(apiKey.environment) { _, new in new },
            timeout: timeout,
            processOutput: {
                // Python's stderr is redirected into this run's own file by the
                // script above, so the pipe only ever carries pre-exec shell
                // output. Reading that private file means no other run can have
                // truncated it and none of its lines can belong to another
                // operation, which is what let a UUID containing "413" in an
                // unrelated entry misreport a 401 as "photos too large".
                PythonBridgeLog.runOutput(runLog: runLogURL, sharedLog: logURL,
                                          marker: runMarker)
            })
        // Fold into the shared log whatever happened, so the history a human
        // reads still has every run in it, and no per-run file is left behind.
        defer { PythonBridgeLog.foldIntoShared(runLog: runLogURL, sharedLog: logURL) }
        try await runner.run()
    }
}
