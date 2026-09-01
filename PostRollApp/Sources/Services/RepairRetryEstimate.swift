import Foundation

/// How long a retry of N alt text markers should take (#1164).
///
/// The retry control shipped with `estimate: "~1 min"`, a constant, sitting
/// next to `CALL_TIMEOUT` in `postroll/ai/blog_repair.py` which carries the
/// reading it came from. An unmeasured number beside measured ones reads as one
/// of them, and this one was chosen.
///
/// The estimate is one of the three states `LongRunIndicator` exists to keep
/// apart: started, still alive, stalled. A constant written for one marker
/// makes a healthy five marker retry look stalled, which is the failure the
/// indicator was built to prevent.
///
/// ## What it is derived from
///
/// Every number here is measured, and every one of them is re-measurable:
///
/// * the per call cost, from `tests/fixtures/alt_text_call_timing.json`, three
///   real image-carrying calls on 2026-09-01 at 2.8s, 3.1s and 3.1s.
///   Re-measure with `venv/bin/python tools/measure_alt_text_call.py --photo <a photograph>`.
/// * the round budget, `MAX_ROUNDS` in `postroll/ai/blog_repair.py`, which is
///   the number of attempts the pass actually makes per marker.
/// * the fixed cost of starting the run, measured 2026-09-01 on this Mac: five
///   runs of `venv/bin/python -c "import postroll.ai.retry_blog_repair"` at
///   0.80s cold and 0.31s to 0.45s warm. The cold reading is the one carried,
///   because a person pressing Retry after a while is the cold case.
///
/// `RepairRetryEstimateTests` holds each of these to its source, so a reading
/// that moves and a constant that does not is caught rather than shipped.
///
/// ## Why a range and not one number
///
/// The readings give a fastest and a slowest, and the pass makes between one
/// and `MAX_ROUNDS` calls per marker depending on whether the first rewrite
/// lands. Quoting the midpoint would hide both facts behind a number that is
/// wrong in both directions. The range is what was measured, so the range is
/// what it says, in the same idiom as the other estimates on this panel
/// ("~2 to 5 min").
enum RepairRetryEstimate {

    /// The fastest of the recorded answered readings. Pinned to the fixture.
    static let fastestCallSeconds: Double = 2.8

    /// The slowest of them. The upper bound is built on this rather than the
    /// median, because the harm is asymmetric in the same way `CALL_TIMEOUT`
    /// reasons about: an estimate that is generous costs a run finishing early,
    /// and one that is tight makes a healthy run read as stalled.
    static let slowestCallSeconds: Double = 3.1

    /// Attempts per marker. Pinned to `MAX_ROUNDS` on the Python side, which
    /// owns it.
    static let roundsPerMarker: Int = 2

    /// Launching the interpreter and importing the retry module.
    static let startupSeconds: Double = 0.8

    /// Above this the range is quoted in minutes. Below it, seconds are the
    /// unit a person can actually hold against a clock.
    private static let minutesAbove: TimeInterval = 90

    /// The fastest and slowest this retry should take, or nil when there is
    /// nothing to retry.
    ///
    /// nil rather than zero: the control is only shown when markers can be
    /// retried, and an estimate for work that will not happen is a number about
    /// nothing.
    static func bounds(markerCount: Int) -> ClosedRange<TimeInterval>? {
        guard markerCount > 0 else { return nil }
        let markers = Double(markerCount)
        // Worst case: every marker needing the full round budget.
        let worst = startupSeconds + slowestCallSeconds * markers * Double(roundsPerMarker)
        // Best case: every marker fixed on its first round, and never above the
        // worst case. Held there rather than trusted to be there, because a
        // closed range TRAPS when the ends cross, and this is built inside a
        // view: a pair of readings that disagreed would take the whole app down
        // rather than show a wrong number. Found by the guard prover, whose
        // mutation crossed them and crashed the test process instead of failing
        // it (a crash reports as 0 tests executed, not as a red test).
        let best = min(startupSeconds + fastestCallSeconds * markers, worst)
        return best...worst
    }

    /// The range as the indicator shows it, or nil when there is nothing to
    /// retry.
    static func text(markerCount: Int) -> String? {
        guard let bounds = bounds(markerCount: markerCount) else { return nil }

        if bounds.upperBound >= minutesAbove {
            let low = max(1, Int(bounds.lowerBound / 60.0))
            let high = Int(ceil(bounds.upperBound / 60.0))
            return "~\(low) to \(max(high, low + 1)) min"
        }
        // Rounded outward to the nearest five seconds, never inward: a range
        // that has been tightened by rounding is no longer the range that was
        // measured.
        let low = max(5, Int((bounds.lowerBound / 5.0).rounded(.down)) * 5)
        let high = Int((bounds.upperBound / 5.0).rounded(.up)) * 5
        return "~\(low) to \(max(high, low + 5)) sec"
    }
}
