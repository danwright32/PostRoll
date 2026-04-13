import Foundation

enum PythonBridgeError: LocalizedError {
    case scriptFailed(exitCode: Int32, stderr: String)
    case outputMissing
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let code, let stderr):
            return "Python exited with code \(code).\n\(stderr)"
        case .outputMissing:
            return "Python ran but produced no output file."
        case .invalidOutput(let detail):
            return "Could not parse output: \(detail)"
        }
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

    func runWeekGeneration(event: Event) async throws -> WeekGenerationResult {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_manifest_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_week_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        // Build manifest
        let manifest = try buildManifest(event: event)
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestFile)

        // Run Python
        let args = [
            "-m", "postroll.ai.generate_week",
            "--manifest", manifestFile.path,
            "--output",   outputFile.path,
        ]
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        let data = try Data(contentsOf: outputFile)
        do {
            return try JSONDecoder().decode(WeekGenerationResult.self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Media generation (stories + collage)

    /// Generates story images for each day and a masonry collage for Wednesday.
    /// Throws on Python error; individual day failures are logged but non-fatal.
    /// Returns URLs of all static images (PNG) that were successfully written.
    func runMediaGeneration(event: Event, outputDir: URL) async throws -> [URL] {
        let tmp = FileManager.default.temporaryDirectory
        let manifestFile = tmp.appendingPathComponent("postroll_media_manifest_\(UUID().uuidString).json")
        let outputFile   = tmp.appendingPathComponent("postroll_media_\(UUID().uuidString).json")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        // Build a lightweight manifest (no OCR needed — just photos + special assets)
        var daysDict: [String: Any] = [:]
        for dayName in DayName.allCases {
            guard let pd = event.days[dayName.rawValue], !pd.photoPaths.isEmpty else { continue }
            var entry: [String: Any] = ["photos": pd.photoPaths.map { $0.path }]
            // Day-specific special assets
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
            case .wednesday:
                if let seed = pd.collageSeed         { entry["collage_seed"]      = seed }
                // Build crop_offsets list parallel to photos
                let offsets = pd.photoPaths.map { url -> [Double] in
                    let o = pd.cropOffsets[url.absoluteString] ?? CropOffset()
                    return [o.x, o.y]
                }
                if offsets.contains(where: { $0[0] != 0 || $0[1] != 0 }) {
                    entry["crop_offsets"] = offsets
                }
            case .friday:
                if let raw  = pd.rawPhotoPath        { entry["raw_photo"]         = raw.path }
                if let edit = pd.editedPhotoPath     { entry["edited_photo"]      = edit.path }
            default:
                break
            }
            daysDict[dayName.rawValue] = entry
        }

        let manifest: [String: Any] = [
            "event":  event.name,
            "org":    event.org,
            "venue":  event.venue,
            "date":   event.isoDate,
            "days":   daysDict,
        ]

        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestFile)

        let args = [
            "-m", "postroll.ai.generate_media",
            "--manifest",   manifestFile.path,
            "--output-dir", outputDir.path,
            "--output",     outputFile.path,
        ]
        try await runProcess(args: args)

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw PythonBridgeError.outputMissing
        }

        // Decode output JSON to collect successfully generated static image paths
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
            throw PythonBridgeError.invalidOutput("No OCR result — complete the OCR step first.")
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
            "event":      event.name,
            "org":        event.org,
            "venue":      event.venue,
            "date":       event.isoDate,
            "shoot_type": event.shootType.pythonValue,
            "day":        day.rawValue,
            "program":    programDict,
            "existing":   captionDict,
            "feedback":   feedback,
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
            return try JSONDecoder().decode(DayCaption.self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
    }

    // MARK: - Manifest builder

    private func buildManifest(event: Event) throws -> [String: Any] {
        // Serialize OCRResult via JSONEncoder so CodingKeys produce snake_case
        guard let ocr = event.ocrResult else {
            throw PythonBridgeError.invalidOutput("No OCR result — complete the OCR step first.")
        }
        let ocrData = try JSONEncoder().encode(ocr)
        guard let programDict = try JSONSerialization.jsonObject(with: ocrData) as? [String: Any] else {
            throw PythonBridgeError.invalidOutput("Could not serialise OCR result.")
        }

        // Build per-day entries
        var daysDict: [String: Any] = [:]
        for dayName in DayName.allCases {
            guard let pd = event.days[dayName.rawValue], !pd.photoPaths.isEmpty else { continue }
            var dayEntry: [String: Any] = [
                "photos": pd.photoPaths.map { $0.path },
            ]
            if !pd.tagHandles.isEmpty   { dayEntry["tag_handles"]   = pd.tagHandles }
            if !pd.nameMentions.isEmpty { dayEntry["name_mentions"] = pd.nameMentions }
            if !pd.notes.isEmpty        { dayEntry["notes"]         = pd.notes }
            daysDict[dayName.rawValue] = dayEntry
        }

        var manifest: [String: Any] = [
            "event":      event.name,
            "org":        event.org,
            "venue":      event.venue,
            "date":       event.isoDate,
            "shoot_type": event.shootType.pythonValue,
            "program":    programDict,
            "days":       daysDict,
        ]
        if !event.blogPhotoPaths.isEmpty {
            manifest["blog_photos"] = event.blogPhotoPaths.map { $0.path }
        }
        return manifest
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
            return try JSONDecoder().decode(OCRResult.self, from: data)
        } catch {
            throw PythonBridgeError.invalidOutput(error.localizedDescription)
        }
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
    private func runProcess(args: [String]) async throws {
        let python = python3
        let root = projectRoot

        try await Task.detached {
            // Shell-quote each argument (single-quote, escape embedded single-quotes)
            let quotedArgs = ([python] + args)
                .map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
                .joined(separator: " ")
            let script = "cd '\(root.path)' && \(quotedArgs)"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", script]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                throw PythonBridgeError.scriptFailed(exitCode: process.terminationStatus, stderr: stderr)
            }
        }.value
    }
}
