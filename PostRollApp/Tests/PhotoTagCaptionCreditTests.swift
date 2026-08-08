import XCTest

/// Issue #171: people tagged on an individual carousel photo must also be
/// credited by the caption. Before this, `photoTags` only ever produced the
/// "PHOTO TAGS" block in CAPTIONS.txt and the alt-text prose; the caption's
/// own `tag_handles` / `name_mentions` came exclusively from the day-level
/// performer checkboxes, so tagging a photo credited nobody and Dan had to
/// tick the same person twice.
final class PhotoTagCaptionCreditTests: XCTestCase {

    private func makeEvent(wednesday: PostingDay, performers: [Performer] = []) -> Event {
        var event = Event(name: "Test Show", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        event.ocrResult = OCRResult(performers: performers)
        event.days["wednesday"] = wednesday
        return event
    }

    private func wednesday(photos: [String], tags: [String: [String]]) -> PostingDay {
        var day = PostingDay(day: .wednesday)
        day.photoPaths = photos.map { URL(fileURLWithPath: $0) }
        var byKey: [String: [String]] = [:]
        for (path, names) in tags {
            byKey[URL(fileURLWithPath: path).absoluteString] = names
        }
        day.photoTags = byKey
        return day
    }

    private func manifestDay(_ event: Event) async throws -> [String: Any] {
        let manifest = try await PythonBridge.shared.buildManifest(event: event)
        let days = try XCTUnwrap(manifest["days"] as? [String: Any])
        return try XCTUnwrap(days["wednesday"] as? [String: Any])
    }

    // MARK: - Rollup

    func testPlainNameTaggedOnAPhotoIsCreditedInTheCaption() async throws {
        let event = makeEvent(wednesday: wednesday(
            photos: ["/photos/a.jpg", "/photos/b.jpg"],
            tags: ["/photos/b.jpg": ["Jordan Langworthy"]]
        ))
        let day = try await manifestDay(event)

        let names = day["name_mentions"] as? [String] ?? []
        XCTAssertTrue(names.contains("Jordan Langworthy"),
                      "a plain name tagged on one photo must reach the caption's name_mentions")
        XCTAssertNil(day["tag_handles"], "a plain name must not be sent as an @ handle")
    }

    func testHandleTaggedOnAPhotoIsCreditedAsAHandle() async throws {
        let event = makeEvent(wednesday: wednesday(
            photos: ["/photos/a.jpg"],
            tags: ["/photos/a.jpg": ["@mikebonomusic"]]
        ))
        let day = try await manifestDay(event)

        let handles = day["tag_handles"] as? [String] ?? []
        XCTAssertTrue(handles.contains("@mikebonomusic"),
                      "an @ handle tagged on a photo must reach the caption's tag_handles")
        XCTAssertNil(day["name_mentions"], "an @ handle must not also be sent as a plain name")
    }

    func testTagsFromSeveralPhotosAreAllCredited() async throws {
        let event = makeEvent(wednesday: wednesday(
            photos: ["/photos/a.jpg", "/photos/b.jpg", "/photos/c.jpg"],
            tags: [
                "/photos/a.jpg": ["@onehandle", "Ana Ruiz"],
                "/photos/c.jpg": ["Jane Smith"],
            ]
        ))
        let day = try await manifestDay(event)

        let handles = day["tag_handles"] as? [String] ?? []
        let names = day["name_mentions"] as? [String] ?? []
        XCTAssertEqual(handles, ["@onehandle"])
        XCTAssertEqual(Set(names), Set(["Ana Ruiz", "Jane Smith"]))
    }

    // MARK: - Deduplication

    func testAPersonTaggedOnAPhotoAndTickedAtDayLevelIsCreditedOnce() async throws {
        let performer = Performer(name: "Jane Smith", handle: "@janesmith")
        var day = wednesday(photos: ["/photos/a.jpg"],
                            tags: ["/photos/a.jpg": ["@janesmith"]])
        day.selectedPerformerIDs = [performer.id]
        let event = makeEvent(wednesday: day, performers: [performer])

        let entry = try await manifestDay(event)
        let handles = entry["tag_handles"] as? [String] ?? []
        XCTAssertEqual(handles.filter { $0.lowercased() == "@janesmith" }.count, 1,
                       "the same person picked both ways must be credited once, not twice")
    }

    func testTheSamePersonTaggedOnTwoPhotosIsCreditedOnce() async throws {
        let event = makeEvent(wednesday: wednesday(
            photos: ["/photos/a.jpg", "/photos/b.jpg"],
            tags: [
                "/photos/a.jpg": ["Ana Ruiz"],
                "/photos/b.jpg": ["ana ruiz"],
            ]
        ))
        let day = try await manifestDay(event)

        let names = day["name_mentions"] as? [String] ?? []
        XCTAssertEqual(names.count, 1, "one person across two photos is one credit, matched case-insensitively")
    }

    // MARK: - Degenerate input

    func testBlankAndSentinelTagsAreNotCredited() async throws {
        let event = makeEvent(wednesday: wednesday(
            photos: ["/photos/a.jpg"],
            tags: ["/photos/a.jpg": ["  ", "@", "@unknown", "Real Person"]]
        ))
        let day = try await manifestDay(event)

        let handles = day["tag_handles"] as? [String] ?? []
        let names = day["name_mentions"] as? [String] ?? []
        XCTAssertTrue(handles.isEmpty, "a bare @ and a sentinel handle are not real handles")
        XCTAssertEqual(names, ["Real Person"], "blank tags must not become empty credits")
    }

    func testAPhotoWithNoTagsAddsNoCredits() async throws {
        let event = makeEvent(wednesday: wednesday(
            photos: ["/photos/a.jpg"],
            tags: ["/photos/a.jpg": []]
        ))
        let day = try await manifestDay(event)

        XCTAssertNil(day["tag_handles"])
        XCTAssertNil(day["name_mentions"])
    }
}
