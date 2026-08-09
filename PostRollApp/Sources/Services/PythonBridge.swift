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

    nonisolated static func isRealHandle(_ handle: String) -> Bool {
        var h = handle.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("@") { h = String(h.dropFirst()) }
        return !h.isEmpty && !handleSentinels.contains(h)
    }

    // nonisolated lets these be read from Task.detached without hopping back to the actor
    nonisolated let projectRoot: URL
    nonisolated let python3: String

    private init() {
        // The Python code (venv, source, preview output) lives in the project
        // checkout, separate from the user data root (AppPaths.root).
        let root = AppPaths.projectRoot
        projectRoot = root

        // Prefer the project venv so all pip packages are available
        let venvPython = root.appendingPathComponent("venv/bin/python3").path
        if FileManager.default.fileExists(atPath: venvPython) {
            python3 = venvPython
        } else {
            let candidates = [
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "/usr/bin/python3",
            ]
            python3 = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "python3"
        }
    }

    // MARK: - Public API

    // MARK: - Week generation

    /// Run week generation. Pass `onlyDays` to regenerate a subset of days/blog
    /// without touching days that already succeeded.
    func runWeekGeneration(event: Event, onlyDays: Set<String>? = nil) async throws -> WeekGenerationResult {
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

        // Run Python
        let args = [
            "-m", "postroll.ai.generate_week",
            "--manifest", manifestFile.path,
            "--output",   outputFile.path,
            "--timing",   timingFile.path,
        ]
        try await runProcess(args: args)

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
               let timing = try? JSONDecoder().decode([String: Double?].self, from: timingData) {
                TimingStore.shared.recordGenerationPhases(
                    captions:  timing["captions"]  ?? nil,
                    blog:      timing["blog"]      ?? nil,
                    packaging: timing["packaging"] ?? nil
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
    /// Returns URLs of all static images (PNG) that were successfully written.
    func runMediaGeneration(event: Event, outputDir: URL, days: [String]? = nil) async throws -> [URL] {
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

        var args = [
            "-m", "postroll.ai.generate_media",
            "--manifest",   manifestFile.path,
            "--output-dir", outputDir.path,
            "--output",     outputFile.path,
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
            return []
        }
        var imagePaths: [URL] = []
        for dayKey in ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"] {
            guard let dayDict = json[dayKey] as? [String: Any] else { continue }
            for (_, assetPath) in dayDict {
                guard let pathStr = assetPath as? String,
                      pathStr.hasSuffix(".png"),
                      FileManager.default.fileExists(atPath: pathStr) else { continue }
                imagePaths.append(URL(fileURLWithPath: pathStr))
            }
        }
        return imagePaths
    }

    /// Render `count` candidate collage layouts for `day` (each a distinct seed)
    /// into a temp directory, for the in-app layout gallery. The caller stores
    /// the chosen candidate's `seed` as the day's collageSeed so the final
    /// render reproduces it. Returns the candidates (empty on failure).
    func renderCollageCandidates(event: Event, day: DayName, count: Int = 6) async throws -> [CollageCandidate] {
        guard let pd = event.days[day.rawValue], !pd.photoPaths.isEmpty else { return [] }
        let photoCount = event.effectivePostingPreset.format(for: day)?.count ?? pd.photoPaths.count
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

        let logo = projectRoot.appendingPathComponent("postroll/assets/logo-black.png").path
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
        if FileManager.default.fileExists(atPath: logo) {
            args += ["--logo", logo]
        }
        // Pass the day's saved per-photo crop offsets so the gallery thumbnails
        // match the final collage (#62). Only when at least one is non-default.
        let offsets = Array(pd.photoPaths.prefix(photoCount)).map { url -> [Double] in
            let o = pd.collageCropOffsets[url.absoluteString] ?? CropOffset()
            return [o.x, o.y, o.scale]
        }
        if offsets.contains(where: { $0[0] != 0 || $0[1] != 0 || $0[2] != 1.0 }),
           let cropData = try? JSONSerialization.data(withJSONObject: offsets) {
            try? cropData.write(to: cropFile)
            args += ["--crop-offsets-json", cropFile.path]
        }
        try await runProcess(args: args)

        guard let data = try? Data(contentsOf: jsonFile),
              let candidates = try? JSONDecoder().decode([CollageCandidate].self, from: data)
        else { return [] }
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
        /// Friday's Stage 2 selection plan, decoded straight from
        /// generate_media.py's friday_clip_plan when a clip reel was
        /// rendered. nil when no reel was attempted this run.
        var fridayClipPlan: FridayClipPlan? = nil
        /// Thursday/Friday's cover-image pick, decoded straight from
        /// generate_media.py's cover_pick, keyed by day name. Only present
        /// for a day when a fresh pick was made this run (the sticky gate
        /// reusing a persisted pick emits no cover_pick at all).
        var coverPicks: [String: CoverPick] = [:]
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

        var args = [
            "-m", "postroll.ai.generate_media",
            "--manifest",   manifestFile.path,
            "--output-dir", previewRoot.path,
            "--output",     outputFile.path,
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

        var paths: [String: [String: String]] = [:]
        var fridayClipPlan: FridayClipPlan? = nil
        var coverPicks: [String: CoverPick] = [:]
        for dayKey in ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"] {
            guard let dayDict = json[dayKey] as? [String: Any] else { continue }
            let parsed = Self.parsePreviewDayEntry(dayDict)
            if !parsed.paths.isEmpty { paths[dayKey] = parsed.paths }
            if dayKey == "friday" { fridayClipPlan = parsed.fridayClipPlan }
            if let pick = parsed.coverPick { coverPicks[dayKey] = pick }
        }
        let errors = (json["errors"] as? [String: String]) ?? [:]
        return PreviewGenerationResult(paths: paths, errors: errors, fridayClipPlan: fridayClipPlan, coverPicks: coverPicks)
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
        let resultFile   = tmp.appendingPathComponent("postroll_reel_preview_result_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: resultFile)
        }

        let offsets: [[Double]] = pd.photoPaths.map { url in
            let o = pd.reelCropOffsets[url.absoluteString] ?? CropOffset()
            return [o.x, o.y, o.scale]
        }
        print("[PostRoll:runBuildReelPreview] photoPaths (\(pd.photoPaths.count)):")
        for (i, url) in pd.photoPaths.enumerated() {
            print("  [\(i)] \(url.lastPathComponent)")
        }
        var manifest: [String: Any] = [
            "photos": pd.photoPaths.map { $0.path },
        ]
        if let seed = pd.reelSeed { manifest["seed"] = seed }
        if offsets.contains(where: { $0[0] != 0 || $0[1] != 0 || $0[2] != 1.0 }) {
            manifest["crop_offsets"] = offsets
        }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestFile)

        try await runProcess(args: [
            "-m", "postroll.ai.build_reel_preview",
            "--manifest", manifestFile.path,
            "--output",   previewPNG.path,
            "--result",   resultFile.path,
        ])

        guard FileManager.default.fileExists(atPath: previewPNG.path) else { return nil }
        return previewPNG
    }

    /// Swap the audio track on an existing reel without re-rendering video.
    /// Uses ffmpeg stream-copy on the video + a fresh Jamendo track. ~3-5s, no API calls.
    /// Returns the new audio source path on success, nil on failure.
    @discardableResult
    func runSwapReelAudio(event: Event, day: DayName) async throws -> String? {
        guard let reelPath = event.previewMediaPaths[day.rawValue]?["reel"],
              FileManager.default.fileExists(atPath: reelPath) else {
            return nil
        }

        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_swap_manifest_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_swap_result_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let pieces: [[String: String]] = (event.ocrResult?.pieces ?? []).map {
            ["title": $0.title, "composer": $0.composer]
        }
        let manifest: [String: Any] = [
            "shoot_type": event.shootType.pythonValue,
            "pieces": pieces,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestFile)

        try await runProcess(args: [
            "-m", "postroll.ai.swap_reel_audio",
            "--reel", reelPath,
            "--manifest", manifestFile.path,
            "--output", outputFile.path,
        ])

        guard FileManager.default.fileExists(atPath: outputFile.path) else { return nil }
        let data = try Data(contentsOf: outputFile)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["audio_source"] as? String
    }

    /// Like `runSwapReelAudio` but uses a user-provided audio file instead of
    /// fetching from Jamendo.
    func runSwapReelAudioWithFile(event: Event, day: DayName, audioPath: String) async throws -> String? {
        guard let reelPath = event.previewMediaPaths[day.rawValue]?["reel"],
              FileManager.default.fileExists(atPath: reelPath) else {
            return nil
        }

        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_swap_manifest_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_swap_result_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let pieces: [[String: String]] = (event.ocrResult?.pieces ?? []).map {
            ["title": $0.title, "composer": $0.composer]
        }
        let manifest: [String: Any] = [
            "shoot_type": event.shootType.pythonValue,
            "pieces": pieces,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestFile)

        try await runProcess(args: [
            "-m", "postroll.ai.swap_reel_audio",
            "--reel", reelPath,
            "--manifest", manifestFile.path,
            "--output", outputFile.path,
            "--audio", audioPath,
        ])

        guard FileManager.default.fileExists(atPath: outputFile.path) else { return nil }
        let data = try Data(contentsOf: outputFile)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["audio_source"] as? String
    }

    /// Re-renders the Friday reel from the user's manual override
    /// (reorder/include-exclude/swap), skipping Stage 1/2 entirely. Manual
    /// edits never re-invoke Claude (feedback_collage_edits_no_python_regen).
    /// Overwrites the existing reel path in place, mirroring
    /// runSwapReelAudio, so the reel player picks up the change with no new
    /// path wiring. Returns the render output path on success, nil when
    /// there's no override or no existing reel to overwrite.
    @discardableResult
    func runRenderFridayOverride(event: Event) async throws -> String? {
        guard let fri = event.days[DayName.friday.rawValue],
              let override = fri.fridayClipOverride, !override.isEmpty,
              let reelPath = event.previewMediaPaths[DayName.friday.rawValue]?["reel"] else {
            return nil
        }

        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_friday_override_manifest_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestFile) }

        var manifest = Self.buildFridayOverrideManifest(override: override, originalPlan: fri.fridayClipPlan)
        manifest["duck_gain_db"] = fri.fridayAudioDuckDB
        manifest["mute_clip_audio"] = fri.fridayAudioMuted
        manifest["title_card_muted"] = fri.titleCardMuted
        manifest["event_name"] = event.name
        manifest["shoot_type"] = event.shootType.pythonValue
        manifest["pieces"] = (event.ocrResult?.pieces ?? []).map {
            ["title": $0.title, "composer": $0.composer]
        }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestFile)

        try await runProcess(args: [
            "-m", "postroll.ai.render_friday_override",
            "--manifest", manifestFile.path,
            "--output", reelPath,
        ])

        guard FileManager.default.fileExists(atPath: reelPath) else { return nil }
        return reelPath
    }

    /// Builds the render_friday_override.py manifest: fridayClipOverride
    /// entries reordered by `order` and filtered to `included`, each
    /// carrying over its transition from the original AI plan (matched by
    /// clip path) since ReelClipOverride has no transition field of its
    /// own. A swap-in clip the AI never selected defaults to "cut".
    /// A pure function (no actor-isolated state), so nonisolated: callable
    /// directly, and internal (not private) so PostRollTests can pin the
    /// exact wire format render_friday_override.py expects.
    nonisolated static func buildFridayOverrideManifest(
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
            guard let pd = event.days[dayName.rawValue],
                  !pd.photoPaths.isEmpty || pd.rawPhotoPath != nil || pd.editedPhotoPath != nil
                      || !pd.clipPaths.isEmpty
            else { continue }
            // photoPaths is the source of truth for reel/collage order. It's
            // sorted once at import (changeReelPhotos) and any user-driven
            // reorders (e.g. Thursday swap) live there. Don't re-sort here —
            // doing so would silently revert manual swaps on every regen.
            var entry: [String: Any] = ["photos": pd.photoPaths.map { $0.path }]
            if dayName == .thursday {
                print("[PostRoll:buildMediaManifest] Thursday photos in manifest (\(pd.photoPaths.count)):")
                for (i, url) in pd.photoPaths.enumerated() {
                    print("  [\(i)] \(url.lastPathComponent)")
                }
            }
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
                if !pd.clipPaths.isEmpty { entry["clips"] = pd.clipPaths.map { $0.path } }
                entry["clip_duck_db"] = pd.fridayAudioDuckDB
                entry["clip_audio_muted"] = pd.fridayAudioMuted
                entry["title_card_muted"] = pd.titleCardMuted
            default:
                break
            }
            // Instagram grid cover image (Thursday + Friday only): a manual
            // override always wins over the AI pick, same nil-means-AI /
            // non-nil-means-user semantics as collageCellOverride. Lets
            // Phase 1's sticky gate skip its Claude call on regen.
            if let source = pd.coverOverride ?? pd.coverPick?.sourcePath {
                entry["cover_source"] = source
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

        let manifest: [String: Any] = [
            "event":         event.name,
            "org":           event.org,
            "venue":         event.venue,
            "venue_context": event.venueContext,
            "date":          event.isoDate,
            "shoot_type":    event.shootType.pythonValue,
            "day":           day.rawValue,
            "program":       programDict,
            "existing":      captionDict,
            "feedback":      feedback,
        ]

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

        let manifest: [String: Any] = [
            "event":         event.name,
            "org":           event.org,
            "venue":         event.venue,
            "venue_context": event.venueContext,
            "date":          event.isoDate,
            "shoot_type":    event.shootType.pythonValue,
            "program":       programDict,
            "existing":      blogDict,
            "feedback":      feedback,
        ]

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

        var manifest: [String: Any] = [
            "body":        currentBody,
            "photo_paths": photoPaths.map { $0.path },
        ]
        if let event {
            manifest["venue"] = event.venue
            if let ocr = event.ocrResult,
               let program = try? JSONSerialization.jsonObject(
                   with: JSONEncoder().encode(ocr)) {
                manifest["program"] = program
            }
        }
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

        // Parse event-wide handles (org, venue) — prepended to every day
        let eventHandleList: [String] = event.eventHandles
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Build per-day entries, optionally filtered to a subset
        let performers = ocr.performers
        var daysDict: [String: Any] = [:]
        for dayName in DayName.allCases {
            if let only = onlyDays, !only.contains(dayName.rawValue) { continue }
            guard let pd = event.days[dayName.rawValue],
                  !pd.photoPaths.isEmpty || pd.rawPhotoPath != nil || pd.editedPhotoPath != nil
                      || !pd.clipPaths.isEmpty
            else { continue }
            var dayEntry: [String: Any] = [
                "photos": pd.photoPaths.map { $0.path },
            ]
            // Friday clip reel: the persisted Stage 2 plan (already selected/
            // ordered/trimmed by generate_media.py, decoded back into
            // fridayClipPlan) is sent along so generate_week.py can re-extract
            // representative frames for the caption call without redoing
            // Stage 1/2 selection.
            if dayName == .friday {
                if !pd.clipPaths.isEmpty { dayEntry["clips"] = pd.clipPaths.map { $0.path } }
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

            // Merge selected performers into handles / name mentions
            let selectedIDs = Set(pd.selectedPerformerIDs)
            var performerHandles: [String] = []
            var performerNames: [String] = []
            for p in performers where selectedIDs.contains(p.id) {
                let h = p.handle.trimmingCharacters(in: .whitespaces)
                if !h.isEmpty && Self.isRealHandle(h) {
                    performerHandles.append(h.hasPrefix("@") ? h : "@\(h)")
                } else if !p.name.isEmpty {
                    performerNames.append(p.name)
                }
            }

            // People tagged on individual photos are credited by the caption too
            // (#171). Without this, tagging a carousel photo only produced the
            // PHOTO TAGS list in CAPTIONS.txt and Dan had to tick the same
            // person again at day level to get them into the caption.
            var photoTagHandles: [String] = []
            var photoTagNames: [String] = []
            for tags in pd.photoTags.values {
                for raw in tags {
                    let tag = raw.trimmingCharacters(in: .whitespaces)
                    guard !tag.isEmpty else { continue }
                    if tag.hasPrefix("@") {
                        if Self.isRealHandle(tag) { photoTagHandles.append(tag) }
                    } else {
                        photoTagNames.append(tag)
                    }
                }
            }
            // photoTags iterates a dictionary, so sort for a stable manifest.
            photoTagHandles.sort()
            photoTagNames.sort()

            // Event-wide handles (org, venue) + selected performer handles +
            // manual day handles + per-photo tags. Deduped case-insensitively so
            // someone picked two ways is credited once.
            let allHandles = Self.dedupedPreservingOrder(
                eventHandleList + performerHandles + pd.tagHandles + photoTagHandles)
            let allNames = Self.dedupedPreservingOrder(
                performerNames + pd.nameMentions + photoTagNames)
            if !allHandles.isEmpty { dayEntry["tag_handles"]   = allHandles }
            if !allNames.isEmpty   { dayEntry["name_mentions"] = allNames }
            if !pd.notes.isEmpty   { dayEntry["notes"]         = pd.notes }
            if let source = pd.coverOverride ?? pd.coverPick?.sourcePath {
                dayEntry["cover_source"] = source
            }
            // Per-photo people tags (Wednesday). Re-key from the URL
            // absoluteString the UI stores to the POSIX path used in `photos`,
            // so Python can line each tag up with its photo by path.
            if !pd.photoTags.isEmpty {
                var tagsByPath: [String: [String]] = [:]
                for (key, tags) in pd.photoTags where !tags.isEmpty {
                    let path = URL(string: key)?.path ?? key
                    tagsByPath[path] = tags
                }
                if !tagsByPath.isEmpty { dayEntry["photo_tags"] = tagsByPath }
            }
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

    struct HandleSuggestion: Codable {
        var name: String
        var handle: String?
        var profileURL: String?
        var confidence: String
        var note: String?

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
                "Handle lookup failed. The web search may have timed out — try again with fewer performers, or check ~/Documents/PostRoll/logs."
            )
        }

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.invalidOutput(
                "Handle lookup produced no output. Check ~/Documents/PostRoll/logs for details."
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
    struct PieceNoteResult: Codable {
        var title: String
        var composer: String
        var notes: String?

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
    func runFlagIssues(ocr: OCRResult, imagePaths: [URL]) async throws -> [OCRFlag] {
        guard !imagePaths.isEmpty else { return [] }

        let programFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_flag_program_\(UUID().uuidString).json")
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_flag_out_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: programFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let programData = try JSONEncoder().encode(ocr)
        try programData.write(to: programFile)

        var args = ["-m", "postroll.ai.flag_issues", "--program", programFile.path]
        for url in imagePaths {
            args.append("--image")
            args.append(url.path)
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

    func runOCR(imagePaths: [URL]) async throws -> OCRResult {
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("postroll_ocr_\(UUID().uuidString).json")

        defer { try? FileManager.default.removeItem(at: outputFile) }

        var args = ["-m", "postroll.ai.ocr_program", "--output", outputFile.path]
        for path in imagePaths { args += ["--image", path.path] }

        try await runProcess(args: args)

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

        let manifest: [String: Any] = [
            "posts":                      postsJSON,
            "org_bands":                  orgBandsDict,
            "global_hashtags_to_exclude": globalHashtags,
        ]

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

        let manifest: [String: Any] = [
            "brand_voice": brandVoice,
            "edits":       edits,
        ]
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
        return json["suggestion"] as? String
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
        let escaped = root.path.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "export POSTROLL_DATA_DIR='\(escaped)'"
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
    private func runProcess(args: [String], timeout: TimeInterval = 1800) async throws {
        let python = python3
        let root = projectRoot
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
        let brandVoicePath = AppPaths.brandVoiceFile.path
            .replacingOccurrences(of: "'", with: "'\"'\"'")
        let brandVoiceExport = "export POSTROLL_BRAND_VOICE='\(brandVoicePath)'"

        // Python cannot reproduce AppPaths' marker-gated choice between
        // Documents and Application Support, so the app tells it. The AI usage
        // log (#207) is written here.
        let dataDirExport = Self.dataDirExport(AppPaths.root)

        let quotedArgs = ([python] + args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
            .joined(separator: " ")

        let logPath = logURL.path.replacingOccurrences(of: "'", with: "'\"'\"'")
        // This run's own stderr file. The shared log is truncated by whichever
        // run starts next, and that truncation swaps the inode under any run
        // already appending, so a shared file could lose this run's output
        // entirely and hand back somebody else's (#90).
        let runMarker = UUID().uuidString
        let runLogURL = PythonBridgeLog.runLogURL(in: logsDir, marker: runMarker)
        let runLogPath = runLogURL.path.replacingOccurrences(of: "'", with: "'\"'\"'")
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
            \(brandVoiceExport)
            \(dataDirExport)
            cd '\(root.path)'
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running [\(runMarker)]:" \(quotedArgs) >> '\(runLogPath)'
            exec \(quotedArgs) 2>> '\(runLogPath)'
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
            logFallback: {
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
