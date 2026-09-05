import XCTest

/// #1069: the review screen says what a day's alt text is meant to describe.
///
/// It showed one sentence beside the caption with nothing saying what that
/// sentence covers, and the screen looked the same whether the alt text
/// described a video built from two hundred photographs, one photo of a
/// carousel, or a single feed photo. Alt text is the one part of a post that
/// cannot be verified by looking at the post, so this screen is the only place
/// the error can be caught.
final class AltTextScopeTests: XCTestCase {

    /// The assertion the issue asks for by name. A reel's alt text is written
    /// from a SAMPLE of the photographs while the reel is built from all of
    /// them, so naming the sample would send the reviewer to check the
    /// description against the wrong set: worse than saying nothing, because it
    /// reads as a fact.
    func testTheReelLineNamesEveryPhotographTheReelHolds() {
        let line = AltTextScope.line(day: .thursday, isCarousel: false,
                                     photos: 137, altTexts: 1)

        XCTAssertEqual(line, "Describes the whole reel, built from 137 photographs.")
    }

    func testTuesdayIsAReelDayToo() {
        let line = AltTextScope.line(day: .tuesday, isCarousel: false,
                                     photos: 42, altTexts: 1)

        XCTAssertEqual(line?.contains("whole reel"), true)
    }

    /// More than one description on a reel is #1067's defect: the model wrote
    /// one per photograph. The line has to disagree with the list beneath it
    /// out loud rather than print a sentence that contradicts it.
    func testAReelWithSeveralDescriptionsIsToldItIsWrong() {
        let line = AltTextScope.line(day: .thursday, isCarousel: false,
                                     photos: 137, altTexts: 4)

        XCTAssertEqual(line?.contains("takes one description"), true, line ?? "nil")
        XCTAssertEqual(line?.contains("4"), true, line ?? "nil")
        XCTAssertEqual(line?.contains("137"), false,
                       "the reel's photo count is not the subject when the "
                       + "fault is that there are four descriptions")
    }

    func testACarouselSaysTheDescriptionsAreOnePerPhotoInOrder() {
        let line = AltTextScope.line(day: .wednesday, isCarousel: true,
                                     photos: 6, altTexts: 6)

        XCTAssertEqual(line, "One per photo, in the order they appear in the carousel.")
    }

    /// A count repeated on every ordinary post is noise, so it appears only
    /// where it is a fault worth interrupting for (L36).
    func testACarouselWithTheWrongNumberOfDescriptionsSaysSo() {
        let line = AltTextScope.line(day: .wednesday, isCarousel: true,
                                     photos: 6, altTexts: 4)

        XCTAssertEqual(line?.contains("4 for 6 photographs"), true, line ?? "nil")
    }

    func testASingleFeedPhotoSaysWhatItDescribes() {
        let line = AltTextScope.line(day: .sunday, isCarousel: false,
                                     photos: 1, altTexts: 1)

        XCTAssertEqual(line, "Describes the one photograph in this post.")
    }

    /// A day with no alt text has nothing to explain, and a line over an empty
    /// list would describe something that is not there (L98).
    func testADayWithNoAltTextSaysNothing() {
        XCTAssertNil(AltTextScope.line(day: .thursday, isCarousel: false,
                                       photos: 137, altTexts: 0))
    }

    /// An event whose photographs have not been counted yet must not be told
    /// there are none: the mismatch note is about a real disagreement, and
    /// zero photos with one description is a day mid-setup rather than a fault.
    func testAnUncountedDayIsNotAccusedOfAMismatch() {
        let line = AltTextScope.line(day: .wednesday, isCarousel: true,
                                     photos: 0, altTexts: 1)

        XCTAssertEqual(line, "One per photo, in the order they appear in the carousel.")
    }
}
