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
}
