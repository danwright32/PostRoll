import XCTest

/// Regression coverage for the Wednesday story that stopped generating: the day
/// carried a saved 10 cell collage layout whose `photo_path`s still pointed at
/// the pre MediaReclaim `~/Downloads` originals, while the day's photo set had
/// since been cut to 4 app storage copies. `buildMediaManifest` sent that layout
/// to Python as `cell_layout`, `generate_collage` opened the first (missing)
/// file, and the render died with FileNotFoundError. No collage meant no
/// Wednesday story, and every regen repeated it because the stale override
/// persisted in events.json.
///
/// The contract these tests pin: a saved layout is only usable when it still
/// describes the day's current photo set exactly (one cell per photo, matched
/// after rebasing moved paths by filename). Anything else falls back to the
/// automatic masonry layout instead of feeding a dead path to the renderer.
final class CollageOverrideStalePathsTests: XCTestCase {

    private let storage = "/Users/dan/Library/Application Support/PostRoll/photos"
    private let downloads = "/Users/dan/Downloads/socials/day 4"

    private func cell(_ path: String, _ y: Int = 0) -> CollageCell {
        let json = """
        {"photo_path":"\(path)","x":40,"y":\(y),"w":1000,"h":387}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(CollageCell.self, from: json)
    }

    private func photos(_ names: [String], in dir: String) -> [URL] {
        names.map { URL(fileURLWithPath: "\(dir)/\($0)") }
    }

    // MARK: - usable(_:forPhotos:)

    func testStaleOverrideWithMoreCellsThanPhotosIsUnusable() {
        // The reported bug, reduced: 10 cells left over from the classic 10 photo
        // Wednesday, 4 photos now assigned. Six cells name files that are not in
        // the day's photo set at all, so the layout cannot be honoured.
        let cells = ["11", "46", "60", "68", "71", "84", "150", "156", "93", "116"]
            .enumerated().map { cell("\(downloads)/photo-\($1).jpg", $0 * 100) }
        let current = photos(["photo-11.jpg", "photo-60.jpg", "photo-68.jpg", "photo-116.jpg"], in: storage)

        XCTAssertNil(CollageCell.usable(cells, forPhotos: current),
                     "a layout naming photos the day no longer has must not reach the renderer")
    }

    func testMovedPathsAreRebasedAndTheLayoutStaysUsable() {
        // MediaReclaim copied the originals into app storage and rewrote the
        // day's photoPaths. Same photos, same count, only the directory changed:
        // the layout is still valid once rebased by filename.
        let cells = [cell("\(downloads)/photo-11.jpg", 0), cell("\(downloads)/photo-60.jpg", 400)]
        let current = photos(["photo-11.jpg", "photo-60.jpg"], in: storage)

        let usable = CollageCell.usable(cells, forPhotos: current)

        XCTAssertEqual(usable?.map(\.photoPath), current.map(\.path))
        XCTAssertEqual(usable?.map(\.y), [0, 400], "rebasing must not disturb the frame geometry")
    }

    func testLayoutMissingOneOfTheDaysPhotosIsUnusable() {
        // Fewer cells than photos: honouring it would silently drop a photo the
        // user assigned, so fall back to the automatic layout instead.
        let cells = [cell("\(storage)/photo-11.jpg"), cell("\(storage)/photo-60.jpg")]
        let current = photos(["photo-11.jpg", "photo-60.jpg", "photo-68.jpg"], in: storage)

        XCTAssertNil(CollageCell.usable(cells, forPhotos: current))
    }

    func testLayoutRepeatingOnePhotoIsUnusable() {
        // Two cells on the same photo means one of the day's photos has no cell.
        let cells = [cell("\(storage)/photo-11.jpg"), cell("\(storage)/photo-11.jpg", 400)]
        let current = photos(["photo-11.jpg", "photo-60.jpg"], in: storage)

        XCTAssertNil(CollageCell.usable(cells, forPhotos: current))
    }

    func testNilEmptyAndPhotolessInputsAreUnusable() {
        let current = photos(["photo-11.jpg"], in: storage)
        XCTAssertNil(CollageCell.usable(nil, forPhotos: current))
        XCTAssertNil(CollageCell.usable([], forPhotos: current))
        XCTAssertNil(CollageCell.usable([cell("\(storage)/photo-11.jpg")], forPhotos: []))
    }

    func testAlreadyCurrentLayoutPassesThroughUnchanged() {
        let cells = [cell("\(storage)/photo-11.jpg"), cell("\(storage)/photo-60.jpg", 400)]
        let current = photos(["photo-11.jpg", "photo-60.jpg"], in: storage)

        XCTAssertEqual(CollageCell.usable(cells, forPhotos: current), cells)
    }

    // MARK: - Manifest wiring (the path that actually broke)

    private func wednesdayEvent(override cells: [CollageCell]?, photos names: [String]) -> Event {
        var event = Event(name: "Spring Concert", org: "Every Voice Choirs",
                          venue: "Merkin Hall", date: Date(timeIntervalSince1970: 0),
                          shootType: .fullShow)
        var day = PostingDay(day: .wednesday)
        day.photoPaths = photos(names, in: storage)
        day.collageCellOverride = cells
        event.days["wednesday"] = day
        return event
    }

    private func cellLayout(in manifest: [String: Any]) -> [[String: Any]]? {
        let days = manifest["days"] as? [String: Any]
        let wednesday = days?["wednesday"] as? [String: Any]
        return wednesday?["cell_layout"] as? [[String: Any]]
    }

    func testManifestOmitsCellLayoutWhenTheSavedOverrideIsStale() async {
        let stale = ["11", "46", "60", "68", "71", "84", "150", "156", "93", "116"]
            .enumerated().map { cell("\(downloads)/photo-\($1).jpg", $0 * 100) }
        let event = wednesdayEvent(override: stale,
                                   photos: ["photo-11.jpg", "photo-60.jpg", "photo-68.jpg", "photo-116.jpg"])

        let manifest = await PythonBridge.shared.buildMediaManifest(event: event)

        XCTAssertNil(cellLayout(in: manifest),
                     "sending a layout with dead paths is what killed the Wednesday collage")
    }

    func testManifestSendsRebasedCellLayoutWhenTheOverrideStillFits() async {
        let cells = [cell("\(downloads)/photo-11.jpg", 0), cell("\(downloads)/photo-60.jpg", 400)]
        let event = wednesdayEvent(override: cells, photos: ["photo-11.jpg", "photo-60.jpg"])

        let manifest = await PythonBridge.shared.buildMediaManifest(event: event)

        XCTAssertEqual(cellLayout(in: manifest)?.compactMap { $0["photo_path"] as? String },
                       ["\(storage)/photo-11.jpg", "\(storage)/photo-60.jpg"],
                       "a still valid layout must be sent with the current photo paths, not the old ones")
    }
}
