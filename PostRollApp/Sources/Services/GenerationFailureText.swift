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
    static func summary(day: String, raw: String) -> (text: String, fixable: Bool) {
        let lower = raw.lowercased()

        // ffmpeg / system level issues. Not fixable from the GUI.
        if lower.contains("ffmpeg") {
            return ("ffmpeg isn't installed. Run `brew install ffmpeg` in Terminal, then retry.", false)
        }
        if lower.contains("jamendo") || lower.contains("jamendo_client_id") {
            return ("Couldn't reach Jamendo for background audio. Check your JAMENDO_CLIENT_ID env var or upload your own audio file.", false)
        }

        // Claude API errors, kept distinct from each other. Matches have to be
        // specific enough that an "anthropic" mention in a stack trace is not
        // read as an auth failure.
        if lower.contains("request_too_large") || lower.contains("413") {
            return ("\(dayLabel(day)) sent too much data to Claude in one request. Reduce inputs (fewer photos, shorter notes) and retry.", true)
        }
        if lower.contains("rate_limit") || lower.contains("429") {
            return ("Hit Claude's rate limit. Wait ~30 seconds and retry, no input changes needed.", false)
        }
        if lower.contains("invalid_api_key") || lower.contains("401") || lower.contains("authentication") {
            return ("Claude API key is invalid or missing. Set ANTHROPIC_API_KEY and retry.", false)
        }
        if lower.contains("overloaded_error") || lower.contains("529") {
            return ("Claude is overloaded right now. Wait a minute and retry, no input changes needed.", false)
        }
        if lower.contains("anthropic api error") {
            return ("Claude API error during \(dayLabel(day)). Often resolves on retry.", false)
        }

        // Missing inputs, fixable on the photo assignment screen. The collage
        // floor comes from the live preset rather than a Classic literal: under
        // Balanced a day with its full 4 photos was told it needed 10, which
        // contradicts the app's own generator (#119, #195).
        if let collageDay = DayName(rawValue: day),
           PostingPreset.current.isCollageCarousel(collageDay),
           lower.contains("collage skipped") || lower.contains("collage_min") {
            return (CollagePhotoSelection.generationShortfallHint(day: collageDay), true)
        }
        if day == "tuesday" && (lower.contains("raw") || lower.contains("edited")) {
            return ("Tuesday's before/after reel needs a RAW + edited photo. Assign them and retry.", true)
        }
        if day == "friday" && (lower.contains("raw") || lower.contains("edited")) {
            return ("Friday's before/after story reuses Tuesday's RAW + edited. Assign them on Tuesday and retry.", true)
        }
        if day == "thursday" && lower.contains("photo") && lower.contains("empty") {
            return ("Thursday's scroll reel needs at least one photo. Add photos to Thursday and retry.", true)
        }
        if lower.contains("no such file") || lower.contains("filenotfounderror") {
            return ("A photo or audio file was moved or deleted. Re-assign your photos on the photo screen and retry.", true)
        }

        if lower.contains("story fallback failed") {
            return ("Even the static-image fallback for \(dayLabel(day)) couldn't run. Often fixed by re-uploading the day's photos.", true)
        }

        // No specific summary. The caller shows the raw error verbatim.
        return ("", true)
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
