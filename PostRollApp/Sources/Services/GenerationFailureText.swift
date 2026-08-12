import Foundation

/// What the generation screen says about a day that failed.
///
/// Lifted out of `AssetGenerationView` so it can be tested and so the render
/// harness can draw the done screen carrying the messages the app really
/// produces (#396). While it lived inside the view, the only way to see any of
/// this copy was to make a real run fail in a specific way, which meant nobody
/// had read most of it.
///
/// Every branch here is a hint, never a replacement: the raw error is always
/// appended, because a summary that guesses wrong sends the diagnosis somewhere
/// unrelated and the raw text is the part Dan can act on.
enum GenerationFailureText {

    /// What to call a failed key on screen. Two of the keys are not days.
    static func dayLabel(_ key: String) -> String {
        switch key {
        case "blog": return "Blog post"
        case PreviewMergePolicy.graphicsRunKey: return "Visual assets"
        default: return key.capitalized
        }
    }

    /// The message shown for one failed day, and whether Dan can fix it himself.
    ///
    /// `fixable` decides whether the screen offers a route back to the photo
    /// screen, so a wrong answer here sends him to change inputs that were never
    /// the problem.
    static func humanize(day: String, raw: String) -> (text: String, fixable: Bool) {
        let (summary, fixable) = summary(day: day, raw: raw)
        if summary.isEmpty { return (raw, fixable) }
        return ("\(summary)\n\nRaw: \(raw)", fixable)
    }

    /// Just the actionable hint. Empty when there is no useful translation, in
    /// which case the caller shows the raw error verbatim rather than inventing
    /// an explanation for it.
    ///
    /// What the failure IS comes from `RunFailureKind`, which is the only place
    /// that reads the text. This function only decides what to say about it, in
    /// the language of one day rather than a whole run (#401).
    static func summary(day: String, raw: String) -> (text: String, fixable: Bool) {
        let kind = RunFailureKind.of(raw, day: day)
        return (sentence(for: kind, day: day), kind.isFixableFromTheApp)
    }

    /// The per-day wording. Empty means say nothing and show the raw error.
    private static func sentence(for kind: RunFailureKind, day: String) -> String {
        switch kind {
        case .ffmpegMissing:
            return "ffmpeg isn't installed. Run `brew install ffmpeg` in Terminal, then retry."
        case .audioServiceUnreachable:
            return "Couldn't reach Jamendo for background audio. Check your JAMENDO_CLIENT_ID "
                 + "env var or upload your own audio file."
        case .requestTooLarge:
            return "\(dayLabel(day)) sent too much data to Claude in one request. Reduce inputs "
                 + "(fewer photos, shorter notes) and retry."
        case .rateLimited, .overloaded, .aiServiceError:
            return serviceSentence(for: kind, day: day)
        case .authFailed:
            return "Claude API key is invalid or missing. Set ANTHROPIC_API_KEY and retry."
        case .performersMissing:
            return "No performers were found in your program data. Go back to OCR review and "
                 + "add at least one, then retry."
        case .piecesMissing:
            return "No program works were found in your program data. Go back to OCR review and "
                 + "add at least one, then retry."
        // The collage floor comes from the live preset rather than a Classic
        // literal: under Balanced a day with its full 4 photos was told it needed
        // 10, which contradicts the app's own generator (#119, #195).
        case .collageShortfall(let collageDay):
            return CollagePhotoSelection.generationShortfallHint(day: collageDay)
        case .beforeAfterInputsMissing(let inputDay):
            return inputDay == "friday"
                ? "Friday's before/after story reuses Tuesday's RAW + edited. Assign them on "
                  + "Tuesday and retry."
                : "Tuesday's before/after reel needs a RAW + edited photo. Assign them and retry."
        case .reelPhotosMissing:
            return "Thursday's scroll reel needs at least one photo. Add photos to Thursday "
                 + "and retry."
        case .fileMissing:
            return "A photo or audio file was moved or deleted. Re-assign your photos on the "
                 + "photo screen and retry."
        case .storyFallbackFailed:
            return "Even the static-image fallback for \(dayLabel(day)) couldn't run. Often "
                 + "fixed by re-uploading the day's photos."
        case .outputUnreadable:
            return "\(dayLabel(day)) finished but its output couldn't be read. This is usually "
                 + "temporary, so retry."
        case .unknown:
            // Nothing recognised, so nothing claimed. The caller shows the raw
            // error on its own rather than an invented explanation of it.
            return ""
        }
    }

    /// The three service failures, sharing one shape so the wait cannot differ
    /// between them by accident. The wait itself belongs to the kind (#401).
    private static func serviceSentence(for kind: RunFailureKind, day: String) -> String {
        let cause: String
        switch kind {
        case .rateLimited:  cause = "Hit Claude's rate limit."
        case .overloaded:   cause = "Claude is overloaded right now."
        default:            cause = "Claude API error during \(dayLabel(day))."
        }
        guard let wait = kind.waitAdvice else { return cause }
        return "\(cause) Wait \(wait) and retry, no input changes needed."
    }

    /// "Sunday, Thursday, and Blog post", for the retry button's label.
    ///
    /// Takes the labels rather than recomputing them, so the button can never
    /// name a different set from the cards above it (L16).
    static func summarySentence(_ labels: [String]) -> String {
        switch labels.count {
        case 0: return ""
        case 1: return labels[0]
        case 2: return "\(labels[0]) and \(labels[1])"
        default:
            let allButLast = labels.dropLast().joined(separator: ", ")
            return "\(allButLast), and \(labels.last!)"
        }
    }
}
