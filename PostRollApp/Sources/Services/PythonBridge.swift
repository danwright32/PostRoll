import Foundation

/// One candidate track returned by the music-picker fetcher.
struct TrackCandidate: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var artistName: String
    var duration: Double
    var tags: String
    var localPath: String

    enum CodingKeys: String, CodingKey {
        case id, name, duration, tags
        case artistName = "artist_name"
        case localPath  = "local_path"
    }

    var localURL: URL { URL(fileURLWithPath: localPath) }
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

        // Parse per-phase timing if available
        if let timingData = try? Data(contentsOf: timingFile),
           let timing = try? JSONDecoder().decode([String: Double?].self, from: timingData) {
            TimingStore.shared.recordGenerationPhases(
                captions:  timing["captions"]  ?? nil,
                blog:      timing["blog"]      ?? nil,
                packaging: timing["packaging"] ?? nil
            )
        }

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        do {
            var result = try JSONDecoder().decode(WeekGenerationResult.self, from: data)
            result.stampOriginals()
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

    /// Generates static-only preview graphics (no reels) to a stable preview
    /// directory. Run after text generation so the user can see the graphics
    /// in the caption review step. Non-throwing — caller handles errors.
    ///
    /// Returns a dict mapping day name → asset type → absolute path,
    /// mirroring the Python output JSON (e.g. ["sunday": ["story": "/path/..."]])
    func runPreviewGeneration(event: Event, days: [String]? = nil) async throws -> [String: [String: String]] {
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

        guard FileManager.default.fileExists(atPath: outputFile.path) else { return [:] }

        let data = try Data(contentsOf: outputFile)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }

        var result: [String: [String: String]] = [:]
        for dayKey in ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"] {
            guard let dayDict = json[dayKey] as? [String: String] else { continue }
            // Include both images and video files (.mp4)
            let existing = dayDict.filter { FileManager.default.fileExists(atPath: $0.value) }
            if !existing.isEmpty { result[dayKey] = existing }
        }
        return result
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

    // MARK: - Music picker (candidate tracks)

    /// Fetch a batch of candidate Jamendo tracks matching `tags`. Each candidate is
    /// pre-downloaded to the shared audio cache so the UI can preview it immediately.
    /// Pass `excludeIds` to skip tracks the user has already seen (used for
    /// "get new tracks" pagination).
    func runFetchTrackCandidates(
        tags: String,
        count: Int = 5,
        excludeIds: [String] = []
    ) async throws -> [TrackCandidate] {
        let tmp = FileManager.default.temporaryDirectory
        let outputFile = tmp.appendingPathComponent("postroll_tracks_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputFile) }

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
            guard let pd = event.days[dayName.rawValue], !pd.photoPaths.isEmpty else { continue }
            var entry: [String: Any] = ["photos": pd.photoPaths.map { $0.path }]
            switch dayName {
            case .tuesday:
                if let rec  = pd.screenRecordingPath { entry["screen_recording"]  = rec.path }
                if let raw  = pd.rawPhotoPath        { entry["raw_photo"]         = raw.path }
                if let edit = pd.editedPhotoPath     { entry["edited_photo"]      = edit.path }
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
        var daysDict: [String: Any] = [:]
        for dayName in DayName.allCases {
            if let only = onlyDays, !only.contains(dayName.rawValue) { continue }
            guard let pd = event.days[dayName.rawValue], !pd.photoPaths.isEmpty else { continue }
            var dayEntry: [String: Any] = [
                "photos": pd.photoPaths.map { $0.path },
            ]
            // Event-wide handles (org, venue) + any day-specific performer handles
            let allHandles = eventHandleList + pd.tagHandles
            if !allHandles.isEmpty      { dayEntry["tag_handles"]   = allHandles }
            if !pd.nameMentions.isEmpty { dayEntry["name_mentions"] = pd.nameMentions }
            if !pd.notes.isEmpty        { dayEntry["notes"]         = pd.notes }
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
        let script = """
            export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            [ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"
            cd '\(root.path)'
            if [ -f '\(logPath)' ]; then
                tail -n 500 '\(logPath)' > '\(logPath).tmp' && mv '\(logPath).tmp' '\(logPath)'
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running: \(quotedArgs)" >> '\(logPath)'
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
