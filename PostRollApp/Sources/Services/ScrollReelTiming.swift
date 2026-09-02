import Foundation

/// How long the Thursday reel is, and what to say when the music will not
/// cover it (#1076).
///
/// Pure, so the answers can be checked without rendering anything, and held to
/// `tests/fixtures/scroll_reel_timing.json` by `ScrollReelTimingTests` so these
/// numbers cannot drift from the ones `generate_reel_scroll.py` renders with.
/// That is the split that put an 8px gutter in the collage editor against
/// Python's 16 (#969).
enum ScrollReelTiming {
    /// The hold at the bottom of the scroll, and the closing frame after it.
    /// `HOLD_END` and `CLOSING_FRAME_DURATION` in generate_reel_scroll.py.
    static let holdEndSeconds: Double = 1.0
    static let closingFrameSeconds: Double = 5.0

    /// How long the finished reel is, for the scroll length on the slider.
    ///
    /// The distinction the notice below rests on. A reel is the scroll a person
    /// chose PLUS the holds, so a track that comfortably covers the slider
    /// value can still be six seconds short of the reel, and that is the case
    /// somebody is most likely to think is fine.
    static func reelSeconds(scrollSeconds: Double) -> Double {
        scrollSeconds + holdEndSeconds + closingFrameSeconds
    }

    /// One sentence when the chosen track will not cover the reel, else nil.
    ///
    /// `fit_audio_to_duration` loops a short track with crossfaded seams, which
    /// is the right thing to do and used to be done in silence. The pipeline
    /// reports it now, but only once a render has happened; this answers before
    /// Dan waits for one, which is when the remedy is still cheap.
    ///
    /// A nil `trackSeconds` says nothing rather than warning. It means the
    /// length is not known, usually because no track has been chosen and the
    /// run will fetch one from Jamendo, and warning on that would fire on
    /// almost every reel (L36, L11).
    static func musicNotice(trackSeconds: Double?, scrollSeconds: Double) -> String? {
        guard let trackSeconds, trackSeconds > 0 else { return nil }
        let reel = reelSeconds(scrollSeconds: scrollSeconds)
        guard trackSeconds < reel else { return nil }
        return "This track is \(Int(trackSeconds.rounded())) seconds and the reel "
            + "is \(Int(reel.rounded())), so the music will repeat to cover the rest."
    }
}
