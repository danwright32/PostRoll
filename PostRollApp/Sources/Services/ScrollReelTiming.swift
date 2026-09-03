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

    // MARK: - How fast it reads (#1066)
    //
    // Dan, 2026-08-30: "in general I think it's too fast though. Is there a
    // warning we can put if it's running too fast?"
    //
    // Every number here is held to `tests/fixtures/scroll_reel_timing.json`,
    // so the sentence the editor shows and the reel the encoder makes cannot
    // describe different speeds.

    /// The frame rate the reel is encoded at, and that Instagram re-encodes to.
    static let fps: Double = 30

    /// How much of the gallery a viewer sees at once. The reading below is
    /// expressed as how long a full screen takes to be replaced, because that
    /// is a quantity a person can picture; pixels per frame is not.
    static let viewportHeight: Double = 1430

    /// How much faster the constant middle of the scroll runs than its average,
    /// since the ends are ramps. The middle is what a viewer is watching.
    static let cruiseFactor: Double = 1.0 / (1.0 - 0.15)

    /// The speed Dan settled on by watching a ladder of ten renders of one
    /// reel on 2026-08-30: 11.50px a frame read as fast, 10.81 read as right.
    static let comfortableTravelPx: Double = 10.81

    /// How far the strip travels in total. A strip no taller than the viewport
    /// does not scroll at all.
    static func scrollTravel(stripHeight: Double) -> Double {
        max(0, stripHeight - viewportHeight)
    }

    /// How far the strip advances between frames, at cruise.
    static func travelPerFrame(stripHeight: Double, scrollSeconds: Double) -> Double {
        guard scrollSeconds > 0 else { return 0 }
        return scrollTravel(stripHeight: stripHeight) / (scrollSeconds * fps) * cruiseFactor
    }

    /// How long the gallery takes to replace one full screen.
    static func secondsPerScreen(stripHeight: Double, scrollSeconds: Double) -> Double {
        let perFrame = travelPerFrame(stripHeight: stripHeight, scrollSeconds: scrollSeconds)
        guard perFrame > 0 else { return .infinity }
        return viewportHeight / perFrame / fps
    }

    /// The scroll length that would bring this strip to the comfortable speed.
    static func comfortableScrollSeconds(stripHeight: Double) -> Double {
        let travel = scrollTravel(stripHeight: stripHeight)
        guard travel > 0 else { return 0 }
        return travel * cruiseFactor / (fps * comfortableTravelPx)
    }

    /// Roughly how many photographs would reach the comfortable speed at this
    /// length, given how tall the ones already chosen made the strip.
    ///
    /// Approximate, and deliberately so: the masonry layout is Python's and
    /// the exact height of a different photo set cannot be known here. The
    /// strip's height per photograph is taken from the set in hand, which is
    /// the same estimate #1066 used to arrive at its own figure, and it is
    /// offered as a number to aim at rather than a promise.
    static func comfortablePhotoCount(stripHeight: Double, photoCount: Int,
                                      scrollSeconds: Double) -> Int {
        guard photoCount > 0, scrollSeconds > 0, stripHeight > 0 else { return 0 }
        let perPhoto = stripHeight / Double(photoCount)
        let allowedTravel = comfortableTravelPx * scrollSeconds * fps / cruiseFactor
        let allowedStrip = allowedTravel + viewportHeight
        return max(1, Int((allowedStrip / perPhoto).rounded(.down)))
    }

    /// One sentence when the reel is faster than is comfortable to watch, else
    /// nil. A warning only: Dan may well want a fast one deliberately, and this
    /// blocks no render and changes no reel.
    ///
    /// It names BOTH remedies with real numbers, and which one it leads with is
    /// decided by whether the slider can actually reach the answer. At 234
    /// photographs the slider's 60 second maximum still leaves the reel faster
    /// than one Dan had already called too fast, so naming only the duration
    /// would point at a control that cannot solve the problem (L80, L111).
    static func speedNotice(stripHeight: Double, photoCount: Int,
                            scrollSeconds: Double) -> String? {
        guard photoCount > 0, scrollSeconds > 0 else { return nil }
        let perFrame = travelPerFrame(stripHeight: stripHeight, scrollSeconds: scrollSeconds)
        guard perFrame > comfortableTravelPx else { return nil }

        let screen = secondsPerScreen(stripHeight: stripHeight, scrollSeconds: scrollSeconds)
        let opening = String(
            format: "This reel replaces the whole screen every %.1f seconds, "
                  + "which is faster than is comfortable to watch. ", screen)

        let needed = comfortableScrollSeconds(stripHeight: stripHeight)
        if needed <= sliderMaximumSeconds {
            return opening + "Try \(Int(needed.rounded())) seconds."
        }

        let fewer = comfortablePhotoCount(stripHeight: stripHeight,
                                          photoCount: photoCount,
                                          scrollSeconds: sliderMaximumSeconds)
        return opening
            + "Even at \(Int(sliderMaximumSeconds)) seconds it would still be too "
            + "fast, so this one needs about \(fewer) photographs rather than "
            + "\(photoCount)."
    }

    /// The longest scroll the editor offers, from the reel length presets.
    /// Named here because the notice's choice of remedy turns on it.
    static let sliderMaximumSeconds: Double = 60

    // MARK: - Watching the pace (#1071)
    //
    // There was no way to see a Thursday reel MOVE without rendering the whole
    // thing. On 2026-08-30 Dan settled the comfortable scroll speed by having
    // ten complete reels rendered at 50 to 160 seconds each and opening them in
    // QuickTime, roughly forty minutes to answer one question, and every reel
    // with an unusual photo count poses it again.
    //
    // The numbers below come from the same travel and cruise factor the encoder
    // walks. A preview that moved at its own speed would be worse than none,
    // because it would be trusted.

    /// How long a pace sample runs.
    ///
    /// At the comfortable speed a full screen is replaced every 4.4 seconds, so
    /// a shorter sample would show a slice of movement rather than the thing
    /// being judged. Long enough to see a screen go by twice, short enough that
    /// judging the pace is not itself a wait.
    static let paceSampleSeconds: Double = 9

    /// The sample shows a VIEWPORT-shaped window of the strip, not the whole
    /// strip scaled down: the speed a viewer sees is pixels against the
    /// viewport, and a scaled whole strip moves at a completely different one.
    static let paceWindowHeight: Double = viewportHeight

    /// How fast the strip moves through that window, in canvas pixels a second,
    /// at cruise. The ramps at each end are not sampled: cruise is where the
    /// reel spends its time and what "too fast" was reported about.
    static func cruisePixelsPerSecond(stripHeight: Double, scrollSeconds: Double) -> Double {
        travelPerFrame(stripHeight: stripHeight, scrollSeconds: scrollSeconds) * fps
    }
}
