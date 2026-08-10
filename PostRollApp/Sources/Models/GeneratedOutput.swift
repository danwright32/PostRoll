import Foundation

// MARK: - Per-day caption result (mirrors Python generate_captions output)

struct DayCaption: Codable, Hashable {
    var caption: String = ""
    var hashtags: [String] = []
    var altTexts: [String] = []
    var sceneLabels: [String?] = []
    /// The caption exactly as it came out of generation — never overwritten by edits.
    /// Empty until `WeekGenerationResult.stampOriginals()` is called after first decode.
    var generatedCaption: String = ""

    enum CodingKeys: String, CodingKey {
        case caption, hashtags
        case altTexts         = "alt_texts"
        case sceneLabels      = "scene_labels"
        case generatedCaption = "generated_caption"
    }

    /// Caption + hashtags as a ready-to-paste string.
    var formatted: String {
        let tags = hashtags.joined(separator: " ")
        guard !tags.isEmpty else { return caption }
        guard !caption.isEmpty else { return tags }
        // Don't append if the hashtags are already the last non-empty line of the caption
        let lastLine = caption
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        if lastLine == tags { return caption }
        return "\(caption)\n\n\(tags)"
    }

    var wasEdited: Bool {
        !generatedCaption.isEmpty && caption != generatedCaption
    }
}

// MARK: - Blog post result (mirrors Python generate_blog output)

/// One deterministic blog check that fired (#201). These report rather than
/// rewrite: nobody can supply the true number that replaces an invented one,
/// and alt text cannot be rewritten without seeing the photograph, so the
/// quoted text is what lets Dan fix it in seconds.
struct BlogFinding: Codable, Hashable, Identifiable {
    var code: String = ""
    var message: String = ""
    var detail: String = ""

    var id: String { "\(code)|\(detail)" }

    init(code: String = "", message: String = "", detail: String = "") {
        self.code = code
        self.message = message
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code    = try c.decodeIfPresent(String.self, forKey: .code)    ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        detail  = try c.decodeIfPresent(String.self, forKey: .detail)  ?? ""
    }
}

struct BlogOutput: Codable, Hashable {
    var title: String = ""
    var body: String = ""
    var photoCount: Int = 0
    /// Body exactly as generated — never overwritten by edits.
    var generatedBody: String = ""
    /// What the deterministic checks caught (#201).
    var findings: [BlogFinding] = []
    /// The exact body `findings` were measured against.
    ///
    /// Its own field rather than a reuse of `generatedBody`, because the two
    /// answer different questions. `generatedBody` asks "has Dan edited this",
    /// while this asks "do the findings still describe what is on screen". A
    /// photo swap regenerates the markers and re-runs the checks without being
    /// an edit, so inferring one from the other reports fresh findings as stale.
    var findingsBody: String = ""

    enum CodingKeys: String, CodingKey {
        case title, body, findings
        case photoCount    = "photo_count"
        case generatedBody = "generated_body"
        case findingsBody  = "findings_body"
    }

    /// Attach findings from a Python run, pinning the body they describe.
    mutating func applyFindings(_ found: [BlogFinding], checkedBody: String) {
        findings = found
        findingsBody = checkedBody
    }

    var wasEdited: Bool {
        !generatedBody.isEmpty && body != generatedBody
    }
}

// MARK: - Full week result (mirrors Python generate_week output)

struct WeekGenerationResult: Codable, Hashable {
    var sunday: DayCaption?
    var monday: DayCaption?
    var tuesday: DayCaption?
    var wednesday: DayCaption?
    var thursday: DayCaption?
    var friday: DayCaption?
    var blog: BlogOutput?
    var errors: [String: String] = [:]
    /// Days that generated but have something worth saying, keyed by day name
    /// (#228). Separate from `errors`: these days produced usable captions, and
    /// putting them in the same field as a failure would either make a good day
    /// look broken or hide a real error behind a warning.
    var warnings: [String: [SkippedPhoto]] = [:]
    /// Why the run stopped before finishing, when it did (#257).
    ///
    /// Written by `generate_week` on every halt, alongside everything that had
    /// finished. A halted week is not a failed one: the days below are real.
    /// Read through `HaltedWeek`, which turns it into the state and the two
    /// ways forward.
    var stoppedReason: String? = nil

    /// Declared rather than synthesised: Python writes snake_case, and a
    /// synthesised `stoppedReason` key would decode to nil against a file that
    /// really does carry the halt. That mismatch is silent, which would put the
    /// field straight back to being written and never read.
    enum CodingKeys: String, CodingKey {
        case sunday, monday, tuesday, wednesday, thursday, friday
        case blog, errors, warnings
        case stoppedReason = "stopped_reason"
    }

    subscript(day: DayName) -> DayCaption? {
        get {
            switch day {
            case .sunday:    return sunday
            case .monday:    return monday
            case .tuesday:   return tuesday
            case .wednesday: return wednesday
            case .thursday:  return thursday
            case .friday:    return friday
            }
        }
        set {
            switch day {
            case .sunday:    sunday    = newValue
            case .monday:    monday    = newValue
            case .tuesday:   tuesday   = newValue
            case .wednesday: wednesday = newValue
            case .thursday:  thursday  = newValue
            case .friday:    friday    = newValue
            }
        }
    }

    /// True when the run produced at least one caption (or blog), regardless
    /// of whether other days errored. Used to gate timing-store updates so a
    /// run that fails immediately and produces nothing doesn't skew the
    /// rolling-mean estimate downward.
    var hasAnyContent: Bool {
        blog != nil || DayName.allCases.contains { self[$0] != nil }
    }

    var daysWithContent: [DayName] {
        DayName.allCases.filter { self[$0] != nil }
    }

    var errorCount: Int { errors.count }

    /// One line naming the photos this day left out, or nil when there were
    /// none. Nil rather than an empty string so a caller cannot render an empty
    /// banner on every ordinary day, which is how a real warning gets ignored.
    func warningMessage(for day: DayName) -> String? {
        let skipped = warnings[day.rawValue] ?? []
        guard !skipped.isEmpty else { return nil }
        let names = skipped.map(\.file).joined(separator: ", ")
        let subject = skipped.count == 1 ? "photo" : "photos"
        return "Skipped \(skipped.count) unreadable \(subject) (\(names)). "
             + "This day's caption and alt text were written from the rest, so "
             + "check whether those files open."
    }

    /// Copy `caption` → `generatedCaption` and `body` → `generatedBody` for any
    /// day/blog that hasn't been stamped yet. Call once after decoding from Python output.
    mutating func stampOriginals() {
        for day in DayName.allCases {
            guard var cap = self[day], cap.generatedCaption.isEmpty else { continue }
            cap.generatedCaption = cap.caption
            self[day] = cap
        }
        if var b = blog, b.generatedBody.isEmpty {
            b.generatedBody = b.body
            blog = b
        }
    }
}

// MARK: - Backward-compatible decoding (decodeIfPresent so new fields don't break old saves)

extension DayCaption {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caption          = try c.decodeIfPresent(String.self,    forKey: .caption)          ?? ""
        hashtags         = try c.decodeIfPresent([String].self,  forKey: .hashtags)         ?? []
        altTexts         = try c.decodeIfPresent([String].self,  forKey: .altTexts)         ?? []
        sceneLabels      = try c.decodeIfPresent([String?].self, forKey: .sceneLabels)      ?? []
        generatedCaption = try c.decodeIfPresent(String.self,    forKey: .generatedCaption) ?? ""
    }
}

extension BlogOutput {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title         = try c.decodeIfPresent(String.self, forKey: .title)         ?? ""
        body          = try c.decodeIfPresent(String.self, forKey: .body)          ?? ""
        photoCount    = try c.decodeIfPresent(Int.self,    forKey: .photoCount)    ?? 0
        generatedBody = try c.decodeIfPresent(String.self, forKey: .generatedBody) ?? ""
        findings      = try c.decodeIfPresent([BlogFinding].self, forKey: .findings) ?? []
        findingsBody  = try c.decodeIfPresent(String.self, forKey: .findingsBody) ?? ""
    }
}

extension WeekGenerationResult {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sunday    = try c.decodeIfPresent(DayCaption.self, forKey: .sunday)
        monday    = try c.decodeIfPresent(DayCaption.self, forKey: .monday)
        tuesday   = try c.decodeIfPresent(DayCaption.self, forKey: .tuesday)
        wednesday = try c.decodeIfPresent(DayCaption.self, forKey: .wednesday)
        thursday  = try c.decodeIfPresent(DayCaption.self, forKey: .thursday)
        friday    = try c.decodeIfPresent(DayCaption.self, forKey: .friday)
        blog      = try c.decodeIfPresent(BlogOutput.self,            forKey: .blog)
        errors    = try c.decodeIfPresent([String: String].self,      forKey: .errors)    ?? [:]
        warnings  = try c.decodeIfPresent([String: [SkippedPhoto]].self, forKey: .warnings) ?? [:]
        stoppedReason = try c.decodeIfPresent(String.self, forKey: .stoppedReason)
    }
}

/// A photo left out of a day's caption call because the file could not be read
/// (#228). Carries the filename so the warning is actionable.
struct SkippedPhoto: Codable, Hashable {
    var file: String = ""
    var reason: String = ""

    enum CodingKeys: String, CodingKey { case file, reason }

    init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file   = try c.decodeIfPresent(String.self, forKey: .file)   ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

// MARK: - GeneratedOutput (kept for future per-field editing in Step 5)

struct GeneratedOutput: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var suggestedText: String
    var finalText: String?
    var createdAt: Date = Date()

    var displayText: String { finalText ?? suggestedText }
    var hasFinal: Bool { finalText != nil }
}
