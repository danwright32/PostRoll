import Foundation

/// One candidate track returned by the music-picker fetcher.
struct TrackCandidate: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var artistName: String
    var duration: Double
    var tags: String
    var localPath: String
    /// "program" when the track was matched by piece search; nil otherwise.
    var source: String?
    /// "<title> — <composer>" of the program piece this track was matched
    /// against. Only populated when source == "program".
    var matchLabel: String?

    enum CodingKeys: String, CodingKey {
        case id, name, duration, tags, source
        case artistName = "artist_name"
        case localPath  = "local_path"
        case matchLabel = "match_label"
    }

    var localURL: URL { URL(fileURLWithPath: localPath) }
    var isProgramMatch: Bool { source == "program" }
}

enum PythonBridgeError: LocalizedError {
    case scriptFailed(exitCode: Int32, stderr: String)
    case outputMissing
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(_, let stderr):
            return Self.humanise(stderr: stderr)
        case .outputMissing:
            return "Generation finished but produced no output. Check that the program PDF has readable text and try again."
        case .invalidOutput:
            return "Generated output couldn't be read. Try regenerating. If it keeps failing, check ~/Documents/PostRoll/logs."
        }
    }

    private static func humanise(stderr: String) -> String {
        let s = stderr.lowercased()
        if s.contains("no performers") || s.contains("performers is empty") || s.contains("no performer") {
            return "Generation failed: no performers found in your OCR data. Go back to OCR review and add at least one performer, then try again."
        }
        if s.contains("no pieces") || s.contains("pieces is empty") || s.contains("no works") {
            return "Generation failed: no program works found in your OCR data. Go back to OCR review and add at least one work, then try again."
        }
        if s.contains("ffmpeg") {
            return "Media generation failed: ffmpeg is not installed. Run `brew install ffmpeg` in Terminal, then try again."
        }
        // Order matters: check 413 / request_too_large BEFORE the generic "anthropic" check.
        if s.contains("413") || s.contains("request_too_large") || s.contains("request exceeds the maximum size") || s.contains("payload too large") {
            return "The program photos are too large for the AI service to process in one call. Try uploading fewer pages at a time, or downscale the images (Preview › Tools › Adjust Size), then try again."
        }
        if s.contains("rate_limit") || s.contains("rate limit") || s.contains("429") || s.contains("overloaded") {
            return "The AI service is rate-limiting or overloaded right now. Wait a minute and try again."
        }
        if s.contains("anthropic") || s.contains("openai") || s.contains("api key") || s.contains("apikey") {
            return "Generation failed: could not connect to the AI service. Check that your API key is set correctly and that you have internet access."
        }
        if s.contains("json") || s.contains("decode") || s.contains("parse") {
            return "Generation failed: the output could not be read. This is usually a temporary issue. Try again."
        }
        if s.contains("no such file") || s.contains("filenotfounderror") {
            return "Generation failed: a required file was not found. Check that your photos are still in their original locations."
        }
        // Fall back to a trimmed version of stderr (first 120 chars), not a raw traceback
        let trimmed = stderr.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? stderr
        let preview = trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
        return "Generation failed: \(preview). Check ~/Documents/PostRoll/logs if this persists."
    }
}

actor PythonBridge {
    static let shared = PythonBridge()

    /// Sentinel values that mark "I looked this up and there's no Instagram."
    /// Stored in the handle book so we don't re-search, but not passed to captions.
    private static let handleSentinels: Set<String> = [
        "unknown", "n/a", "na", "none", "-", "no", "skip",
    ]

    nonisolated static func isRealHandle(_ handle: String) -> Bool {
        var h = handle.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("@") { h = String(h.dropFirst()) }
        return !h.isEmpty && !handleSentinels.contains(h)
    }

    // nonisolated lets these be read from Task.detached without hopping back to the actor
    nonisolated let projectRoot: URL
    nonisolated let python3: String

    private init() {
        let root = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/PostRoll")
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

    /// Result of a preview-generation run. `paths` mirrors Python's per-day
    /// output dict; `errors` carries the per-day failure messages Python writes
    /// when a day couldn't be generated (e.g. missing photo, ffmpeg crash). A
    /// successful run for a given day means `paths[day]` is non-empty AND
    /// `errors[day]` is absent.
    struct PreviewGenerationResult {
        let paths: [String: [String: String]]
        let errors: [String: String]
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
        let previewRoot  = projectRoot.appendingPathComponent("preview")

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
        for dayKey in ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"] {
            guard let dayDict = json[dayKey] as? [String: String] else { continue }
            // Include both images and video files (.mp4)
            let existing = dayDict.filter { FileManager.default.fileExists(atPath: $0.value) }
            if !existing.isEmpty { paths[dayKey] = existing }
        }
        let errors = (json["errors"] as? [String: String]) ?? [:]
        return PreviewGenerationResult(paths: paths, errors: errors)
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

    // MARK: - Music picker (candidate tracks)

    /// Fetch a batch of candidate Jamendo tracks matching `tags`. Each candidate is
    /// pre-downloaded to the shared audio cache so the UI can preview it immediately.
    /// Pass `excludeIds` to skip tracks the user has already seen (used for
    /// "get new tracks" pagination).
    func runFetchTrackCandidates(
        tags: String,
        count: Int = 5,
        excludeIds: [String] = [],
        programPieces: [Piece]? = nil
    ) async throws -> [TrackCandidate] {
        let tmp = FileManager.default.temporaryDirectory
        let outputFile = tmp.appendingPathComponent("postroll_tracks_\(UUID().uuidString).json")
        let programFile = tmp.appendingPathComponent("postroll_tracks_program_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: outputFile)
            try? FileManager.default.removeItem(at: programFile)
        }

        var args: [String] = [
            "-m", "postroll.ai.fetch_tracks",
            "--tags", tags,
            "--count", String(count),
            "--output", outputFile.path,
        ]
        if !excludeIds.isEmpty {
            args.append("--exclude-ids")
            args.append(excludeIds.joined(separator: ","))
        }
        if let pieces = programPieces, !pieces.isEmpty {
            let dict: [String: Any] = [
                "pieces": pieces.map { ["title": $0.title, "composer": $0.composer] }
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict) {
                try data.write(to: programFile)
                args.append("--program")
                args.append(programFile.path)
            }
        }

        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else { return [] }
        let data = try Data(contentsOf: outputFile)
        struct Wrapper: Codable { let tracks: [TrackCandidate] }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        return wrapper.tracks
    }

    /// Builds the media manifest dict shared by runMediaGeneration and runPreviewGeneration.
    private func buildMediaManifest(event: Event) -> [String: Any] {
        var daysDict: [String: Any] = [:]
        for dayName in DayName.allCases {
            guard let pd = event.days[dayName.rawValue],
                  !pd.photoPaths.isEmpty || pd.rawPhotoPath != nil || pd.editedPhotoPath != nil
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
            case .wednesday:
                if let seed = pd.collageSeed         { entry["collage_seed"]      = seed }
                let offsets = pd.photoPaths.map { url -> [Double] in
                    let o = pd.collageCropOffsets[url.absoluteString] ?? CropOffset()
                    return [o.x, o.y, o.scale]
                }
                if offsets.contains(where: { $0[0] != 0 || $0[1] != 0 || $0[2] != 1.0 }) {
                    entry["crop_offsets"] = offsets
                }
                // Pass user-dragged frame layout to Python so it renders at the exact positions
                if let cellOverride = pd.collageCellOverride, !cellOverride.isEmpty {
                    entry["cell_layout"] = cellOverride.map { [
                        "photo_path": $0.photoPath,
                        "x": $0.x, "y": $0.y,
                        "w": $0.w, "h": $0.h,
                    ] as [String: Any] }
                }
            case .friday:
                if let raw  = pd.rawPhotoPath        { entry["raw_photo"]         = raw.path }
                if let edit = pd.editedPhotoPath     { entry["edited_photo"]      = edit.path }
                if let bw   = pd.bwPhotoPath         { entry["bw_photo"]          = bw.path }
            default:
                break
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
    func runBlogPhotoSwap(currentBody: String, photoPaths: [URL]) async throws -> BlogOutput {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_swap_photos_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_swapped_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let manifest: [String: Any] = [
            "body":        currentBody,
            "photo_paths": photoPaths.map { $0.path },
        ]
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

    // MARK: - Manifest builder

    private func buildManifest(event: Event, onlyDays: Set<String>? = nil) throws -> [String: Any] {
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
            else { continue }
            var dayEntry: [String: Any] = [
                "photos": pd.photoPaths.map { $0.path },
            ]

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

            // Event-wide handles (org, venue) + selected performer handles + manual day handles
            let allHandles = eventHandleList + performerHandles + pd.tagHandles
            let allNames   = performerNames + pd.nameMentions
            if !allHandles.isEmpty { dayEntry["tag_handles"]   = allHandles }
            if !allNames.isEmpty   { dayEntry["name_mentions"] = allNames }
            if !pd.notes.isEmpty   { dayEntry["notes"]         = pd.notes }
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

    // MARK: - Audio Tags
    //
    // Calls postroll.ai.audio_tags via CLI to fetch the canonical Jamendo
    // tags for a posting day. Single source of truth so the Swift track
    // picker matches what the Python reel generators auto-fetch.

    func suggestAudioTags(day: DayName, shootType: ShootType, pieces: [Piece]) async -> String {
        let tmp = FileManager.default.temporaryDirectory
        let programFile = tmp.appendingPathComponent("postroll_audio_tags_in_\(UUID().uuidString).json")
        let outputFile = tmp.appendingPathComponent("postroll_audio_tags_out_\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: programFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        // Thursday is the only day that consumes pieces — writing them
        // unconditionally keeps the call site simple.
        let dict: [String: Any] = [
            "pieces": pieces.map { ["title": $0.title, "composer": $0.composer] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: programFile)
        }

        let args = [
            "-m", "postroll.ai.audio_tags",
            "--day", day.rawValue,
            "--shoot-type", shootType.pythonValue,
            "--program", programFile.path,
            "--output", outputFile.path,
        ]
        do {
            try await runProcess(args: args)
            if let data = try? Data(contentsOf: outputFile),
               let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        } catch {
            // Fall through to the static default below
        }
        return day == .tuesday ? "electronic,upbeat" : "ambient,atmospheric"
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
        decoder.dateDecodingStrategy = .iso8601
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
        decoder.dateDecodingStrategy = .iso8601
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

        // Read brand voice from disk
        let brandVoiceFile = projectRoot
            .appendingPathComponent("postroll/assets/brand-voice.md")
        let brandVoice = (try? String(contentsOf: brandVoiceFile, encoding: .utf8)) ?? ""

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
        let file = projectRoot
            .appendingPathComponent("postroll/assets/brand-voice.md")
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
        let file = projectRoot
            .appendingPathComponent("postroll/assets/brand-voice.md")
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

    // MARK: - Private

    /// Runs the Python command via `zsh -l` so the user's login shell profile
    /// (and therefore ANTHROPIC_API_KEY etc.) are available even when the app
    /// is launched from Finder rather than a terminal.
    ///
    /// Supports Swift task cancellation: when the calling task is cancelled,
    /// the subprocess is terminated immediately via SIGTERM.
    private func runProcess(args: [String]) async throws {
        let python = python3
        let root = projectRoot
        let logURL = root
            .appendingPathComponent("logs")
            .appendingPathComponent("postroll.log")

        // Ensure logs directory exists
        let logsDir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let quotedArgs = ([python] + args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
            .joined(separator: " ")

        let logPath = logURL.path.replacingOccurrences(of: "'", with: "'\"'\"'")
        // `exec` replaces the shell with the Python process so that terminating
        // this Process object directly kills the Python subprocess, not just the
        // shell wrapper.
        let apiKeyExport: String
        if let key = KeychainStore.readAPIKey() {
            let escaped = key.replacingOccurrences(of: "'", with: "'\"'\"'")
            apiKeyExport = "export ANTHROPIC_API_KEY='\(escaped)'"
        } else {
            apiKeyExport = ""
        }

        let script = """
            export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            [ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"
            \(apiKeyExport)
            cd '\(root.path)'
            if [ -f '\(logPath)' ]; then
                tail -n 500 '\(logPath)' > '\(logPath).tmp' && mv '\(logPath).tmp' '\(logPath)'
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running:" \(quotedArgs) >> '\(logPath)'
            exec \(quotedArgs) 2>> '\(logPath)'
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", script]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        // Use terminationHandler (non-blocking) + withTaskCancellationHandler so
        // cancelling the calling Swift task immediately sends SIGTERM to the process.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { p in
                    let status = p.terminationStatus
                    if status == 0 {
                        cont.resume()
                    } else {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                        cont.resume(throwing: PythonBridgeError.scriptFailed(exitCode: status, stderr: stderr))
                    }
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}
