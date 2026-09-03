import XCTest

/// #961 left a stale Thursday cover reachable by the export.
///
/// Removing Thursday's cover stopped it being RENDERED, and stopped the panel
/// drawing it. It did not remove the `cover` entry every Thursday generated
/// before that still carries in events.json, and the export does not simply
/// re-render: it copies already approved previews where it can, generically
/// over asset key. So a day that has not been regenerated since would still put
/// a story composite into the folder Dan uploads from, which is the one thing
/// that issue said must not happen.
///
/// Stripped on load rather than at the export, so every reader of
/// `previewMediaPaths` sees the same thing and the stored file is cleaned the
/// next time it is saved. A fix at the copy site would leave the path in the
/// event for the next surface that reads one.
final class RetiredAssetPathsTests: XCTestCase {

    func testThursdayLosesACoverPathItWasStoredWith() {
        let stored = [
            "thursday": ["reel": "/day/reel.mp4", "cover": "/day/cover.png"],
            "friday": ["reel": "/day/f.mp4", "cover": "/day/f_cover.png"],
        ]

        let cleaned = PreviewMergePolicy.withoutRetiredAssets(stored)

        XCTAssertNil(cleaned["thursday"]?["cover"],
                     "the export copies whatever keys a day has, so this reaches the folder")
        XCTAssertEqual(cleaned["thursday"]?["reel"], "/day/reel.mp4",
                       "only the retired asset goes")
    }

    /// Friday's cover is a different post and is not retired. Without this the
    /// check above is satisfied by stripping every cover, which would take a
    /// real asset out of Friday's export (L159).
    func testFridayKeepsItsCover() {
        let stored = ["friday": ["reel": "/day/f.mp4", "cover": "/day/f_cover.png"]]

        XCTAssertEqual(PreviewMergePolicy.withoutRetiredAssets(stored)["friday"]?["cover"],
                       "/day/f_cover.png")
    }

    func testADayWithNothingRetiredIsUnchanged() {
        let stored = [
            "wednesday": ["collage": "/day/c.png", "story": "/day/s.png"],
            "thursday": ["reel": "/day/reel.mp4"],
        ]

        XCTAssertEqual(PreviewMergePolicy.withoutRetiredAssets(stored), stored)
    }

    /// The wiring, not just the helper (L3). An event decoded from a file that
    /// still names a Thursday cover must not carry it, or the fix is a function
    /// nothing calls.
    func testAnEventDecodedFromStorageHasNoThursdayCover() throws {
        let json = """
        {"id":"d6e243e6-504f-49e4-a468-1f38d197a9f5","name":"Test Show","org":"Org","venue":"Hall",
         "date":737000,"shootType":"Performance",
         "previewMediaPaths":{"thursday":{"reel":"/day/reel.mp4","cover":"/day/cover.png"},
                              "friday":{"cover":"/day/f_cover.png"}}}
        """
        let event = try JSONDecoder().decode(Event.self, from: Data(json.utf8))

        XCTAssertNil(event.previewMediaPaths["thursday"]?["cover"])
        XCTAssertEqual(event.previewMediaPaths["thursday"]?["reel"], "/day/reel.mp4")
        XCTAssertEqual(event.previewMediaPaths["friday"]?["cover"], "/day/f_cover.png")
    }
}
