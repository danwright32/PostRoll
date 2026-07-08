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
        case .invalidOutput:
            return "Generated output couldn't be read. Try regenerating. If it keeps failing, check ~/Documents/PostRoll/logs."
        case .timedOut(let seconds):
            return "The operation was still running after \(Int(seconds / 60)) minutes and was stopped. Check your internet connection and try again."
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
}
