import Foundation

/// Swapping a reel's music for a fresh Jamendo track (#118).
///
/// The swap clears any uploaded audio first, so the regeneration fetches from
/// Jamendo rather than reusing the file already on the event. That clearing was
/// persisted BEFORE the fetch that justified it, and the failure path never put
/// it back.
///
/// So a failed fetch (no network, no JAMENDO_CLIENT_ID) showed an error banner
/// while Dan's own uploaded track had already been unhooked from the event.
/// Retrying then fetched Jamendo instead of using his file, and the file itself
/// became an orphan-sweep candidate on the next launch, because the sweep looks
/// for audio nothing references.
///
/// A failed action must leave the event no worse than it found it.
enum ReelAudioSwap {

    /// The event with this day's uploaded audio cleared, plus what was there,
    /// so the caller can put it back if the fetch fails.
    static func clearingAudio(in event: Event, day: DayName) -> (event: Event, previous: URL?) {
        var updated = event
        var pd = updated.days[day.rawValue] ?? PostingDay(day: day)
        let previous = pd.audioPath
        pd.audioPath = nil
        updated.days[day.rawValue] = pd
        return (updated, previous)
    }

    /// Put back the audio a failed swap cleared.
    ///
    /// Reads the LIVE event rather than the snapshot taken before the fetch:
    /// the swap takes seconds and anything edited meanwhile must survive the
    /// rollback.
    static func restoringAudio(_ previous: URL?, in event: Event, day: DayName) -> Event {
        var updated = event
        var pd = updated.days[day.rawValue] ?? PostingDay(day: day)
        pd.audioPath = previous
        updated.days[day.rawValue] = pd
        return updated
    }

    /// Record which track the swap actually put in the reel (#262).
    ///
    /// Python reported this on every swap and the app read none of it, so a
    /// fetched track was anonymous: Dan could hear the music and had nowhere on
    /// screen to see what it was. Written to the LIVE event for the same reason
    /// as `restoringAudio`.
    static func recording(_ result: PythonBridge.ReelAudioSwapResult,
                          in event: Event, day: DayName) -> Event {
        var updated = event
        var pd = updated.days[day.rawValue] ?? PostingDay(day: day)
        pd.reelAudioSource = URL(fileURLWithPath: result.audioSource)
        pd.reelAudioTags = result.tags
        updated.days[day.rawValue] = pd
        return updated
    }

    /// Forget the recorded track for any day whose reel was just re-rendered.
    ///
    /// A fresh render fetches its own music, so the label written by an earlier
    /// manual swap now names a track that is not in the file. Left in place it
    /// is worse than absent: it names something specific, which is exactly what
    /// makes it believable, and clicking it plays audio Dan will not hear when
    /// he posts.
    static func clearingStaleAudioLabels(in event: Event,
                                         freshMedia: [String: [String: String]]?) -> Event {
        guard let freshMedia else { return event }
        var updated = event
        for (dayKey, assets) in freshMedia where assets["reel"] != nil {
            guard var pd = updated.days[dayKey],
                  pd.reelAudioSource != nil || !pd.reelAudioTags.isEmpty else { continue }
            pd.reelAudioSource = nil
            pd.reelAudioTags = ""
            updated.days[dayKey] = pd
        }
        return updated
    }
}
