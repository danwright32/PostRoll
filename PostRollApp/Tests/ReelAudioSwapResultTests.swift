import XCTest

/// #262: what the audio swap reports back is actually read.
///
/// `swap_reel_audio.py` writes `reel`, `audio_source` and `tags`. The app read
/// only `audio_source`, and both call sites discarded even that with `_ =`, so
/// the Jamendo track that ended up in the reel was anonymous: Dan could hear it
/// and had no way to see what it was or what it had been matched on.
final class ReelAudioSwapResultTests: XCTestCase {

    func testItReadsAllThreeFieldsPythonReports() throws {
        let parsed = PythonBridge.parseSwapReelAudioOutput([
            "reel": "/data/previews/ev/thursday/reel.mp4",
            "audio_source": "/cache/jamendo/track_1234.mp3",
            "tags": "strings,warm",
        ])
        XCTAssertEqual(parsed?.reelPath, "/data/previews/ev/thursday/reel.mp4")
        XCTAssertEqual(parsed?.audioSource, "/cache/jamendo/track_1234.mp3")
        XCTAssertEqual(parsed?.tags, "strings,warm")
    }

    func testAUsersOwnFileReportsNoTags() throws {
        // Python sends "" rather than a sentinel, so there is no magic word for
        // this side to know. An empty string means "not matched on anything".
        let parsed = PythonBridge.parseSwapReelAudioOutput([
            "reel": "/data/reel.mp4",
            "audio_source": "/Users/dan/Music/my_track.wav",
            "tags": "",
        ])
        XCTAssertEqual(parsed?.tags, "")
        XCTAssertFalse(parsed?.wasMatchedOnTags ?? true,
                       "an uploaded file was not matched on anything, so the app "
                       + "must not offer to show Dan what it was matched on")
    }

    func testAFetchedTrackKnowsItWasMatchedOnTags() {
        let parsed = PythonBridge.parseSwapReelAudioOutput([
            "reel": "/data/reel.mp4", "audio_source": "/cache/t.mp3", "tags": "piano,calm",
        ])
        XCTAssertTrue(parsed?.wasMatchedOnTags ?? false)
    }

    func testAResultMissingTheReelPathIsRefused() {
        // The reel path is what the player reloads. Guessing it would point the
        // player at a file this run may not have written.
        XCTAssertNil(PythonBridge.parseSwapReelAudioOutput([
            "audio_source": "/cache/t.mp3", "tags": "x",
        ]))
    }

    func testAResultMissingTheAudioSourceIsRefused() {
        XCTAssertNil(PythonBridge.parseSwapReelAudioOutput([
            "reel": "/data/reel.mp4", "tags": "x",
        ]))
    }

    func testMissingTagsDecodeAsEmptyRatherThanFailing() {
        // A payload from an older build has no `tags` at all. That is not a
        // failed swap, and refusing it would break a working feature over a
        // field that only decorates it.
        let parsed = PythonBridge.parseSwapReelAudioOutput([
            "reel": "/data/reel.mp4", "audio_source": "/cache/t.mp3",
        ])
        XCTAssertEqual(parsed?.tags, "")
        XCTAssertNotNil(parsed)
    }

    func testGarbageValuesAreRefusedRatherThanCoerced() {
        XCTAssertNil(PythonBridge.parseSwapReelAudioOutput([
            "reel": 42, "audio_source": "/cache/t.mp3",
        ]))
    }
}
