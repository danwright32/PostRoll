import Foundation

enum PythonBridgeError: LocalizedError {
    case scriptFailed(exitCode: Int32, stderr: String)
    case outputMissing
    case invalidOutput(String)
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(_, let stderr):
            return Self.humanise(stderr: stderr)
        case .outputMissing:
            return "Generation finished but produced no output. Check that the program PDF has readable text and try again."
        case .invalidOutput(let reason):
            // Every call site writes a reason and this switch used to discard
            // all of them, so "No OCR result. Complete the OCR step first."
            // and "Cover regeneration did not produce a cover path." arrived
            // as the same sentence, and the one naming the step to go back to
            // was the one that never showed up (#365).
            let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let whereToLook = "If it keeps failing, check \(AppPaths.logsDirDisplayPath)."
            guard !detail.isEmpty else {
                return "Generated output couldn't be read. Try regenerating. \(whereToLook)"
            }
            return "\(detail)\n\n\(whereToLook)"
        case .timedOut(let seconds):
            return "The operation was still running after \(Int(seconds / 60)) minutes and was stopped. Check your internet connection and try again."
        }
    }

    /// What to tell Dan about a whole run that died.
    ///
    /// What the failure IS comes from `RunFailureKind`, which is the only place
    /// that reads the text. This decides what to say about it, in the language of
    /// a whole run. `GenerationFailureText` says it in the language of one day,
    /// off the same kind, so the two can no longer disagree about what happened
    /// or how long to wait (#401).
    private static func humanise(stderr: String) -> String {
        switch RunFailureKind.of(stderr) {
        case .performersMissing:
            return "Generation failed: no performers found in your OCR data. Go back to OCR "
                 + "review and add at least one performer, then try again."
        case .piecesMissing:
            return "Generation failed: no program works found in your OCR data. Go back to OCR "
                 + "review and add at least one work, then try again."
        case .ffmpegMissing:
            return "Media generation failed: ffmpeg is not installed. Run `brew install ffmpeg` "
                 + "in Terminal, then try again."
        case .audioServiceUnreachable:
            return "Couldn't reach Jamendo for background audio. Check your JAMENDO_CLIENT_ID "
                 + "env var, or upload your own audio file, then try again."
        case .requestTooLarge:
            return "The program photos are too large for the AI service to process in one call. "
                 + "Try uploading fewer pages at a time, or downscale the images "
                 + "(Preview › Tools › Adjust Size), then try again."
        case .rateLimited:
            return waitSentence("The AI service is rate-limiting right now.", .rateLimited)
        case .overloaded:
            return waitSentence("The AI service is overloaded right now.", .overloaded)
        case .authFailed:
            return "Generation failed: the AI service rejected the API key. Check that "
                 + "ANTHROPIC_API_KEY is set correctly, then try again."
        case .aiServiceError:
            return waitSentence("Generation failed: the AI service returned an error.",
                                .aiServiceError)
        case .outputUnreadable:
            return "Generation failed: the output could not be read. This is usually a "
                 + "temporary issue. Try again."
        case .fileMissing:
            return "Generation failed: a required file was not found. Check that your photos "
                 + "are still in their original locations."
        // The per-day kinds cannot be reached from here, because `of` is called
        // without a day. Named rather than defaulted, so adding a kind is a
        // compile error here instead of silently becoming the fallback.
        case .collageShortfall, .beforeAfterInputsMissing, .reelPhotosMissing,
             .storyFallbackFailed, .unknown:
            return fallback(stderr: stderr)
        }
    }

    /// One wait per kind, taken from the kind rather than written per sentence.
    private static func waitSentence(_ cause: String, _ kind: RunFailureKind) -> String {
        guard let wait = kind.waitAdvice else { return "\(cause) Try again." }
        return "\(cause) Wait \(wait) and try again."
    }

    /// The last line of stderr rather than a raw traceback, and never the whole
    /// thing. Nothing is claimed about a failure we did not recognise.
    private static func fallback(stderr: String) -> String {
        let trimmed = stderr.split(separator: "\n")
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? stderr
        let preview = trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
        return "Generation failed: \(preview). Check \(AppPaths.logsDirDisplayPath) "
             + "if this persists."
    }
}

/// Helpers for reading the shared rolling `postroll.log`. The log accumulates
/// output from every Python invocation across the app's lifetime (OCR,
/// generation, export, ...); when a subprocess fails with no direct stderr
/// (the common case: its real stderr is redirected straight into the log
/// file rather than the pipe Swift reads), the log is the only place to find
/// out what happened.
///
/// Reading an unscoped tail of that shared file is dangerous: a stray digit
/// sequence in an unrelated, older entry (e.g. a UUID containing "413") can
/// hijack `PythonBridgeError`'s substring-based classification and misreport
/// a completely different failure as something it isn't. `scopedTail` isolates
/// just the lines written for one invocation, identified by a marker unique
/// to that run.
enum PythonBridgeLog {
    /// Returns the log lines from the last occurrence of `marker` to the end
    /// of `logText`. Falls back to a bounded tail (never the whole file) if
    /// the marker isn't present, so a missed marker degrades to "less
    /// context" rather than reintroducing the whole-log conflation bug.
    static func scopedTail(_ logText: String, marker: String, fallbackLineCount: Int = 20) -> String {
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let markerIndex = lines.lastIndex(where: { $0.contains(marker) }) else {
            return lines.suffix(fallbackLineCount).joined(separator: "\n")
        }
        return lines[markerIndex...].joined(separator: "\n")
    }

    // MARK: - Per-run isolation (#90)
    //
    // `scopedTail` above narrows a shared file by marker, which is only as good
    // as the marker surviving. It did not: every run began by truncating the
    // shared log with `tail > tmp && mv tmp log`, and the `mv` swaps the inode
    // under any run already appending, so that run's output (marker included)
    // vanishes and `scopedTail` falls back to somebody else's tail.
    //
    // So each run now owns a private stderr file. Nothing another run does can
    // truncate it, and nothing this run reads can belong to another. The shared
    // log stays, for reading history by hand, but is only ever appended to
    // whole and rotated under a lock.

    /// Serialises rotation and folding across concurrent runs.
    private static let logLock = NSLock()

    /// The private stderr file for one invocation.
    static func runLogURL(in directory: URL, marker: String) -> URL {
        directory.appendingPathComponent("run-\(marker).log")
    }

    /// What this run actually wrote, for the error message.
    ///
    /// Its own file first. The shared log is consulted only when that file is
    /// empty, which happens when the shell died before the redirect existed (a
    /// bad interpreter, a missing cwd): degrading to less context beats
    /// degrading to an empty error.
    static func runOutput(runLog: URL, sharedLog: URL, marker: String) -> String {
        if let own = try? String(contentsOf: runLog, encoding: .utf8),
           !own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return own
        }
        guard let shared = try? String(contentsOf: sharedLog, encoding: .utf8) else { return "" }
        return scopedTail(shared, marker: marker)
    }

    /// Trim the shared log to its last `keepingLines` lines.
    ///
    /// In Swift under a lock rather than in the launch script, because the
    /// shell version raced every concurrent run.
    static func rotate(_ sharedLog: URL, keepingLines: Int = 500) {
        logLock.lock()
        defer { logLock.unlock() }
        guard let text = try? String(contentsOf: sharedLog, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > keepingLines else { return }
        let kept = lines.suffix(keepingLines).joined(separator: "\n")
        try? kept.write(to: sharedLog, atomically: true, encoding: .utf8)
    }

    /// Append a finished run's output to the shared log and delete its file.
    ///
    /// One locked append of the whole run, so two runs finishing together
    /// interleave as blocks rather than as lines, and neither is lost.
    static func foldIntoShared(runLog: URL, sharedLog: URL) {
        logLock.lock()
        defer { logLock.unlock() }
        defer { try? FileManager.default.removeItem(at: runLog) }

        guard let data = try? Data(contentsOf: runLog), !data.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: sharedLog.path) {
            try? data.write(to: sharedLog)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: sharedLog) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
