import XCTest

/// #221, #222, #223. CAPTIONS.txt is the deliverable: it is what Dan pastes
/// into Instagram. A wrongly formatted or entirely missing section produces a
/// file that reads as complete, ships, and is only caught if he happens to
/// notice something absent.
final class CaptionBlocksTests: XCTestCase {

    // MARK: - #221 bare usernames

    func testTheAtPrefixIsStripped() {
        XCTAssertEqual(CaptionBlocks.bareUsername("@ferminsuerojr"), "ferminsuerojr")
    }

    func testABareUsernameIsLeftAlone() {
        XCTAssertEqual(CaptionBlocks.bareUsername("safa.wav"), "safa.wav")
    }

    func testDoubledPrefixesAndPaddingAreHandled() {
        XCTAssertEqual(CaptionBlocks.bareUsername("  @@therealladibree "), "therealladibree")
    }

    func testAPastedProfileURLBecomesTheUsername() {
        XCTAssertEqual(CaptionBlocks.bareUsername("https://instagram.com/petewhitesongs/"),
                       "petewhitesongs")
    }

    // MARK: - #222 the reel days get the week's tag list

    private func event(withDays days: [DayName: (handles: [String], tags: [String: [String]], photos: [URL])]) -> Event {
        var e = Event(name: "Show", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        for (day, spec) in days {
            var posting = PostingDay(day: day)
            posting.tagHandles = spec.handles
            posting.photoPaths = spec.photos
            posting.photoTags = spec.tags
            e.days[day.rawValue] = posting
        }
        return e
    }

    func testTheListGathersHandlesFromEveryDay() {
        let e = event(withDays: [
            .sunday: (["@a"], [:], []),
            .wednesday: (["@b"], [:], []),
        ])
        XCTAssertEqual(Set(CaptionBlocks.weekTagList(event: e)), ["a", "b"])
    }

    func testTheListGathersPerPhotoTagsToo() {
        let photo = URL(fileURLWithPath: "/p/1.jpg")
        let e = event(withDays: [
            .wednesday: ([], [photo.absoluteString: ["@safa.wav", "@petewhitesongs"]], [photo]),
        ])
        XCTAssertEqual(CaptionBlocks.weekTagList(event: e), ["safa.wav", "petewhitesongs"])
    }

    func testTheListIsDeduplicatedAcrossDays() {
        let photo = URL(fileURLWithPath: "/p/1.jpg")
        let e = event(withDays: [
            .sunday: (["@shared"], [:], []),
            .wednesday: (["@shared"], [photo.absoluteString: ["@shared"]], [photo]),
        ])
        XCTAssertEqual(CaptionBlocks.weekTagList(event: e), ["shared"])
    }

    func testTwoSpellingsOfOneHandleAreOnePerson() {
        // Instagram handles are not case sensitive, so tagging both would tag
        // the same account twice.
        let e = event(withDays: [.sunday: (["@Safa.WAV", "@safa.wav"], [:], [])])
        XCTAssertEqual(CaptionBlocks.weekTagList(event: e).count, 1)
    }

    func testTheListCarriesNoAtPrefixes() {
        let e = event(withDays: [.sunday: (["@a", "b"], [:], [])])
        XCTAssertFalse(CaptionBlocks.weekTagList(event: e).contains { $0.contains("@") })
    }

    func testAnEmptyHandleIsDropped() {
        let e = event(withDays: [.sunday: (["@", "  ", "@real"], [:], [])])
        XCTAssertEqual(CaptionBlocks.weekTagList(event: e), ["real"])
    }

    // MARK: - #223 expectations per day

    func testACollageDayExpectsPhotoTagsNotAWeekTagList() {
        let blocks = CaptionBlocks.expected(day: .wednesday, preset: .balanced,
                                            hasAltText: true, hasPhotoTags: true,
                                            hasWeekTags: true)
        XCTAssertTrue(blocks.contains(.photoTags))
        XCTAssertFalse(blocks.contains(.tagList))
    }

    func testAReelDayExpectsTheWeekTagList() {
        // The defect: the reel days emitted no tag list at all, so the people
        // in the reel went untagged.
        for day in [DayName.tuesday, .thursday] {
            let blocks = CaptionBlocks.expected(day: day, preset: .balanced,
                                                hasAltText: true, hasPhotoTags: false,
                                                hasWeekTags: true)
            XCTAssertTrue(blocks.contains(.tagList), "\(day) must carry a tag list")
            XCTAssertFalse(blocks.contains(.photoTags), "\(day) has no per-photo tags")
        }
    }

    func testNoTagsAnywhereMeansNoTagBlockIsExpected() {
        let blocks = CaptionBlocks.expected(day: .thursday, preset: .balanced,
                                            hasAltText: true, hasPhotoTags: false,
                                            hasWeekTags: false)
        XCTAssertFalse(blocks.contains(.tagList))
    }

    func testEveryDayAlwaysExpectsACaption() {
        for day in DayName.allCases {
            let blocks = CaptionBlocks.expected(day: day, preset: .balanced,
                                                hasAltText: false, hasPhotoTags: false,
                                                hasWeekTags: false)
            XCTAssertEqual(blocks, [.caption])
        }
    }

    // MARK: - #223 the check itself, seen to fail

    func testACompleteBlockReportsNothingMissing() {
        let text = """
        === THURSDAY ===
        A caption.

        ALT TEXT:
        Someone at a venue doing something.

        TAG LIST:
        a, b
        """
        XCTAssertTrue(CaptionBlocks.missing(from: text,
                                            expected: [.caption, .altText, .tagList]).isEmpty)
    }

    func testAMissingTagListIsReported() {
        // Exactly what shipped: caption and alt text present, nothing to paste
        // into the tag field.
        let text = """
        === THURSDAY ===
        A caption.

        ALT TEXT:
        Someone at a venue doing something.
        """
        XCTAssertEqual(CaptionBlocks.missing(from: text, expected: [.caption, .altText, .tagList]),
                       [.tagList])
    }

    func testAMissingAltTextIsReported() {
        let text = "=== THURSDAY ===\nA caption."
        XCTAssertEqual(CaptionBlocks.missing(from: text, expected: [.caption, .altText]),
                       [.altText])
    }

    func testAnEmptyCaptionIsReportedEvenWhenTheOtherBlocksAreThere() {
        // A heading with nothing under it is not a caption.
        let text = "=== THURSDAY ===\n\nALT TEXT:\nSomething visible."
        XCTAssertTrue(CaptionBlocks.missing(from: text,
                                            expected: [.caption, .altText]).contains(.caption))
    }

    func testABlockIsNotExpectedIsNotReported() {
        let text = "=== TUESDAY ===\nA caption."
        XCTAssertTrue(CaptionBlocks.missing(from: text, expected: [.caption]).isEmpty)
    }
}
