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
    /// Text export finished and the folder is open, while assets are still
    /// being written in the background ("Skip, text export only"). Its own
    /// state rather than a reuse of `exporting`, because that one flag also
    /// decided whether Done could dismiss the run, so the sidebar contradicted
    /// the pane and Done did nothing (#182, L53).
    case finishingMedia
    case awaitingGeneration
    case awaitingExport
    case stage(EventStage)

    /// Every state the pill can be in, including one per stage.
    ///
    /// The pill is coloured per state and its label is drawn on a wash of that
    /// same colour, so the legibility of each one is its own measurement rather
    /// than something the family can be judged on from a single sample (#582).
    /// Derived from `EventStage.allCases` rather than listed again, because a
    /// hand-written copy is exactly the entry a new stage would be missing from
    /// while the walk still reported a clean run (L96).
    static var allPillStates: [StagePillState] {
        [.reading, .readingFailed, .generating, .generationFailed,
         .exporting, .finishingMedia, .awaitingGeneration, .awaitingExport]
        + EventStage.allCases.map { .stage($0) }
    }

    /// True for any in-flight background work — drives the pulsing dot.
    var isBusy: Bool {
        switch self {
        case .reading, .generating, .exporting, .finishingMedia: return true
        default: return false
        }
    }

    /// Which state the pill is in, from the event and the live work.
    ///
    /// - Parameter awaitingGeneration: `stage` has advanced to
    ///   `.assetsGenerated` purely to open the generation screen, with no
    ///   assets yet (`weekResult == nil`). The `stage` field doubles as a
    ///   navigation router, so it flips the moment "Continue to Generation" is
    ///   pressed; without this the pill would claim "Assets Generated" before
    ///   anything was generated.
    /// - Parameter awaitingExport: `stage` is `.exported` while the export has
    ///   not run (no `exportPath` or `archivedAt`). The same guard for the same
    ///   reason: opening the Export screen must not make the pill claim the
    ///   folder is written.
    static func resolve(stage: EventStage,
                        isGenerating: Bool,
                        generationFailed: Bool,
                        isReading: Bool = false,
                        readingFailed: Bool = false,
                        isExporting: Bool = false,
                        isFinishingMedia: Bool = false,
                        awaitingGeneration: Bool,
                        awaitingExport: Bool) -> StagePillState {
        // Live work first (most informative), then failures, then static labels.
        if isGenerating { return .generating }
        if isReading { return .reading }
        if isExporting { return .exporting }
        // After exporting, so a run genuinely still in flight wins.
        if isFinishingMedia { return .finishingMedia }
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
        case .finishingMedia:     return "Finishing assets…"
        case .awaitingGeneration: return "Ready to Generate"
        case .awaitingExport:     return "Ready to Export"
        case .stage(let s):       return s.displayLabel
        }
    }
}
