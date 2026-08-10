import XCTest

/// #262: the recorded reel track must not outlive the reel it describes.
///
/// A manual audio swap records which track landed in the reel so the music has
/// a name on screen. A later graphics run renders a brand new reel and fetches
/// its own track, and nothing on that path touched the recorded label, so the
/// strip went on naming a file that was no longer in the video. That is worse
/// than showing nothing: it names something specific, which is what makes it
/// believable, and clicking it plays audio Dan will not hear when he posts.
final class StaleAudioLabelTests: XCTestCase {

    private func event(withRecordedAudioOn days: [DayName]) -> Event {
        var ev = Event(name: "Show", org: "Org", venue: "Hall",
                       date: Date(), shootType: .fullShow)
        for day in days {
            var pd = PostingDay(day: day)
            pd.reelAudioSource = URL(fileURLWithPath: "/cache/old_track.mp3")
            pd.reelAudioTags = "strings, orchestral"
            ev.days[day.rawValue] = pd
        }
        return ev
    }

    func testARerenderedReelForgetsTheTrackTheOldOneHad() {
        let ev = event(withRecordedAudioOn: [.thursday])
        let cleared = ReelAudioSwap.clearingStaleAudioLabels(
            in: ev, freshMedia: ["thursday": ["reel": "/p/thursday/reel.mp4"]])

        XCTAssertNil(cleared.days["thursday"]?.reelAudioSource)
        XCTAssertEqual(cleared.days["thursday"]?.reelAudioTags, "")
    }

    func testADayWhoseReelWasNotRerenderedKeepsItsLabel() {
        let ev = event(withRecordedAudioOn: [.thursday, .tuesday])
        let cleared = ReelAudioSwap.clearingStaleAudioLabels(
            in: ev, freshMedia: ["thursday": ["reel": "/p/thursday/reel.mp4"]])

        XCTAssertNil(cleared.days["thursday"]?.reelAudioSource)
        XCTAssertNotNil(cleared.days["tuesday"]?.reelAudioSource,
                        "Tuesday's reel was not touched, so its track is still in it")
    }

    func testRenderingSomethingOtherThanAReelLeavesTheLabelAlone() {
        // A collage-only re-render does not change the reel's audio.
        let ev = event(withRecordedAudioOn: [.thursday])
        let cleared = ReelAudioSwap.clearingStaleAudioLabels(
            in: ev, freshMedia: ["thursday": ["story": "/p/thursday/story.png"]])
        XCTAssertNotNil(cleared.days["thursday"]?.reelAudioSource)
    }

    func testARunThatRenderedNoGraphicsChangesNothing() {
        let ev = event(withRecordedAudioOn: [.thursday])
        XCTAssertNotNil(
            ReelAudioSwap.clearingStaleAudioLabels(in: ev, freshMedia: nil)
                .days["thursday"]?.reelAudioSource)
    }

    func testItDoesNotInventDaysThatDoNotExist() {
        let ev = event(withRecordedAudioOn: [.thursday])
        let cleared = ReelAudioSwap.clearingStaleAudioLabels(
            in: ev, freshMedia: ["friday": ["reel": "/p/friday/reel.mp4"]])
        XCTAssertNil(cleared.days["friday"], "no PostingDay existed for Friday")
    }
}
