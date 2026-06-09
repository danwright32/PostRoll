import Foundation

/// Speculatively pre-renders the Thursday reel in the background while the user
/// is still editing, so "Apply changes" can adopt an already finished encode
/// instead of waiting 30-60s for ffmpeg.
///
/// The reel is a pure function of five inputs (photo order, audio, scroll
/// duration, layout seed, per-photo crop offsets). We fingerprint those inputs;
/// a pre-render stays valid as long as the fingerprint matches. When a newer
/// edit arrives we SIGTERM the stale encode (via Swift task cancellation, which
/// `PythonBridge.runProcess` forwards to ffmpeg) and start a fresh one.
///
/// Instagram-style: assume the user will apply, start the work early, and just
/// restart if they change something.
@MainActor
final class SpeculativeReelRenderer {
    private let day: DayName

    /// The most recently finished pre-render and the inputs it was built from.
    private var completed: (fingerprint: String, result: PythonBridge.PreviewGenerationResult)?
    /// The render currently encoding (if any) and the inputs it is building.
    private var inFlight: (fingerprint: String, task: Task<PythonBridge.PreviewGenerationResult, Error>)?
    /// Debounce timer so rapid drags/swaps coalesce into one encode.
    private var debounce: Task<Void, Never>?

    private let debounceNanos: UInt64 = 600_000_000  // 0.6s

    init(day: DayName = .thursday) {
        self.day = day
    }

    /// Stable hash of the inputs that determine the rendered reel. Two events
    /// with the same fingerprint produce equivalent output, so a pre-render for
    /// one can be adopted by the other.
    func fingerprint(for event: Event) -> String? {
        guard let pd = event.days[day.rawValue], !pd.photoPaths.isEmpty else { return nil }
        var parts: [String] = []
        parts.append("photos:" + pd.photoPaths.map { $0.path }.joined(separator: "|"))
        parts.append("audio:" + (pd.audioPath?.path ?? "nil"))
        parts.append("dur:" + String(format: "%.3f", pd.scrollDuration))
        parts.append("seed:" + (pd.reelSeed.map(String.init) ?? "nil"))
        let offsets = pd.reelCropOffsets
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.x),\($0.value.y),\($0.value.scale)" }
            .joined(separator: ";")
        parts.append("crops:" + offsets)
        return parts.joined(separator: "\n")
    }

    /// Schedule a speculative render for the current state. Debounced, and a
    /// no-op if we already have (or are already building) this exact state.
    /// Pass a live event snapshot read straight from AppState after `save()`.
    func schedule(for event: Event) {
        guard let fp = fingerprint(for: event) else { return }
        // Already have it, or already building it — nothing to do.
        if completed?.fingerprint == fp { return }
        if inFlight?.fingerprint == fp { return }

        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanos ?? 0)
            guard !Task.isCancelled else { return }
            self?.startRender(for: event, fingerprint: fp)
        }
    }

    private func startRender(for event: Event, fingerprint fp: String) {
        // Re-check: state may have advanced to this fingerprint while debouncing.
        if completed?.fingerprint == fp { return }
        if inFlight?.fingerprint == fp { return }

        // A different render is in flight — cancel it (SIGTERMs ffmpeg) so we
        // don't have two encodes writing the same output file.
        inFlight?.task.cancel()
        // This encode is about to overwrite the shared reel.mp4 in place, so any
        // previously completed render's file is no longer trustworthy. Drop it;
        // if the user returns to that exact state we'll simply re-encode.
        completed = nil

        let task = Task<PythonBridge.PreviewGenerationResult, Error> {
            try await PythonBridge.shared.runPreviewGeneration(
                event: event, days: [day.rawValue]
            )
        }
        inFlight = (fp, task)

        Task { [weak self] in
            let outcome = await task.result
            guard let self else { return }
            // Only record if this render is still the current in-flight one
            // (a newer edit may have superseded it).
            guard self.inFlight?.fingerprint == fp else { return }
            self.inFlight = nil
            if case .success(let result) = outcome, result.errors[self.day.rawValue] == nil {
                self.completed = (fp, result)
            }
        }
    }

    /// If a usable pre-render matches `event`, return it (awaiting an in-flight
    /// encode if needed). Returns nil when there's nothing to adopt, in which
    /// case the caller should render fresh. Cancels any stale, non-matching
    /// in-flight render so it can't collide with the caller's fresh encode.
    func take(matching event: Event) async -> PythonBridge.PreviewGenerationResult? {
        debounce?.cancel()
        guard let fp = fingerprint(for: event) else {
            cancelInFlight()
            return nil
        }

        if let done = completed, done.fingerprint == fp {
            return done.result
        }

        if let flight = inFlight, flight.fingerprint == fp {
            let outcome = await flight.task.result
            if case .success(let result) = outcome, result.errors[day.rawValue] == nil {
                return result
            }
            return nil
        }

        // In-flight render is for stale inputs — kill it before the caller
        // starts a fresh encode to the same output path.
        cancelInFlight()
        return nil
    }

    private func cancelInFlight() {
        inFlight?.task.cancel()
        inFlight = nil
    }

    /// Stop everything (debounce + encode). Call before a fresh render that
    /// writes the same output files, or when tearing down the editor.
    func cancelAll() {
        debounce?.cancel()
        debounce = nil
        cancelInFlight()
    }
}
