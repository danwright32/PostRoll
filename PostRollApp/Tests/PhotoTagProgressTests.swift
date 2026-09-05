import XCTest

/// How much of a day's tagging is left to do (#1361).
///
/// Dan chose per-photo tagging over plumbing the photographs into the blog
/// revision path, and that decision rests on the tagging being practical.
/// Measured on 2026-09-04, 206 of 255 blog photos carry no tag, and the only
/// thing on screen saying so was the difference between an outlined and a
/// filled tag glyph on each thumbnail. So working through them meant opening
/// every photo to find out which were done, with no way to tell when the job
/// was finished, which is the difference between a task and a chore.
final class PhotoTagProgressTests: XCTestCase {

    private func photos(_ names: String...) -> [URL] {
        names.map { URL(fileURLWithPath: "/photos/\($0)") }
    }

    func testEveryPhotoWithNoTagIsCounted() {
        let day = photos("a.jpg", "b.jpg", "c.jpg")
        let tags = [day[0].absoluteString: ["@jenna"]]

        XCTAssertEqual(PhotoTagProgress.untagged(photos: day, tags: tags), 2)
    }

    /// An entry holding an empty list is not a tagged photo. The thumbnail
    /// writes nil rather than an empty array when the last tag is removed, but
    /// a stored event from before that, or a hand-edited one, can carry the
    /// empty list, and counting it as done would report the work finished while
    /// the photograph names nobody (L11).
    func testAnEmptyTagListCountsAsUntagged() {
        let day = photos("a.jpg", "b.jpg")
        let tags = [day[0].absoluteString: [String](),
                    day[1].absoluteString: ["   "]]

        XCTAssertEqual(PhotoTagProgress.untagged(photos: day, tags: tags), 2)
    }

    /// A tag entry whose photo is not on the day any more says nothing about
    /// the photos that are. Counting entries rather than photos would report a
    /// day as finished because a deleted photograph was once tagged.
    func testATagForAPhotoNoLongerOnTheDayDoesNotCount() {
        let day = photos("a.jpg")
        let tags = ["file:///photos/gone.jpg": ["@jenna"]]

        XCTAssertEqual(PhotoTagProgress.untagged(photos: day, tags: tags), 1)
    }

    // MARK: - What the day says about it

    func testADayWithTaggingLeftSaysHowMany() {
        let day = photos("a.jpg", "b.jpg", "c.jpg")

        XCTAssertEqual(PhotoTagProgress.note(photos: day, tags: [:]),
                       "3 still to tag")
    }

    func testOneLeftIsNotSaidInThePlural() {
        let day = photos("a.jpg", "b.jpg")
        let tags = [day[0].absoluteString: ["@jenna"]]

        XCTAssertEqual(PhotoTagProgress.note(photos: day, tags: tags),
                       "1 still to tag")
    }

    /// The finished state is its own sentence rather than silence. A day with
    /// nothing left and a day nobody has started both said nothing before, and
    /// telling them apart is the whole point of showing a count (L11, L152):
    /// the surface that reports progress goes quietest exactly when the work is
    /// complete.
    func testADayWithEveryPhotoTaggedSaysSo() {
        let day = photos("a.jpg", "b.jpg")
        let tags = [day[0].absoluteString: ["@jenna"],
                    day[1].absoluteString: ["@sam"]]

        XCTAssertEqual(PhotoTagProgress.note(photos: day, tags: tags),
                       "all tagged")
    }

    /// A day with no photographs has no tagging to report, and saying "all
    /// tagged" over an empty grid would claim work that never happened (L98).
    func testADayWithNoPhotosSaysNothing() {
        XCTAssertNil(PhotoTagProgress.note(photos: [], tags: [:]))
    }
}
