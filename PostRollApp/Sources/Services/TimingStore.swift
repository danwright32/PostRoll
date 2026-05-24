import Foundation

/// Persists a rolling window of past OCR and generation durations so the UI
/// can show accurate time estimates instead of hardcoded guesses.
final class TimingStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = TimingStore()
    private let key = "postroll.timings.v2"
    private let maxSamples = 5

    private struct Timings: Codable {
        var ocr: [Double] = []          // seconds
        var generation: [Double] = []   // seconds (total)
        var captions: [Double] = []     // seconds
        var blog: [Double] = []         // seconds
        var packaging: [Double] = []    // seconds
        var mediaExport: [Double] = []  // seconds (export-time visual asset run)

        init() {}

        enum CodingKeys: String, CodingKey {
            case ocr, generation, captions, blog, packaging, mediaExport
        }

        // decodeIfPresent on every field so adding a new track (mediaExport)
        // doesn't fail to decode older stored JSON and wipe existing history.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ocr         = try c.decodeIfPresent([Double].self, forKey: .ocr)         ?? []
            generation  = try c.decodeIfPresent([Double].self, forKey: .generation)  ?? []
            captions    = try c.decodeIfPresent([Double].self, forKey: .captions)    ?? []
            blog        = try c.decodeIfPresent([Double].self, forKey: .blog)        ?? []
            packaging   = try c.decodeIfPresent([Double].self, forKey: .packaging)   ?? []
            mediaExport = try c.decodeIfPresent([Double].self, forKey: .mediaExport) ?? []
        }
    }

    private var timings: Timings {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(Timings.self, from: data)
            else { return Timings() }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private init() {}

    func recordOCR(seconds: Double) {
        var t = timings
        t.ocr.append(seconds)
        if t.ocr.count > maxSamples { t.ocr.removeFirst() }
        timings = t
    }

    func recordGeneration(seconds: Double) {
        var t = timings
        t.generation.append(seconds)
        if t.generation.count > maxSamples { t.generation.removeFirst() }
        timings = t
    }

    /// Record the wall-clock duration of an export-time visual asset run.
    /// Only the copy-only common case is recorded by the caller, so the mean
    /// stays meaningful (Python regen runs are estimated separately).
    func recordMediaExport(seconds: Double) {
        var t = timings
        t.mediaExport.append(seconds)
        if t.mediaExport.count > maxSamples { t.mediaExport.removeFirst() }
        timings = t
    }

    /// Record per-phase timings from a completed generation run.
    /// Pass nil for any phase that didn't run (e.g. no blog photos).
    func recordGenerationPhases(captions: Double?, blog: Double?, packaging: Double?) {
        var t = timings
        if let c = captions {
            t.captions.append(c)
            if t.captions.count > maxSamples { t.captions.removeFirst() }
        }
        if let b = blog {
            t.blog.append(b)
            if t.blog.count > maxSamples { t.blog.removeFirst() }
        }
        if let p = packaging {
            t.packaging.append(p)
            if t.packaging.count > maxSamples { t.packaging.removeFirst() }
        }
        timings = t
    }

    /// Rolling mean of OCR durations, or nil if no history yet.
    var ocrEstimate: Double? {
        let s = timings.ocr
        return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
    }

    /// Rolling mean of total generation durations, or nil if no history yet.
    var generationEstimate: Double? {
        let s = timings.generation
        return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
    }

    var captionsMean: Double?  { mean(timings.captions) }
    var blogMean: Double?      { mean(timings.blog) }
    var packagingMean: Double? { mean(timings.packaging) }

    /// Rolling mean of copy-only export-time media runs, or nil if no history.
    var mediaExportEstimate: Double? { mean(timings.mediaExport) }

    private func mean(_ arr: [Double]) -> Double? {
        arr.isEmpty ? nil : arr.reduce(0, +) / Double(arr.count)
    }

    // MARK: - Generation phase timeline

    /// Baseline phase table — used when no timing history exists.
    static let defaultGenerationPhases: [(name: String, startsAt: Int)] = [
        ("Reading program & photos", 0),
        ("Matching photo captions",  30),
        ("Writing captions",         75),
        ("Drafting blog post",       180),
        ("Packaging output",         330),
    ]

    /// Returns a phase table scaled to actual measured per-phase durations.
    /// Falls back to proportional scaling from total estimate, then to defaults.
    func scaledGenerationPhases() -> [(name: String, startsAt: Int)] {
        let t = timings

        // If we have per-phase data, build precise start times
        if let captionsMean = mean(t.captions),
           let blogMean     = mean(t.blog),
           let packMean     = mean(t.packaging) {
            // "Reading + matching": we attribute a setup overhead (~15% of captions)
            let setup       = captionsMean * 0.15
            let matchStart  = Int(setup.rounded())
            let writeStart  = Int((setup + captionsMean * 0.40).rounded())
            let blogStart   = Int((setup + captionsMean).rounded())
            let packStart   = Int((setup + captionsMean + blogMean).rounded())
            _ = packMean  // used implicitly via total; suppress unused warning
            return [
                ("Reading program & photos", 0),
                ("Matching photo captions",  matchStart),
                ("Writing captions",         writeStart),
                ("Drafting blog post",        blogStart),
                ("Packaging output",          packStart),
            ]
        }

        // Fall back to proportional scaling from total estimate
        if let est = mean(t.generation) {
            let base  = Double(Self.defaultGenerationPhases.last?.startsAt ?? 330)
            let scale = est / base
            return Self.defaultGenerationPhases.map {
                ($0.name, Int((Double($0.startsAt) * scale).rounded()))
            }
        }

        return Self.defaultGenerationPhases
    }

    // MARK: - Formatting helpers

    static func formatEstimate(_ seconds: Double) -> String {
        if seconds < 90 {
            return "~\(Int(seconds.rounded())) sec"
        }
        let m = Int((seconds / 60).rounded())
        return "~\(m) min"
    }

    static func formatClock(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "~%d:%02d", m, s)
    }
}
