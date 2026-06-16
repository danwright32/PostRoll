import Foundation

/// What the sidebar stage pill should announce, as a pure value type so the
/// precedence rule can be unit-tested independently of the view and its colors.
///
/// A live background run (now owned by GenerationManager, surviving event
/// switches) takes priority over the static stage-derived labels: the pill must
/// read "Generating…" while a run is in flight and "Needs Attention" if one
/// failed in the background, rather than the stale "Ready to Generate" /
/// "Assets Generated" the `stage` field alone would imply.
enum StagePillState: Equatable {
    case reading            // OCR in flight
    case readingFailed
    case generating
    case generationFailed
    case exporting          // export in flight
    case awaitingGeneration
    case awaitingExport
    case stage(EventStage)

    /// True for any in-flight background work — drives the pulsing dot.
    var isBusy: Bool {
        switch self {
        case .reading, .generating, .exporting: return true
        default: return false
        }
    }

    static func resolve(stage: EventStage,
                        isGenerating: Bool,
                        generationFailed: Bool,
                        isReading: Bool = false,
                        readingFailed: Bool = false,
                        isExporting: Bool = false,
                        awaitingGeneration: Bool,
                        awaitingExport: Bool) -> StagePillState {
        // Live work first (most informative), then failures, then static labels.
        if isGenerating { return .generating }
        if isReading { return .reading }
        if isExporting { return .exporting }
        if generationFailed { return .generationFailed }
        if readingFailed { return .readingFailed }
        if awaitingGeneration { return .awaitingGeneration }
        if awaitingExport { return .awaitingExport }
        return .stage(stage)
    }

    var label: String {
        switch self {
        case .reading:            return "Reading…"
        case .readingFailed:      return "Needs Attention"
        case .generating:         return "Generating…"
        case .generationFailed:   return "Needs Attention"
        case .exporting:          return "Exporting…"
        case .awaitingGeneration: return "Ready to Generate"
        case .awaitingExport:     return "Ready to Export"
        case .stage(let s):       return s.displayLabel
        }
    }
}
