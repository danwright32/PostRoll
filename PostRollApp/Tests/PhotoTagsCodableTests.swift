import XCTest

/// Wednesday per-photo people tags persist in PostingDay.photoTags. Like every
/// other field on this struct, the key must decodeIfPresent so adding it does
/// not make existing events.json undecodable (issue #2). These pin both the
/// round trip and backward compatibility with saves written before the field
/// existed.
final class PhotoTagsCodableTests: XCTestCase {

    func testPhotoTagsRoundTrip() throws {
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [URL(fileURLWithPath: "/photos/show-277.jpg")]
        day.photoTags = ["file:///photos/show-277.jpg": ["Mike Bono", "@mikebonomusic"]]

        let encoded = try JSONEncoder().encode(day)
        let decoded = try JSONDecoder().decode(PostingDay.self, from: encoded)

        XCTAssertEqual(decoded.photoTags["file:///photos/show-277.jpg"], ["Mike Bono", "@mikebonomusic"])
    }

    func testPostingDayToleratesMissingPhotoTags() throws {
        // A PostingDay written before photoTags existed: only a day key. The
        // decode must succeed and default photoTags to empty, not throw and
        // trigger the wipe-protection path.
        let json = Data(#"{"day": "wednesday", "photoPaths": ["file:///x.jpg"]}"#.utf8)
        let day = try JSONDecoder().decode(PostingDay.self, from: json)

        XCTAssertEqual(day.day, .wednesday)
        XCTAssertEqual(day.photoPaths, [URL(string: "file:///x.jpg")])
        XCTAssertTrue(day.photoTags.isEmpty)
    }

    func testEmptyTagsKeyIsOmittable() throws {
        // The UI clears a photo's entry to nil when its tags become empty, so
        // an empty dict is the no-tags state and round-trips as such.
        var day = PostingDay(day: .wednesday)
        day.photoTags = [:]

        let encoded = try JSONEncoder().encode(day)
        let decoded = try JSONDecoder().decode(PostingDay.self, from: encoded)

        XCTAssertTrue(decoded.photoTags.isEmpty)
    }
}
