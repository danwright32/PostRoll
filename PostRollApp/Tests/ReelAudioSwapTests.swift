import XCTest

/// #118: a failed audio swap must not cost Dan his own uploaded track.
///
/// The swap clears uploaded audio so the regeneration fetches from Jamendo,
/// and that clearing was persisted before the fetch that justified it. A fetch
/// that failed showed an error banner while the uploaded track had already been
/// unhooked, so retrying fetched Jamendo instead of using his file, and the file
/// itself became an orphan-sweep candidate on the next launch.
final class ReelAudioSwapTests: XCTestCase {

    private let track = URL(fileURLWithPath: "/tmp/dans-own-track.mp3")

    private func event(withAudio audio: URL?) -> Event {
        var e = Event(name: "E", org: "O", venue: "V",
                      date: Date(timeIntervalSince1970: 1_700_000_000), shootType: .fullShow)
        var pd = PostingDay(day: .thursday)
        pd.audioPath = audio
        e.days[DayName.thursday.rawValue] = pd
        return e
    }

    func testClearingRemovesTheUploadedTrack() {
        let (cleared, _) = ReelAudioSwap.clearingAudio(in: event(withAudio: track), day: .thursday)

        XCTAssertNil(cleared.days[DayName.thursday.rawValue]?.audioPath)
    }

    func testClearingHandsBackWhatItRemoved() {
        // Without this the failure path has nothing to restore from.
        let (_, previous) = ReelAudioSwap.clearingAudio(in: event(withAudio: track), day: .thursday)

        XCTAssertEqual(previous, track)
    }

    func testRestoringPutsTheTrackBack() {
        let (cleared, previous) = ReelAudioSwap.clearingAudio(in: event(withAudio: track), day: .thursday)

        let restored = ReelAudioSwap.restoringAudio(previous, in: cleared, day: .thursday)

        XCTAssertEqual(restored.days[DayName.thursday.rawValue]?.audioPath, track)
    }

    func testAClearAndRestoreRoundTripLeavesTheEventAsItWas() {
        let original = event(withAudio: track)

        let (cleared, previous) = ReelAudioSwap.clearingAudio(in: original, day: .thursday)
        let restored = ReelAudioSwap.restoringAudio(previous, in: cleared, day: .thursday)

        XCTAssertEqual(restored.days[DayName.thursday.rawValue]?.audioPath,
                       original.days[DayName.thursday.rawValue]?.audioPath)
    }

    func testADayWithNoUploadedAudioRestoresToNothing() {
        // Already on Jamendo audio: a failed swap must not invent a path.
        let (cleared, previous) = ReelAudioSwap.clearingAudio(in: event(withAudio: nil), day: .thursday)
        let restored = ReelAudioSwap.restoringAudio(previous, in: cleared, day: .thursday)

        XCTAssertNil(restored.days[DayName.thursday.rawValue]?.audioPath)
    }

    func testRestoringKeepsAnythingEditedWhileTheSwapWasRunning() {
        // The swap takes seconds and the rollback is applied to the live event,
        // so an edit made meanwhile must survive it.
        let (cleared, previous) = ReelAudioSwap.clearingAudio(in: event(withAudio: track), day: .thursday)
        var edited = cleared
        edited.name = "Renamed while the swap was running"

        let restored = ReelAudioSwap.restoringAudio(previous, in: edited, day: .thursday)

        XCTAssertEqual(restored.name, "Renamed while the swap was running")
        XCTAssertEqual(restored.days[DayName.thursday.rawValue]?.audioPath, track)
    }

    func testOtherDaysAreUntouched() {
        var e = event(withAudio: track)
        var tue = PostingDay(day: .tuesday)
        tue.audioPath = URL(fileURLWithPath: "/tmp/tuesday.mp3")
        e.days[DayName.tuesday.rawValue] = tue

        let (cleared, _) = ReelAudioSwap.clearingAudio(in: e, day: .thursday)

        XCTAssertEqual(cleared.days[DayName.tuesday.rawValue]?.audioPath,
                       URL(fileURLWithPath: "/tmp/tuesday.mp3"))
    }
}
